const std = @import("std");
const Connection = std.net.Server.Connection;

const Writer = std.Io.Writer;

pub const Response = struct {
    conn: Connection,
    status: u16,
    body: []u8,

    pub fn init(conn: Connection, status: u16, body: []u8) Response {
        return Response{
            .conn = conn,
            .status = status,
            .body = body,
        };
    }

    pub fn writer(self: Response) *Writer {
        var stream_writer = self.conn.stream.writer(&.{});
        return &stream_writer.interface;
    }
};

pub fn send_200(conn: Connection) !void {
    const message = ("HTTP/1.1 200\n" ++
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
