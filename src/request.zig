const std = @import("std");

pub const Method = enum {
    GET,
    DELETE,
    HEAD,
    OPTIONS,
    TRACE,
    UNKNOWN,

    pub fn init(text: []const u8) Method {
        if (std.mem.eql(u8, text, "GET") or std.mem.eql(u8, text, "get")) return Method.GET;
        if (std.mem.eql(u8, text, "DELETE") or std.mem.eql(u8, text, "delete")) return Method.DELETE;
        if (std.mem.eql(u8, text, "HEAD") or std.mem.eql(u8, text, "head")) return Method.HEAD;
        if (std.mem.eql(u8, text, "OPTIONS") or std.mem.eql(u8, text, "options")) return Method.OPTIONS;
        if (std.mem.eql(u8, text, "TRACE") or std.mem.eql(u8, text, "trace")) return Method.TRACE;
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

pub fn read_request(stream: *std.net.Stream, buffer: []u8) void {
    var stream_reader = stream.reader(buffer);
    var reader = stream_reader.interface();

    //TODO: figure out a better alternative, since this will (almost randomly) throw error.EndOfStream
    while (reader.takeDelimiterExclusive('\n')) |line| {
        if (line.len == 0 or (line.len == 1 and line[0] == '\r')) {
            break;
        }
    } else |err| {
        std.log.err("Reached the end of stream: {any}", .{err});
    }
}

pub fn parse_request(text: []u8) !Request {
    const line_index = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;

    var iterator = std.mem.splitScalar(u8, text[0..line_index], ' ');

    const method = Method.init(iterator.next() orelse return error.InvalidRequest);
    const uri = iterator.next() orelse return error.InvalidRequest;
    const version = iterator.next() orelse return error.InvalidRequest;

    const request = Request.init(method, uri, version);
    return request;
}
