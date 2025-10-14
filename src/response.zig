const std = @import("std");
const Connection = std.net.Server.Connection;

const Writer = std.Io.Writer;

pub const Response = struct {
    conn: Connection,
    status: u16,
    body: []const u8,

    pub fn init(conn: Connection, status: u16, body: []const u8) Response {
        return Response{
            .conn = conn,
            .status = status,
            .body = body,
        };
    }

    pub fn write(self: Response) !void {
        var header_buffer: [220]u8 = undefined;
        // HTTP/1.1 {d} \r\n is ALWAYS 15 characters, as {d} is ALWAYS a 3-digit number
        _ = try std.fmt.bufPrint(header_buffer[0..], "HTTP/1.1 {d} \r\n", .{self.status});

        const content_length = try std.fmt.bufPrint(header_buffer[15..], "Content-Length: {d} \r\n", .{self.body.len});
        var total_written = 15 + content_length.len;

        const content_type = try std.fmt.bufPrint(header_buffer[total_written..], "Content-Type: text/html \r\n", .{});
        total_written += content_type.len;

        const connection = try std.fmt.bufPrint(header_buffer[total_written..], "Connection: close \r\n\r\n", .{});
        total_written += connection.len;

        const headers = header_buffer[0..total_written];

        var stream_writer = self.conn.stream.writer(&.{});
        const writer = &stream_writer.interface;
        _ = try writer.write(headers);
        _ = try writer.write(self.body);
    }
};
