const std = @import("std");
const Connection = std.net.Server.Connection;
const Writer = std.Io.Writer;

const HEADER_TEMPLATE = //please see write function for what gets placed in formatting specifiers
    "HTTP/1.1 {d} \r\n" ++
    "Content-Length: {d} \r\n" ++
    "Content-Type: text/html \r\n" ++
    "Connection: close \r\n\r\n";

pub const Response = struct {
    conn: *Connection,
    status: u16 = 200,
    body: []const u8 = "",

    pub fn init(conn: *Connection) Response {
        return Response{
            .conn = conn,
        };
    }

    pub fn write(self: Response) !void {
        var header_buffer: [220]u8 = undefined;

        const headers = try std.fmt.bufPrint(header_buffer[0..], HEADER_TEMPLATE, .{
            self.status,
            self.body.len,
        });

        var stream_writer = self.conn.stream.writer(&.{});
        const writer = &stream_writer.interface;
        _ = try writer.writeVec(&.{ headers, self.body });
    }
};
