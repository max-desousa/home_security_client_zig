//! Thread layout for `-Dnumber_of_cores=1`. Not implemented.

const std = @import("std");
const Camera = @import("camera");

/// Placeholder. Hits `unreachable`.
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
