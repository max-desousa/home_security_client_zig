const std = @import("std");
const Camera = @import("camera");
const options = @import("options");

pub fn startSecurityCamera(
    io : std.Io,
    allocator : std.mem.Allocator,
    camera : *Camera,
) !void {
    const start = comptime switch (options.numberOfCores) {
        1 => @import("single_core_layout.zig").start,
        2 => @import("two_core_layout.zig").start,
        3 => @import("three_core_layout.zig").start,
        else => @import("four_core_layout.zig").start,
    };

    try start(io, allocator, camera);
}
