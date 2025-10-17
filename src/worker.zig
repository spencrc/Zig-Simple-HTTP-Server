const std = @import("std");

const Server = @import("server.zig");

pub fn work(address: std.net.Address, allocator: std.mem.Allocator) !void {
    var server = try Server.init(allocator);
    defer server.deinit();

    try server.run(address);
}
