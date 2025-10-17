const std = @import("std");

const Server = @import("server.zig");

pub fn work(address: std.net.Address) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var server = try Server.init(allocator);
    defer server.deinit();

    try server.run(address);
}
