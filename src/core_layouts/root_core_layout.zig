//! Chooses a thread layout from the `number_of_cores` build option.
//!
//! `-Dnumber_of_cores=1`, `2`, or `3` select that layout file. Any other
//! count, including the default (the host CPU count), selects
//! `four_core_layout.zig`. Only the selected file is compiled.

const std = @import("std");
const Camera = @import("camera");
const options = @import("options");

/// Run the layout selected at build time.
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
