const std = @import("std");
const Worker = @import("worker.zig");
const config = @import("config");

pub fn main() !void {
    const address = try std.net.Address.parseIp(config.host, config.port);

    {
        var buffer: [64]u8 = undefined;
        const stderr = std.debug.lockStderrWriter(&buffer);
        defer std.debug.unlockStderrWriter();

        try stderr.print("Listening with {d} workers at http://", .{config.num_workers});
        try address.in.format(stderr);
        try stderr.print("\n", .{});
        try stderr.flush();
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const threads = try allocator.alloc(std.Thread, config.num_workers);
    defer allocator.free(threads);

    for (0..config.num_workers) |i| {
        threads[i] = try std.Thread.spawn(.{}, Worker.work, .{address});
    }

    for (threads) |thread| thread.join();

    std.debug.print("STOPPED\n", .{});
}
