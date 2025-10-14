const std = @import("std");
const socket = @import("socket.zig");
const request = @import("request.zig");

const Response = @import("response.zig").Response;
const Socket = socket.Socket;
const Method = request.Method;
const Connection = std.net.Server.Connection;

var stdout_buffer: [1024]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
const stdout = &stdout_writer.interface;

fn handleConnection(conn: *Connection) !void {
    //TODO: fix autocannon error: { errno -104, code 'ECONNRESET', syscall: 'read' }

    var buffer: [8192]u8 = undefined;

    try request.read_request(conn, &buffer);
    const req = try request.parse_request(&buffer);

    var res = Response.init(conn);

    if (req.method == Method.GET) {
        if (std.mem.eql(u8, req.uri, "/")) {
            res.body = "<html><body><h1>Hello, World!</h1></body></html>";

            try res.write();
        } else {
            res.status = 404;
            res.body = "<html><body><h1>File not found!</h1></body></html>";

            try res.write();
        }
    }
}

pub fn main() !void {
    const sock = try Socket.init(.{
        .host = [4]u8{ 127, 0, 0, 1 },
        .port = 3000,
    });

    try stdout.print("Server Addr: http://", .{});
    try sock.print_address(stdout);
    try stdout.print("\n", .{});
    try stdout.flush();

    var server = try sock._address.listen(.{ .reuse_address = true });
    defer server.deinit();

    while (true) {
        //TODO: add REAL threading here. code below is not good (and in fact slower), even though it works
        var conn = try server.accept();
        defer conn.stream.close();
        //const thread = try std.Thread.spawn(.{}, handleConnection, .{conn});
        //thread.detach();
        try handleConnection(&conn);
    }
}
