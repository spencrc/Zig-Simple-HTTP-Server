const std = @import("std");

const Stream = std.net.Stream;

const HEADER_TEMPLATE = //please see write function for what gets placed in formatting specifiers
    "HTTP/1.1 {d} \r\n" ++
    "Content-Length: {d} \r\n" ++
    "Content-Type: text/html \r\n" ++
    "Connection: close \r\n\r\n";

pub const Response = struct {
    stream: *Stream,
    status: u16 = 200,
    body: []const u8 = "",

    pub fn init(stream: *Stream) Response {
        return Response{
            .stream = stream,
        };
    }

    pub fn write(self: Response) !void {
        var header_buffer: [220]u8 = undefined;
        //according to http.zig, 220 is enough for:
        // - the status
        // - Content-Length header or Transfer-Encoding header
        // - http.zig's longest supported content type (we only have one rn lol)
        const headers = try std.fmt.bufPrint(header_buffer[0..], HEADER_TEMPLATE, .{
            self.status,
            self.body.len,
        });

        var stream_writer = self.stream.writer(&.{});
        const writer = &stream_writer.interface;
        _ = try writer.writeVec(&.{ headers, self.body });
    }
};
