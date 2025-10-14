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
        const headers = try std.fmt.bufPrint(header_buffer[0..], "HTTP/1.1 {d} \r\nContent-Length: {d} \r\nContent-Type: text/html \r\nConnection: close \r\n\r\n", .{
            self.status,
            self.body.len,
        });

        var stream_writer = self.conn.stream.writer(&.{});
        const writer = &stream_writer.interface;
        _ = try writer.writeVec(&.{ headers, self.body });
        //_ = try writer.write(self.body);
    }
};
