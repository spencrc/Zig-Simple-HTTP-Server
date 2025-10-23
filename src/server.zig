const Server = @This();

const std = @import("std");
const posix = std.posix;
const static = @import("static.zig");
const config = @import("config");
const types = @import("types.zig");
const parser = @import("parser.zig");

const IoUring = std.os.linux.IoUring;
const RingRequest = types.RingRequest;
const Method = types.Method;
const HttpRequest = types.HttpRequest;
const HttpResponse = types.HttpResponse;
const EventType = types.EventType;

const HEADER_TEMPLATE = //please see write function for what gets placed in formatting specifiers
    "HTTP/1.1 {d} \r\n" ++
    "Content-Length: {d} \r\n" ++
    "Content-Type: {s} \r\n" ++
    "Connection: {s}\r\n\r\n";

ring: IoUring,
req_pool: std.heap.MemoryPool(RingRequest),
read_buffers: [config.num_read_buffers][config.read_buffer_length]u8 = undefined,
read_buffers_left: usize = 0,

pub fn init(allocator: std.mem.Allocator) !Server {
    const ring = try IoUring.init(config.io_uring_entries, 0);

    return .{
        .ring = ring,
        .req_pool = std.heap.MemoryPool(RingRequest).init(allocator),
    };
}

pub fn deinit(self: *Server) void {
    self.ring.deinit();
    self.req_pool.deinit();
}

pub fn run(self: *Server, address: std.net.Address) !void {
    const listener = try posix.socket(address.any.family, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);

    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));

    try posix.bind(listener, &address.any, address.getOsSockLen());
    try posix.listen(listener, config.kernel_backlog);

    try self.queue_all_buffers();

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

        const req: *RingRequest = @ptrFromInt(cqe.user_data);
        if (cqe.res < 0) {
            std.log.err("async requested failed - {d} for event {any}", .{ cqe.res, req.event_type });
            posix.close(req.client_socket);
            self.req_pool.destroy(req);
            continue;
        }

        switch (req.event_type) {
            .ACCEPT => {
                //var timer = try std.time.Timer.start();
                try self.queue_accept_request(listener, &client_address, &client_address_len);
                self.req_pool.destroy(req);
                try self.queue_read_request(cqe.res);
                _ = try self.ring.submit();
                // const elapsed_ns = timer.read();
                // std.debug.print("Accepting took {d:.6}ms\n", .{@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000});
            },
            .READ => {
                //var timer = try std.time.Timer.start();
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
                // const elapsed_ns = timer.read();
                // std.debug.print("Reading took {d:.6}ms\n", .{@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000});
            },
            .WRITE => {
                // var timer = try std.time.Timer.start();
                if (req.keep_alive) {
                    try self.queue_read_request(req.client_socket);
                    _ = try self.ring.submit();
                } else {
                    posix.close(req.client_socket);
                }
                self.req_pool.destroy(req);
                // const elapsed_ns = timer.read();
                // std.debug.print("Writing took {d:.6}ms\n", .{@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000});
            },
        }
    }
}

fn queue_all_buffers(self: *Server) !void {
    _ = try self.ring.provide_buffers(0xbf, @ptrCast(&self.read_buffers), config.read_buffer_length, config.num_read_buffers, config.read_buffer_group_id, 0);
}

fn queue_accept_request(self: *Server, listener: posix.socket_t, client_address: *posix.sockaddr, client_address_len: *posix.socklen_t) !void {
    const req: *RingRequest = try self.req_pool.create();
    req.event_type = EventType.ACCEPT;

    const user_data = @intFromPtr(req);

    _ = try self.ring.accept(user_data, listener, client_address, client_address_len, 0);
}

fn queue_read_request(self: *Server, socket: posix.socket_t) !void {
    const req: *RingRequest = try self.req_pool.create();
    req.event_type = EventType.READ;
    req.client_socket = socket;

    const user_data = @intFromPtr(req);

    self.read_buffers_left -|= 1;
    if (self.read_buffers_left == 0) {
        //reprovide buffers
        try self.queue_all_buffers();
        _ = try self.ring.submit();
    }
    const read_buffer = IoUring.ReadBuffer{ .buffer_selection = .{ .group_id = config.read_buffer_group_id, .len = config.read_buffer_length } };

    _ = try self.ring.read(user_data, req.client_socket, read_buffer, 0); //for whatever reason, read seems to be more stable than recv during benchmarking
}

fn handle_client_request(self: *Server, req: *RingRequest, buffer_id: u16, read_length: usize) !void {
    //var timer = try std.time.Timer.start();
    //std.debug.print("\nClient Request\n{s}\n\n", .{self.read_buffers[buffer_id][0..read_length]}); //view contents of buffer after reading/parsing is done
    const parsed_http_req: HttpRequest = parser.parse(self.read_buffers[buffer_id][0..read_length]) catch {
        std.log.err("invalid HTTP request when parsing", .{});
        posix.close(req.client_socket);
        return;
    };

    if (parsed_http_req.method == Method.GET) {
        var http_res = HttpResponse{};
        const file_data = static.files.get(parsed_http_req.uri.path);
        if (file_data != null) {
            http_res.status = 200;
            http_res.body = file_data.?.contents;
            http_res.type = file_data.?.mime_type;
        } else {
            http_res.type = "html/text";
            http_res.status = 404;
            http_res.body = "<html><body><h1>File not found!</h1></body></html>";
        }
        // const elapsed_ns = timer.read();
        // std.debug.print("handle_client_request took {d:.6}ms\n", .{@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000});
        try self.submit_write_request(req.client_socket, parsed_http_req.keep_alive, http_res);
    } else {
        std.log.warn("encountered a non GET method!", .{});
        posix.close(req.client_socket);
    }
}

fn submit_write_request(self: *Server, client_socket: posix.socket_t, keep_alive: bool, http_res: HttpResponse) !void {
    //var timer = try std.time.Timer.start();
    const req: *RingRequest = try self.req_pool.create();
    req.event_type = EventType.WRITE;
    req.client_socket = client_socket;
    req.body = http_res.body;
    req.keep_alive = keep_alive;

    const body_len = req.body.len;
    const keep_alive_string = if (keep_alive) "keep-alive" else "close";

    var fbs = std.io.fixedBufferStream(&req.header_buffer);
    const writer = fbs.writer();
    try writer.print(HEADER_TEMPLATE, .{ http_res.status, body_len, http_res.type, keep_alive_string });
    req.headers = fbs.getWritten();

    req.iovecs = .{ .{ .base = req.headers.ptr, .len = req.headers.len }, .{ .base = req.body.ptr, .len = body_len } };

    const user_data = @intFromPtr(req);

    _ = try self.ring.writev(user_data, req.client_socket, req.iovecs[0..], 0);
    _ = try self.ring.submit();
    // const elapsed_ns = timer.read();
    // std.debug.print("submit_write_request took {d:.6}ms\n", .{@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000});
}
