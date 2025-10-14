const std = @import("std");
const sock = @import("socket.zig");
const req = @import("request.zig");
const Response = @import("response.zig").Response;

const Socket = sock.Socket;
const Method = req.Method;

var stdout_buffer: [1024]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
const stdout = &stdout_writer.interface;

fn handleConnection(conn: std.net.Server.Connection) !void {
    //TODO: fix autocannon error: { errno -104, code 'ECONNRESET', syscall: 'read' }
    defer conn.stream.close();

    var buffer: [8192]u8 = undefined;

    try req.read_request(conn, &buffer);
    const request = try req.parse_request(buffer[0..buffer.len]);

    if (request.method == Method.GET) {
        if (std.mem.eql(u8, request.uri, "/")) {
            const message = "<html><body><h1>Hello, World!</h1></body></html>";
            const res = Response.init(conn, 200, message);
            try res.write();
        } else {
            const message = "<html><body><h1>File not found!</h1></body></html>";
            const res = Response.init(conn, 200, message);
            try res.write();
        }
    }
}

pub fn main() !void {
    const socket = try Socket.init(.{
        .host = [4]u8{ 127, 0, 0, 1 },
        .port = 3001,
    });

    try stdout.print("Server Addr: ", .{});
    try socket.print_address(stdout);
    try stdout.print("\n", .{});
    try stdout.flush();

    var server = try socket._address.listen(.{ .reuse_address = true });
    defer server.deinit();

    while (true) {
        //TODO: add REAL threading here. code below is not good, even though it works
        const conn = try server.accept();
        // const thread = try std.Thread.spawn(.{}, handleConnection, .{conn});
        // thread.detach();
        try handleConnection(conn);
    }
}
