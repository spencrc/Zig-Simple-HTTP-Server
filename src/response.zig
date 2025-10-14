const std = @import("std");
const Connection = std.net.Server.Connection;

pub fn send_200(conn: Connection) !void {
    const message = ("HTTP/1.1 200 OK\n" ++
        "Content-Length: 48\n" ++
        "Content-Type: text/html\n" ++
        "Connection: close\n" ++
        "\n" ++
        "<html><body>" ++
        "<h1>Hello, World!</h1>" ++
        "</body></html>");
    var stream_writer = conn.stream.writer(&.{});
    const writer = &stream_writer.interface;
    _ = try writer.write(message);
}

pub fn send_404(conn: Connection) !void {
    const message = ("HTTP/1.1 404 Not Found\n" ++
        "Content-Length: 52\n" ++
        "Content-Type: text/html\n" ++
        "Connection: Closed\n" ++
        "\n" ++
        "<html><body>" ++
        "<h1>File not found!</h1>" ++
        "</body></html>");
    var stream_writer = conn.stream.writer(&.{});
    const writer = &stream_writer.interface;
    _ = try writer.write(message);
}
