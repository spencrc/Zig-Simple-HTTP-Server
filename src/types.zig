const std = @import("std");
const posix = std.posix;
const config = @import("config");

pub const EventType = enum(u64) { ACCEPT = 1, READ = 2, WRITE = 3 };

pub const RingRequest = struct {
    event_type: EventType = undefined,
    client_socket: posix.socket_t = undefined,
    iovecs: [2]posix.iovec_const = undefined,
    //according to http.zig, 220 is enough for:
    // - the status
    // - Content-Length header or Transfer-Encoding header
    // - http.zig's longest supported content type (we only have one rn lol)
    header_buffer: [220]u8 = undefined,
    body: []const u8 = "",
    headers: []u8 = undefined,
    keep_alive: bool = true,
};

pub const HttpResponse = struct {
    status: u16 = 200,
    body: []const u8 = "",
    type: []const u8 = "text/html",
};

pub const HttpRequest = struct {
    method: Method,
    uri: URI,
    version: u8,
    headers: [config.max_headers]Header,
    headers_size: usize = 0,
    keep_alive: bool = true,
};

pub const Method = enum { GET, DELETE, HEAD, OPTIONS, TRACE, UNKNOWN, POST, PUT, PATCH, CONNECT };

pub const URI = struct {
    path: []const u8,
    query: ?[]const u8,
    fragment: ?[]const u8,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,

    pub fn init(name: []const u8, value: []const u8) Header {
        return .{ .name = name, .value = value };
    }
};
