const std = @import("std");
const Connection = std.net.Server.Connection;

pub const Method = enum {
    GET,
    UNKNOWN,

    pub fn init(text: []const u8) !Method {
        if (std.mem.eql(u8, text, "GET") or std.mem.eql(u8, text, "get")) return Method.GET;
        return Method.UNKNOWN;
    }
};

const Request = struct {
    method: Method,
    version: []const u8,
    uri: []const u8,

    pub fn init(method: Method, uri: []const u8, version: []const u8) Request {
        return Request{ .method = method, .uri = uri, .version = version };
    }
};

pub fn read_request(conn: Connection, buffer: []u8) !void {
    var stream_reader = conn.stream.reader(buffer);
    var reader = stream_reader.interface();

    while (reader.takeDelimiterExclusive('\n')) |line| {
        if (line.len == 0 or (line.len == 1 and line[0] == '\r')) {
            break;
        }
    } else |err| {
        std.debug.print("{any}\n", .{err});
    }
}

pub fn parse_request(text: []u8) !Request {
    const line_index = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;

    var iterator = std.mem.splitScalar(u8, text[0..line_index], ' ');

    const method = try Method.init(iterator.next() orelse return error.InvalidRequest);
    const uri = iterator.next() orelse return error.InvalidRequest;
    const version = iterator.next() orelse return error.InvalidRequest;

    // std.debug.print("{any}\n", .{method});
    // std.debug.print("{any}\n", .{uri});
    // std.debug.print("{any}\n", .{version});

    const request = Request.init(method, uri, version);
    return request;
}
