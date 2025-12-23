const std = @import("std");
const builtin = @import("builtin");
const camera = @import("camera");
const encoding = @import("encoding");
const debug = @import("debug");
const sync = @import("sync_data");
const config = @import("config");

const SIGNALS = [_]i32{
    std.os.SIG.INT,
};

pub fn perfect_core_layout() !void {
    try config.establish_config();

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

    debug.print("====================\n", .{});
    debug.print("Establishing synchronous data\n", .{});
    var sync_data: sync.SynchronousData = .{};

    debug.print("====================\n", .{});

    debug.print("Starting encoder thread\n", .{});
    try pool.spawn(encoding.encoding_thread, .{&sync_data});

    debug.print("Starting capture thread\n", .{});
    try pool.spawn(camera.run, .{config.get_camera_hardware_name(), allocator, &sync_data });
}
