const std = @import("std");
const config = @import("config");
const types = @import("types.zig");

const Method = types.Method;
const URI = types.URI;
const Header = types.Header;
const HttpRequest = types.HttpRequest;

inline fn match_method(data: []const u8, name: []const u8) bool {
    return data.len >= name.len and std.mem.eql(u8, data[0..name.len], name);
}

fn parse_method(data: []const u8, pos_ptr: *usize) !Method {
    switch (data[0]) {
        'G' => if (match_method(data, "GET")) {
            pos_ptr.* = 3;
            return Method.GET;
        },
        'H' => if (match_method(data, "HEAD")) {
            pos_ptr.* = 4;
            return Method.HEAD;
        },
        'D' => if (match_method(data, "DELETE")) {
            pos_ptr.* = 6;
            return Method.DELETE;
        },
        'C' => if (match_method(data, "CONNECT")) {
            pos_ptr.* = 7;
            return Method.CONNECT;
        },
        'O' => if (match_method(data, "OPTIONS")) {
            pos_ptr.* = 7;
            return Method.OPTIONS;
        },
        'T' => if (match_method(data, "TRACE")) {
            pos_ptr.* = 5;
            return Method.TRACE;
        },
        'P' => switch (data[1]) {
            'O' => if (match_method(data, "POST")) {
                pos_ptr.* = 4;
                return Method.POST;
            },
            'U' => if (match_method(data, "PUT")) {
                pos_ptr.* = 3;
                return Method.PUT;
            },
            'A' => if (match_method(data, "PATCH")) {
                pos_ptr.* = 5;
                return Method.PATCH;
            },
            else => return error.NotImplemented,
        },
        else => return error.NotImplemented,
    }
    return error.NotImplemented;
}

fn parse_uri(uri: []const u8) URI {
    var relative_pos: usize = 0;
    var q_pos: ?usize = null;
    var h_pos: ?usize = null;

    while (relative_pos < uri.len) : (relative_pos += 1) {
        if (q_pos == null and uri[relative_pos] == '?') {
            q_pos = relative_pos;
        } else if (h_pos == null and uri[relative_pos] == '#') {
            h_pos = relative_pos;
            break;
        }
    }

    const path_end = if (q_pos) |q| q else if (h_pos) |h| h else uri.len;
    const path = uri[0..path_end];

    const query = if (q_pos) |q| blk: {
        const end = if (h_pos) |h| h else uri.len;
        break :blk uri[q + 1 .. end];
    } else null;

    const fragment = if (h_pos) |h| blk: {
        if (h + 1 < uri.len) break :blk uri[h + 1 ..];
        break :blk null;
    } else null;

    return .{ .path = path, .query = query, .fragment = fragment };
}

fn parse_version(data: []const u8, pos_ptr: *usize) !u8 {
    if (pos_ptr.* + 5 >= data.len)
        return error.RequestLineTooShort;

    if (!std.mem.startsWith(u8, data[pos_ptr.*..], "HTTP/"))
        return error.InvalidVersionPrefix;

    const major_version_pos = pos_ptr.* + 5;

    if (data[major_version_pos] == '1') {
        if (major_version_pos + 2 >= data.len)
            return error.BadRequest;
        const dot_pos = major_version_pos + 1;
        if (data[dot_pos] != '.')
            return error.MissingVersionDot;

        const minor_version_pos = dot_pos + 1;
        if (data[minor_version_pos] == '1') {
            return 1;
        } else if (data[minor_version_pos] == '0') {
            return 0;
        } else return error.InvalidVersion;
    } else return error.HTTPVersionNotSupported;
}

fn parse_headers(data: []const u8, headers: []Header, count_ptr: *usize, keep_alive: *bool) !void {
    var pos: usize = 0;
    while (pos < data.len) {
        if (pos + 2 <= data.len and data[pos] == '\r' and data[pos + 1] == '\n') {
            break; //we've reached the end of the headers
        }
        if (std.ascii.isWhitespace(data[pos]))
            return error.FieldNameStartsWithWhitespace;

        const colon_pos = std.mem.indexOfScalarPos(u8, data, pos, ':') orelse return error.CannotFindColon;
        if (colon_pos == pos or std.ascii.isWhitespace(data[pos]))
            return error.WhitespaceBeforeColon;

        const field_line_end = std.mem.indexOfScalarPos(u8, data, colon_pos, '\n') orelse return error.MissingCRLF;
        const name = data[pos..colon_pos];

        if (std.mem.eql(u8, name, "Host")) {
            if (data[field_line_end - 1] != '\r')
                return error.MissingCRLF;

            const value = std.mem.trim(u8, data[colon_pos + 1 .. field_line_end - 1], " \t");

            headers[count_ptr.*] = Header.init(name, value);
            count_ptr.* += 1;
            if (count_ptr.* >= config.max_headers)
                return error.RequestHeaderFieldsTooLarge;
        } else if (std.mem.eql(u8, name, "Connection")) {
            if (data[field_line_end - 1] != '\r')
                return error.MissingCRLF;

            const value = std.mem.trim(u8, data[colon_pos + 1 .. field_line_end - 1], " \t");
            if (std.mem.eql(u8, value, "keep-alive")) {
                keep_alive.* = true;
            } else {
                keep_alive.* = false;
            }
        }

        pos = field_line_end + 1;
    }
}

pub fn parse(data: []const u8) !HttpRequest {
    const data_len = data.len;
    if (data_len <= 1)
        return error.EmptyBuffer;
    if (data_len > config.max_request_len)
        return error.ContentTooLarge;

    var req: HttpRequest = undefined;
    var pos: usize = 0;

    req.method = try parse_method(data, &pos);

    if (pos >= data_len)
        return error.RequestLineTooShort;

    if (data[pos] != ' ')
        return error.MissingWhitespace;

    const uri_start = pos + 1;
    const uri_end = std.mem.indexOfScalarPos(u8, data, uri_start, ' ') orelse return error.MissingURI;
    if (uri_end - uri_start > config.max_uri_len)
        return error.URITooLong;
    req.uri = parse_uri(data[uri_start..uri_end]);

    pos = uri_end + 1;

    req.version = try parse_version(data, &pos);

    const request_line_end = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse return error.MissingCRLF;
    if (data[request_line_end - 1] != '\r')
        return error.MissingCRLF;

    req.headers_size = 0;
    req.keep_alive = true;
    try parse_headers(data[request_line_end + 1 ..], &req.headers, &req.headers_size, &req.keep_alive);

    return req;
}

test "basic" {
    const data = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\nHello";
    const req = try parse(data);
    try std.testing.expect(req.method == Method.GET);

    try std.testing.expect(req.uri.fragment == null);
    try std.testing.expect(req.uri.query == null);
    try std.testing.expect(std.mem.eql(u8, req.uri.path, "/"));

    try std.testing.expect(req.version == 1);

    try std.testing.expect(req.headers_size == 1);
    try std.testing.expect(std.mem.eql(u8, req.headers[0].name, "Host"));
    try std.testing.expect(std.mem.eql(u8, req.headers[0].value, "localhost"));
}

test "basic but big" {
    const data =
        "GET /api/v1/resource?id=12345&filter=active&sort=desc HTTP/1.1\r\n" ++
        "Host: benchmark.example.com\r\n" ++
        "User-Agent: ZigHTTPBench/1.0 (Zig; +https://ziglang.org)\r\n" ++
        "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\n" ++
        "Accept-Language: en-US,en;q=0.9\r\n" ++
        "Accept-Encoding: gzip, deflate, br\r\n" ++
        "Cache-Control: no-cache\r\n" ++
        "Pragma: no-cache\r\n" ++
        "Connection: keep-alive\r\n" ++
        "Upgrade-Insecure-Requests: 1\r\n" ++
        "Sec-Fetch-Dest: document\r\n" ++
        "Sec-Fetch-Mode: navigate\r\n" ++
        "Sec-Fetch-Site: none\r\n" ++
        "Sec-Fetch-User: ?1\r\n" ++
        "X-Forwarded-For: 192.168.0.100, 10.0.0.2\r\n" ++
        "X-Request-ID: 550e8400-e29b-41d4-a716-446655440000\r\n" ++
        "X-Trace-ID: abcd1234efgh5678ijkl9012mnop3456\r\n" ++
        "X-Custom-Metric: 1234567890\r\n" ++
        "X-Large-Header: " ++
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789" ++ "\r\n" ++
        "Referer: https://benchmark.example.com/dashboard\r\n" ++
        "If-Modified-Since: Wed, 21 Oct 2015 07:28:00 GMT\r\n" ++
        "If-None-Match: \"33a64df551425fcc55e4d42a148795d9f25f89d4\"\r\n" ++
        "DNT: 1\r\n" ++
        "\r\n";
    const req = try parse(data);
    try std.testing.expect(req.method == Method.GET);

    try std.testing.expect(req.uri.fragment == null);
    try std.testing.expect(std.mem.eql(u8, req.uri.query.?, "id=12345&filter=active&sort=desc"));
    try std.testing.expect(std.mem.eql(u8, req.uri.path, "/api/v1/resource"));

    try std.testing.expect(req.version == 1);

    try std.testing.expect(req.headers_size == 1);
    try std.testing.expect(std.mem.eql(u8, req.headers[0].name, "Host"));
    try std.testing.expect(std.mem.eql(u8, req.headers[0].value, "benchmark.example.com"));
}

test "empty buffer" {
    const data = "";
    try std.testing.expectError(error.EmptyBuffer, parse(data));
}

test "GET method" {
    const data = "GET";
    var pos: usize = 0;
    const method = try parse_method(data, &pos);
    try std.testing.expect(method == .GET);
}

test "POST method" {
    const data = "POST";
    var pos: usize = 0;
    const method = try parse_method(data, &pos);
    try std.testing.expect(method == .POST);
}

test "DELETE method" {
    const data = "DELETE";
    var pos: usize = 0;
    const method = try parse_method(data, &pos);
    try std.testing.expect(method == .DELETE);
}

test "basic uri" {
    const data = "/foo?bar=true&fizz=false#buzz";
    const uri = parse_uri(data);
    try std.testing.expect(std.mem.eql(u8, uri.fragment.?, "buzz"));
    try std.testing.expect(std.mem.eql(u8, uri.query.?, "bar=true&fizz=false"));
    try std.testing.expect(std.mem.eql(u8, uri.path, "/foo"));
}

test "basic request line with bad version" {
    const data = "GET / HTXP/1.1";
    try std.testing.expectError(error.InvalidVersionPrefix, parse(data));
}

test "basic request line with bad version number" {
    const data = "GET / HTTP/1.2";
    try std.testing.expectError(error.InvalidVersion, parse(data));
}

test "basic request line with no version dot" {
    const data = "GET / HTTP/11 ";
    try std.testing.expectError(error.MissingVersionDot, parse(data));
}

test "basic request line with unsupported version" {
    const data = "GET / HTTP/2";
    try std.testing.expectError(error.HTTPVersionNotSupported, parse(data));
}

test "missing trailing character" {
    const data = "GET / HTTP/1.1";
    try std.testing.expectError(error.MissingCRLF, parse(data));
}
