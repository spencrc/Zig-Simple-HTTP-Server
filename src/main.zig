const std = @import("std");
const posix = std.posix;
const request = @import("request.zig");
const static = @import("static");
const linux = std.os.linux;

const Response = @import("response.zig").Response;
const Method = request.Method;
const Stream = std.net.Stream;
const Address = std.net.Address;

const EventType = enum(u8) { ACCEPT, READ, WRITE };

const Client = struct {
    allocator: *std.mem.Allocator,
    client_socket: posix.socket_t,
    buffer: []u8,

    fn init(allocator: *std.mem.Allocator, socket: posix.socket_t) !Client {
        const buffer = try allocator.alloc(u8, 4096);
        @memset(buffer, 0); //done to make buffer readable

        return .{
            .allocator = allocator,
            .client_socket = socket,
            .buffer = buffer,
        };
    }

    fn deinit(self: *Client, allocator: *std.mem.Allocator) void {
        allocator.free(self.buffer);
        allocator.destroy(self);
    }
};

const Event = struct {
    ptr: ?*Client,
    event_type: EventType,

    fn init(ptr: ?*Client, event_type: EventType) Event {
        return .{ .ptr = ptr, .event_type = event_type };
    }
};

//TODO: replace assetpack (it's good for now) with relative path file loading for hot loading
var index_html: []const u8 = undefined;

fn handleConnection(stream: *Stream) void {
    //TODO: fix autocannon error: { errno -104, code 'ECONNRESET', syscall: 'read' }

    var buffer: [4096]u8 = undefined;
    @memset(&buffer, 0); //done to make buffer readable

    request.read_request(stream, &buffer);
    const req = request.parse_request(&buffer) catch |err| {
        std.log.err("Invalid request when parsing: {any}", .{err});
        return;
    };

    std.debug.print("\nClient Request\n{s}\n\n", .{buffer}); //view contents of buffer after reading/parsing is done

    var res = Response.init(stream);

    if (req.method == Method.GET) {
        if (std.mem.eql(u8, req.uri, "/")) {
            res.body = index_html;

            res.write() catch |err| {
                std.log.err("Error when writing response: {any}", .{err});
            };
        } else {
            res.status = 404;
            res.body = "<html><body><h1>File not found!</h1></body></html>";

            res.write() catch |err| {
                std.log.err("Error when writing response: {any}", .{err});
            };
        }
    }
}

fn addAcceptRequest(ring: *linux.IoUring, listener: posix.socket_t, allocator: *std.mem.Allocator) !void {
    const event = try allocator.create(Event);
    event.* = Event.init(null, .ACCEPT);

    var address: posix.sockaddr = undefined;
    var address_len: posix.socklen_t = @sizeOf(posix.sockaddr);

    const user_data: usize = @intFromPtr(event);
    std.debug.print("ACCEPT - user_data: {any}\n", .{user_data});
    _ = try ring.accept(user_data, listener, &address, &address_len, 0);
    const num_submitted = try ring.submit();
    std.debug.print("ACCEPT - num_submitted: {any}\n", .{num_submitted});
}

fn addReadRequest(ring: *linux.IoUring, client_socket: posix.socket_t, allocator: *std.mem.Allocator) !void {
    const client = try allocator.create(Client);
    client.* = try Client.init(allocator, client_socket);

    const event = try allocator.create(Event);
    event.* = Event.init(client, .READ);

    const read_buffer = linux.IoUring.ReadBuffer{ .buffer = client.buffer[0..] };
    const user_data: usize = @intFromPtr(event);

    _ = try ring.read(user_data, client.client_socket, read_buffer, 0);
    const num_submitted = try ring.submit();
    std.debug.print("READ - num_submitted: {any}\n", .{num_submitted});
}

fn handleRequest(client: *Client) void {
    _ = request.parse_request(client.buffer) catch |err| {
        std.log.err("Invalid request when parsing: {any}", .{err});
        return;
    };

    std.debug.print("\nClient Request\n{s}\n\n", .{client.buffer}); //view contents of buffer after reading/parsing is done
}

pub fn main() !void {
    //TODO: cache files properly in a production setting
    index_html = try static.root.file("index.html"); //currently just pre-loads by setting global variable

    const host = [4]u8{ 127, 0, 0, 1 };
    const port = 3000;

    const addr = Address.initIp4(host, port);

    {
        var buffer: [64]u8 = undefined;
        const stderr = std.debug.lockStderrWriter(&buffer);
        defer std.debug.unlockStderrWriter();

        try stderr.print("Listening at http://", .{});
        try addr.in.format(stderr);
        try stderr.print("\n", .{});
        try stderr.flush();
    }

    const sock_fd = try posix.socket(addr.any.family, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, posix.IPPROTO.TCP);
    //defer posix.close(sock_fd);

    try posix.setsockopt(sock_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

    try posix.bind(sock_fd, &addr.any, addr.getOsSockLen());
    try posix.listen(sock_fd, 1024);

    var ring = try linux.IoUring.init(256, 0);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();

    //var client_pool = std.heap.MemoryPool(Client).init(allocator);

    try addAcceptRequest(&ring, sock_fd, &allocator);

    while (true) {
        //TODO: add threading here
        var cqe = try ring.copy_cqe();
        std.debug.print("cqe: {any}\n", .{cqe});
        std.debug.print("user_data: {any}\n", .{cqe.user_data});
        const event: *Event = @ptrFromInt(cqe.user_data);
        std.debug.print("event: {any}\n", .{event.*});

        switch (event.event_type) {
            .ACCEPT => {
                try addAcceptRequest(&ring, sock_fd, &allocator);
                try addReadRequest(&ring, cqe.res, &allocator);
            },
            .READ => {
                std.debug.print("HELLO!!!", .{});
                handleRequest(event.ptr.?);
            },
            .WRITE => {},
        }

        ring.cqe_seen(&cqe);

        // var stream: Stream = .{ .handle = conn_fd };

        // handleConnection(&stream);
    }
}
