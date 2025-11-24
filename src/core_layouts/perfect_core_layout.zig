const std = @import("std");
const builtin = @import("builtin");
const camera = @import("camera");
const encoding = @import("encoding");
const debug = @import("debug");
const sync = @import("sync_data");

pub fn perfect_core_layout() !void {
    // Implementation for perfect core layout
    debug.print("Using perfect core layout\n", .{});

    debug.print("====================\n", .{});
    debug.print("Initializing thread pool and allocators... (using new Io concurrent)\n", .{});
    const allocator = blk: {
        if (.ReleaseFast == builtin.mode) {
            break :blk std.heap.smp_allocator;
        } else {
            var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
            break :blk gpa.allocator();
        }
    };

    var pool: std.Thread.Pool = undefined;
    try std.Thread.Pool.init(&pool, .{ .allocator = allocator });
    defer pool.deinit();

    debug.print("====================\n", .{});

    debug.print("Checking for and setting up camera - don't bother running without valid camera\n", .{});
    var cam = try camera.init("/dev/video0", allocator);
    defer cam.deinit();

    debug.print("====================\n", .{});
    debug.print("Establishing synchronous data\n", .{});
    var sync_data: sync.SynchronousData = .{};

    debug.print("====================\n", .{});

    debug.print("Starting encoder thread\n", .{});
    try pool.spawn(encoding.encoder_thread, .{&sync_data});

    debug.print("Starting capture thread\n", .{});
    try pool.spawn(cam.infinite_capture, .{&sync_data});
}
