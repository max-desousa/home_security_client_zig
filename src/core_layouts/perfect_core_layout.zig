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

var DEBUG_ALLOCATOR : std.heap.DebugAllocator(.{}) = .init;

pub fn perfect_core_layout() !void {
    debug.print("Using perfect core layout\n", .{});
    debug.print("Initializing allocators\n", .{});
    const allocator : std.mem.Allocator = comptime switch (builtin.mode) {
        .Debug => DEBUG_ALLOCATOR.allocator(),
        else => std.heap.c_allocator,
    };
    defer {
        if (.Debug == builtin.mode) {
            _ = DEBUG_ALLOCATOR.deinit();
        }
    }

    var threaded : std.Io.Threaded = .init(allocator);
    defer threaded.deinit();

    const io = threaded.io();

    try config.establish_config(io);
    var camera_obj = try camera.init(config.get_camera_hardware_name(), allocator);
    defer camera_obj.deinit();

    var pool: std.Thread.Pool = undefined;
    try std.Thread.Pool.init(&pool, .{ .allocator = allocator });
    defer pool.deinit();

    var sync_data: sync.SynchronousData = .{};

    try pool.spawn(encoding.encoding_thread, .{&sync_data, allocator});

    try pool.spawn(camera.run, .{&camera_obj, &sync_data });
}
