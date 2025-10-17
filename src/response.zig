pub const Response = @This();

const std = @import("std");

status: u16 = 200,
body: []const u8 = "",
