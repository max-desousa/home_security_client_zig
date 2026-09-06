const std = @import("std");
const camera = @import("camera");
const debug = @import("debug");

pub fn main() !void {
    // Implementation for single core layout
    debug.print("Using single core layout\n", .{});

    try camera.init();
}
