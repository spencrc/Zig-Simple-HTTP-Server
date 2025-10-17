const Server = @This();

const std = @import("std");
const posix = std.posix;
const static = @import("static");

const IoUring = std.os.linux.IoUring;
const http_request = @import("http_request.zig");
const Method = http_request.Method;
const Response = @import("response.zig");

const EventType = enum(u64) { ACCEPT = 1, READ = 2, WRITE = 3 };

const HEADER_TEMPLATE = //please see write function for what gets placed in formatting specifiers
    "HTTP/1.1 {d} \r\n" ++
    "Content-Length: {d} \r\n" ++
    "Content-Type: text/html \r\n" ++
    "Connection: close \r\n\r\n";

const Request = struct {
    event_type: EventType = undefined,
    client_socket: posix.socket_t = undefined,
    iovecs: [2]posix.iovec_const = undefined,
    reading_buffer: [4096]u8 = undefined,
    header_buffer: [220]u8 = undefined,
    body: []const u8 = "",
    headers: []u8 = undefined,
};

//TODO: replace assetpack (it's good for now) with relative path file loading for hot loading
var index_html: []const u8 = undefined;

ring: IoUring,
allocator: std.mem.Allocator,
req_pool: std.heap.MemoryPool(Request),

pub fn init(allocator: std.mem.Allocator) !Server {
    const ring = try IoUring.init(4096, 0);

    return .{
        .ring = ring,
        .allocator = allocator,
        .req_pool = std.heap.MemoryPool(Request).init(allocator),
    };
}

pub fn deinit(self: *Server) void {
    self.ring.deinit();
    self.req_pool.deinit();
}

pub fn run(self: *Server, address: std.net.Address) !void {
    index_html = try static.root.file("index.html"); //currently just pre-loads by setting global variable

    {
        var buffer: [64]u8 = undefined;
        const stderr = std.debug.lockStderrWriter(&buffer);
        defer std.debug.unlockStderrWriter();

        try stderr.print("Listening at http://", .{});
        try address.in.format(stderr);
        try stderr.print("\n", .{});
        try stderr.flush();
    }

    const listener = try posix.socket(address.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);

    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

    try posix.bind(listener, &address.any, address.getOsSockLen());
    try posix.listen(listener, 1024);

    var client_address: posix.sockaddr = undefined;
    var client_address_len: posix.socklen_t = @sizeOf(posix.sockaddr);
    try self.addAcceptRequest(listener, &client_address, &client_address_len);

    while (true) {
        //TODO: add threading here
        const cqe = try self.ring.copy_cqe();
        const req: *Request = @ptrFromInt(cqe.user_data);

        if (cqe.res < 0) {
            std.log.err("Async requested failed: {d} for event {any}\n", .{ cqe.res, req.event_type });
            return;
        }

        switch (req.event_type) {
            .ACCEPT => {
                try self.addAcceptRequest(listener, &client_address, &client_address_len);
                self.req_pool.destroy(req);
                try self.addReadRequest(cqe.res);
            },
            .READ => {
                if (cqe.res <= 0) { //res = 0 is an empty result! anything less than 0 is an error
                    posix.close(req.client_socket);
                    self.req_pool.destroy(req);
                    continue;
                }
                try self.handleRequest(req);

                self.req_pool.destroy(req);
            },
            .WRITE => {
                posix.close(req.client_socket);

                self.req_pool.destroy(req);
            },
        }
    }
}

fn addAcceptRequest(self: *Server, listener: posix.socket_t, client_address: *posix.sockaddr, client_address_len: *posix.socklen_t) !void {
    const req: *Request = try self.req_pool.create();
    req.event_type = EventType.ACCEPT;

    const user_data = @intFromPtr(req);

    _ = try self.ring.accept(user_data, listener, client_address, client_address_len, 0);
    _ = try self.ring.submit();
}

fn addReadRequest(self: *Server, socket: posix.socket_t) !void {
    const req: *Request = try self.req_pool.create();
    req.event_type = EventType.READ;
    req.client_socket = socket;

    const user_data = @intFromPtr(req);

    const read_buffer = IoUring.ReadBuffer{ .buffer = req.reading_buffer[0..4096] };

    _ = try self.ring.read(user_data, req.client_socket, read_buffer, 0);
    _ = try self.ring.submit();
}

fn handleRequest(self: *Server, req: *Request) !void {
    //std.debug.print("\nClient Request\n{s}\n\n", .{req.reading_buffer[0..bytes_read]}); //view contents of buffer after reading/parsing is done
    const parsed_req = http_request.parse_request(&req.reading_buffer) catch {
        std.log.err("invalid request when parsing", .{});
        posix.close(req.client_socket);
        return;
    };

    if (parsed_req.method == Method.GET) {
        var res = Response{};
        if (std.mem.eql(u8, parsed_req.uri, "/")) {
            res.status = 200;
            res.body = index_html;
        } else {
            res.status = 404;
            res.body = "<html><body><h1>File not found!</h1></body></html>";
        }
        try self.addWriteRequest(req.client_socket, res);
    } else {
        std.log.warn("encountered a non GET method!", .{});
        posix.close(req.client_socket);
    }
}

fn addWriteRequest(self: *Server, client_socket: posix.socket_t, res: Response) !void {
    const req: *Request = try self.req_pool.create();
    req.event_type = EventType.WRITE;
    req.client_socket = client_socket;
    req.body = res.body;

    const body_len = req.body.len;
    req.headers = try std.fmt.bufPrint(&req.header_buffer, HEADER_TEMPLATE, .{
        res.status,
        body_len,
    });

    req.iovecs = .{ .{ .base = req.headers.ptr, .len = req.headers.len }, .{ .base = req.body.ptr, .len = body_len } };

    const user_data = @intFromPtr(req);

    _ = try self.ring.writev(user_data, req.client_socket, req.iovecs[0..], 0);
    _ = try self.ring.submit();
}
