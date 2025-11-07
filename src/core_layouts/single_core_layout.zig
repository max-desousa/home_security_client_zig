const std = @import("std");
const camera = @import("camera");

pub fn single_core_layout() !void {
    // Implementation for single core layout
    std.debug.print("Using single core layout\n", .{});

    try camera.init();
}
