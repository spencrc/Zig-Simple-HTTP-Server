const std = @import("std");
const builtin = @import("builtin");
const net = @import("std").net;

pub const SocketOptions = struct {
    host: [4]u8 = [4]u8{ 127, 0, 0, 1 },
    port: u16 = 3001,
};

pub const Socket = struct {
    _address: std.net.Address,
    _stream: std.net.Stream,

    pub fn init(options: SocketOptions) !Socket {
        const addr = net.Address.initIp4(options.host, options.port);
        const socket = try std.posix.socket(addr.any.family, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP);

        const stream = net.Stream{ .handle = socket };
        return Socket{ ._address = addr, ._stream = stream };
    }

    pub fn print_address(self: Socket, writer: *std.Io.Writer) !void {
        try self._address.in.format(writer);
    }
};
