const std = @import("std");
const camera = @import("camera");

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

    try pool.spawn(capture_thread, .{});
    try pool.spawn(encoding_thread, .{});
}

fn capture_thread() void {
    const gpa = std.heap.c_allocator;

    var cam = camera.init("/dev/video0", gpa) catch return;
    defer cam.deinit();

    std.debug.print("Number of buffers in camera: {d}\n", .{cam.buffers.len});
    cam.start_capturing() catch return;
    cam.capture_frames_infinitely() catch return;
}

fn encoding_thread() void {
    while (true) {
        const lock_state = DATA.mutex.tryLock();
        defer DATA.mutex.unlock();
        std.debug.print("Data lock state = {b]\n", .{lock_state});
    }
}
