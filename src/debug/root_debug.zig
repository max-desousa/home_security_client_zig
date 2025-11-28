const std = @import("std");
const builtin = @import("builtin");

pub fn print(comptime fmt: []const u8, args: anytype) void {
    if (.Debug != builtin.mode) return;
    std.debug.print(fmt, args);
}
