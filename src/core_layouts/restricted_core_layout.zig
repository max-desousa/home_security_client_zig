const std = @import("std");
const camera = @import("camera");

pub fn restricted_core_layout() !void {
    // Implementation for restricted core layout
    std.debug.print("Using restricted core layout\n", .{});

    try camera.init();
}
