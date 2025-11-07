const std = @import("std");
const camera = @import("camera");

pub fn perfect_core_layout() !void {
    // Implementation for perfect core layout
    std.debug.print("Using perfect core layout\n", .{});

    try camera.init();
}
