const Server = @This();

const std = @import("std");
const posix = std.posix;
const static = @import("static");
const config = @import("config");

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
    header_buffer: [220]u8 = undefined,
    body: []const u8 = "",
    headers: []u8 = undefined,
};

//TODO: replace assetpack (it's good for now) with relative path file loading for hot loading
var index_html: []const u8 = undefined;

ring: IoUring,
req_pool: std.heap.MemoryPool(Request),
read_buffers: [config.num_read_buffers][config.read_buffer_length]u8 = undefined,
read_buffers_left: usize = 0,

pub fn init(allocator: std.mem.Allocator) !Server {
    const ring = try IoUring.init(4096, 0);

    return .{
        .ring = ring,
        .req_pool = std.heap.MemoryPool(Request).init(allocator),
    };
}

pub fn deinit(self: *Server) void {
    self.ring.deinit();
    self.req_pool.deinit();
}

pub fn run(self: *Server, address: std.net.Address) !void {
    index_html = try static.root.file("index.html"); //currently just pre-loads by setting global variable

    const listener = try posix.socket(address.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);

    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));

    try posix.bind(listener, &address.any, address.getOsSockLen());
    try posix.listen(listener, 1024);

    _ = try self.ring.provide_buffers(0xbf, @ptrCast(&self.read_buffers), config.read_buffer_length, config.num_read_buffers, config.read_buffer_group_id, 0);

    var client_address: posix.sockaddr = undefined;
    var client_address_len: posix.socklen_t = @sizeOf(posix.sockaddr);
    try self.queue_accept_request(listener, &client_address, &client_address_len);
    _ = try self.ring.submit();

    while (true) {
        //TODO: add threading here
        const cqe = try self.ring.copy_cqe();

        if (cqe.user_data == 0xbf) { //0xbf is the special code for when all buffers handled via provide_buffers completion
            if (cqe.res == 0) { //0 means success here (https://ziglang.org/documentation/master/std/#std.os.linux.E)!
                self.read_buffers_left = config.num_read_buffers; //all buffers available again
                continue;
            } else {
                return;
            }
        } else if (cqe.user_data == 0xbf1) { //0xbf1 is the special code for when just one buffer handled by provide_buffers completion
            if (cqe.res == 0) { //0 means success here (https://ziglang.org/documentation/master/std/#std.os.linux.E)!
                self.read_buffers_left += 1; //one more buffer available
                continue;
            } else {
                return;
            }
        }

        const req: *Request = @ptrFromInt(cqe.user_data);
        if (cqe.res < 0) {
            std.log.err("async requested failed - {d} for event {any}\n", .{ cqe.res, req.event_type });
            return;
        }

        switch (req.event_type) {
            .ACCEPT => {
                try self.queue_accept_request(listener, &client_address, &client_address_len);
                self.req_pool.destroy(req);
                try self.queue_read_request(cqe.res);
                _ = try self.ring.submit();
            },
            .READ => {
                if (cqe.res <= 0) { //res = 0 is an empty result! anything less than 0 is an error
                    posix.close(req.client_socket);
                    self.req_pool.destroy(req);
                    continue;
                }

                const buffer_id = try cqe.buffer_id();
                const read_length: usize = @intCast(cqe.res);
                try self.handle_client_request(req, buffer_id, read_length);

                _ = try self.ring.provide_buffers(
                    0xbf1,
                    @ptrCast(&self.read_buffers[buffer_id]),
                    config.read_buffer_length,
                    1, // only one buffer
                    config.read_buffer_group_id,
                    buffer_id,
                );

                self.req_pool.destroy(req);
            },
            .WRITE => {
                posix.close(req.client_socket);

                self.req_pool.destroy(req);
            },
        }
    }
}

fn queue_accept_request(self: *Server, listener: posix.socket_t, client_address: *posix.sockaddr, client_address_len: *posix.socklen_t) !void {
    const req: *Request = try self.req_pool.create();
    req.event_type = EventType.ACCEPT;

    const user_data = @intFromPtr(req);

    _ = try self.ring.accept(user_data, listener, client_address, client_address_len, 0);
}

fn queue_read_request(self: *Server, socket: posix.socket_t) !void {
    const req: *Request = try self.req_pool.create();
    req.event_type = EventType.READ;
    req.client_socket = socket;

    const user_data = @intFromPtr(req);

    self.read_buffers_left -= 1;
    const read_buffer = IoUring.ReadBuffer{ .buffer_selection = .{ .group_id = config.read_buffer_group_id, .len = config.read_buffer_length } };

    _ = try self.ring.read(user_data, req.client_socket, read_buffer, 0); //for whatever reason, read seems to be more stable than recv during benchmarking
}

fn handle_client_request(self: *Server, req: *Request, buffer_id: u16, read_length: usize) !void {
    //std.debug.print("\nClient Request\n{s}\n\n", .{req.reading_buffer[0..bytes_read]}); //view contents of buffer after reading/parsing is done
    const parsed_req = http_request.parse_http_request(self.read_buffers[buffer_id][0..read_length]) catch {
        std.log.err("invalid HTTP request when parsing", .{});
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
        try self.submit_write_request(req.client_socket, res);
    } else {
        std.log.warn("encountered a non GET method!", .{});
        posix.close(req.client_socket);
    }
}

fn submit_write_request(self: *Server, client_socket: posix.socket_t, res: Response) !void {
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
