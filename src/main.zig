const std = @import("std");
const builtin = @import("builtin");
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

    //taken from here: https://ziglang.org/download/0.14.0/release-notes.html#SmpAllocator
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const allocator, const is_debug = allocator: {
        if (builtin.os.tag == .wasi) break :allocator .{ std.heap.wasm_allocator, false };
        break :allocator switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    const threads = try allocator.alloc(std.Thread, config.num_workers);
    defer allocator.free(threads);

    for (0..config.num_workers) |i| {
        threads[i] = try std.Thread.spawn(.{}, Worker.work, .{ address, allocator });
    }

    for (threads) |thread| thread.join();

    std.debug.print("STOPPED\n", .{});
}
