const std = @import("std");
const camera = @import("camera");

pub fn perfect_core_layout() !void {
    // Implementation for perfect core layout
    std.debug.print("Using perfect core layout\n", .{});
    const gpa = std.heap.c_allocator;

    var cam = try camera.init("/dev/video0", gpa);
    _ = &cam;
}
