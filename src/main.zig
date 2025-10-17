const std = @import("std");

const Server = @import("server.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var server = try Server.init(allocator);
    defer server.deinit();

    const address = try std.net.Address.parseIp("127.0.0.1", 3000);
    try server.run(address);
    std.debug.print("STOPPED\n", .{});
}
