const std = @import("std");
const camera = @import("camera");

pub fn perfect_core_layout() !void {
    // Implementation for perfect core layout
    std.debug.print("Using perfect core layout\n", .{});
    const gpa = std.heap.c_allocator;

    var cam = try camera.init("/dev/video0", gpa);
    defer cam.deinit();

    std.debug.print("Number of buffers in camera: {d}\n", .{cam.buffers.len});
    try cam.start_capturing();
    try cam.capture_frames_infinitely();
}
