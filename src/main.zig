const std = @import("std");
const posix = std.posix;
const request = @import("request.zig");
const static = @import("static");

const Response = @import("response.zig").Response;
const Method = request.Method;
const Stream = std.net.Stream;
const Address = std.net.Address;

//TODO: replace assetpack (it's good for now) with relative path file loading for hot loading
var index_html: []const u8 = undefined;

fn handleConnection(stream: *Stream) !void {
    //TODO: fix autocannon error: { errno -104, code 'ECONNRESET', syscall: 'read' }

    var buffer: [8192]u8 = undefined;

    try request.read_request(stream, &buffer);
    const req = try request.parse_request(&buffer);

    var res = Response.init(stream);

    if (req.method == Method.GET) {
        if (std.mem.eql(u8, req.uri, "/")) {
            res.body = index_html;

            try res.write();
        } else {
            res.status = 404;
            res.body = "<html><body><h1>File not found!</h1></body></html>";

            try res.write();
        }
    }
}

pub fn main() !void {
    //TODO: cache files properly in a production setting
    index_html = try static.root.file("index.html"); //currently just pre-loads by setting global variable

    const host = [4]u8{ 127, 0, 0, 1 };
    const port = 3000;

    const addr = Address.initIp4(host, port);

    {
        var buffer: [64]u8 = undefined;
        const stderr = std.debug.lockStderrWriter(&buffer);
        defer std.debug.unlockStderrWriter();

        try stderr.print("Listening at http://", .{});
        try addr.in.format(stderr);
        try stderr.print("\n", .{});
        try stderr.flush();
    }

    const sock_fd = try posix.socket(addr.any.family, posix.SOCK.STREAM, posix.IPPROTO.TCP);
    defer posix.close(sock_fd);

    try posix.setsockopt(sock_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

    try posix.bind(sock_fd, &addr.any, addr.getOsSockLen());
    try posix.listen(sock_fd, 1024);

    while (true) {
        //TODO: add threading here
        var address: Address = undefined;
        var address_len: posix.socklen_t = @sizeOf(Address);
        const conn_fd = posix.accept(sock_fd, &address.any, &address_len, posix.SOCK.CLOEXEC) catch |err| {
            std.log.err("Failed to accept socket: {}", .{err});
            continue;
        };
        defer posix.close(conn_fd);

        var stream: Stream = .{ .handle = conn_fd };

        try handleConnection(&stream);
    }
}
