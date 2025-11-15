const std = @import("std");
const camera = @import("camera");
const buffer_queue = @import("buffer_queue");

pub const linked_list = struct {
    data: u8,
    next: ?*linked_list,
};

pub const shared_data = struct {
    head: ?*linked_list,
    mutex: std.Io.Mutex,
};

var DATA: shared_data = .{
    .head = null,
    .mutex = std.Io.Mutex.init(),
};

pub fn perfect_core_layout() !void {
    // Implementation for perfect core layout
    std.debug.print("Using perfect core layout\n", .{});

    std.debug.print("Initializing thread pool...\n", .{});
    const allocator = std.heap.page_allocator;
    var pool: std.Thread.Pool = undefined;

    try pool.init(.{
        .allocator = allocator,
        .track_ids = true,
    });
    defer pool.deinit();

    const gpa = std.heap.c_allocator;

    var cam = camera.init("/dev/video0", gpa) catch return;
    defer cam.deinit();

    try pool.spawn(capture_thread, .{&cam});
    try pool.spawn(encoding_thread, .{&cam});
}

fn capture_thread(cam: *camera.Camera) void {
    std.debug.print("Number of buffers in camera: {d}\n", .{cam.buffers.len});
    cam.start_capturing() catch return;
    cam.capture_frames_infinitely() catch return;
}

fn encoding_thread(cam: *camera.Camera) void {
    _ = &cam;
    while (true) {
        const nullable_new_buffer = buffer_queue.EncodingBuffer.dequeue();
        if (nullable_new_buffer == null) continue;

        const new_buffer = nullable_new_buffer.?;
        std.debug.print("Encoding buffer number: {d}\n", .{new_buffer});
    }
}
