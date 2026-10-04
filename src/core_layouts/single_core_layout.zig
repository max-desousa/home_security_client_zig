const std = @import("std");
const Camera = @import("camera");

pub fn start(
    io : std.Io,
    allocator : std.mem.Allocator,
    camera : *Camera,
) !void {
    _ = &io;
    _ = &allocator;
    _ = &camera;
    unreachable;
}
