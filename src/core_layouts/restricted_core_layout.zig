const std = @import("std");
const camera = @import("camera");
const debug = @import("debug");

pub fn restricted_core_layout() !void {
    // Implementation for restricted core layout
    debug.print("Using restricted core layout\n", .{});

    try camera.init();
}
