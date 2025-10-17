const std = @import("std");
const posix = std.posix;
const request = @import("request.zig");
const static = @import("static");
const linux = std.os.linux;

const Response = @import("response.zig").Response;
const Method = request.Method;
const Stream = std.net.Stream;
const Address = std.net.Address;

const EventType = enum(u64) { ACCEPT = 1, READ = 2, WRITE = 3 };

const Client = struct {
    client_socket: posix.socket_t,
    iovecs: [2]posix.iovec = undefined,
    buffer: []u8,

    fn init(allocator: std.mem.Allocator, socket: posix.socket_t) !Client {
        const buffer = try allocator.alloc(u8, 4096);

        return .{
            .client_socket = socket,
            .buffer = buffer,
        };
    }

    fn deinit(self: *Client, allocator: std.mem.Allocator) void {
        posix.close(self.client_socket);
        allocator.free(self.buffer);
        allocator.destroy(self);
    }
};

const AcceptRequest = extern struct {
    address: posix.sockaddr,
    address_len: posix.socklen_t,

    fn init() AcceptRequest {
        return .{ .address = undefined, .address_len = @sizeOf(posix.sockaddr) };
    }
};

const WriteRequest = extern struct {
    client: *Client,
    response: *Response,
    iovecs: [2]posix.iovec_const,

    fn init(client: *Client, res: *Response) WriteRequest {
        return .{ .client = client, .response = res, .iovecs = .{ .{ .base = res.headers.ptr, .len = res.headers.len }, .{ .base = res.body.ptr, .len = res.body.len } } };
    }

    fn deinit(self: *WriteRequest, allocator: std.mem.Allocator) void {
        self.client.deinit(allocator);
        allocator.free(self.response.headers);
        allocator.destroy(self.response);
        allocator.destroy(self);
    }
};

const EventPtr = union(enum) {
    client: *Client,
    accept: *AcceptRequest,
    write: *WriteRequest,

    none,
};

const Event = struct {
    ptr: EventPtr,
    event_type: EventType,

    fn initAccept(req: *AcceptRequest, event_type: EventType) Event {
        return .{ .ptr = .{ .accept = req }, .event_type = event_type };
    }

    fn initClient(client: *Client, event_type: EventType) Event {
        return .{ .ptr = .{ .client = client }, .event_type = event_type };
    }

    fn initWrite(req: *WriteRequest, event_type: EventType) Event {
        return .{ .ptr = .{ .write = req }, .event_type = event_type };
    }

    fn deinit(self: *Event, allocator: std.mem.Allocator) void {
        switch (self.ptr) {
            .accept => |a_req| allocator.destroy(a_req),
            .write => |w_req| w_req.deinit(allocator),
            else => {},
        }
        allocator.destroy(self);
    }
};

//TODO: replace assetpack (it's good for now) with relative path file loading for hot loading
var index_html: []const u8 = undefined;

fn addAcceptRequest(ring: *linux.IoUring, listener: posix.socket_t, allocator: std.mem.Allocator) !void {
    var req: *AcceptRequest = try allocator.create(AcceptRequest);
    req.* = AcceptRequest.init();

    const event: *Event = try allocator.create(Event);
    event.* = Event.initAccept(req, EventType.ACCEPT);

    const user_data = @intFromPtr(event);

    _ = try ring.accept_multishot(user_data, listener, &req.address, &req.address_len, 0);
    _ = try ring.submit();
}

fn addReadRequest(ring: *linux.IoUring, client: *Client, allocator: std.mem.Allocator) !void {
    const event: *Event = try allocator.create(Event);
    event.* = Event.initClient(client, EventType.READ);

    const user_data = @intFromPtr(event);

    const read_buffer = linux.IoUring.ReadBuffer{ .buffer = client.buffer[0..] };

    _ = try ring.read(user_data, client.client_socket, read_buffer, 0);
    _ = try ring.submit();
}

fn addWriteRequest(ring: *linux.IoUring, client: *Client, res: *Response, allocator: std.mem.Allocator) !void {
    const req: *WriteRequest = try allocator.create(WriteRequest);
    req.* = WriteRequest.init(client, res);

    const event: *Event = try allocator.create(Event);
    event.* = Event.initWrite(req, EventType.WRITE);

    const user_data = @intFromPtr(event);

    _ = try ring.writev(user_data, client.client_socket, &req.iovecs, 0);
    _ = try ring.submit();
}

fn handleRequest(ring: *linux.IoUring, client: *Client, allocator: std.mem.Allocator) !void {
    const req = request.parse_request(client.buffer) catch |err| {
        std.log.err("Invalid request when parsing: {any}", .{err});
        return;
    };

    //std.debug.print("\nClient Request\n{s}\n\n", .{client.buffer}); //view contents of buffer after reading/parsing is done

    const res = try allocator.create(Response);
    res.* = Response.init();

    if (req.method == Method.GET) {
        if (std.mem.eql(u8, req.uri, "/")) {
            res.body = @constCast(index_html);
            try res.prepareHeaders(allocator);
            try addWriteRequest(ring, client, res, allocator);
        } else {
            res.status = 404;
            res.body = "<html><body><h1>File not found!</h1></body></html>";
        }
    }
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
    const allocator = gpa.allocator();

    try addAcceptRequest(&ring, sock_fd, allocator);

    while (true) {
        //TODO: add threading here
        const cqe = try ring.copy_cqe();
        const user_data: *Event = @ptrFromInt(cqe.user_data);

        switch (user_data.event_type) {
            .ACCEPT => {
                try addAcceptRequest(&ring, sock_fd, allocator);

                const client: *Client = try allocator.create(Client);
                client.* = try Client.init(allocator, cqe.res);

                try addReadRequest(&ring, client, allocator);
                user_data.deinit(allocator);
            },
            .READ => {
                switch (user_data.ptr) {
                    .client => |client| {
                        try handleRequest(&ring, client, allocator);
                    },
                    else => {},
                }
                user_data.deinit(allocator);
            },
            .WRITE => {
                user_data.deinit(allocator);
            },
        }
    }
}
