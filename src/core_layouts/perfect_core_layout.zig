const std = @import("std");
const builtin = @import("builtin");
const camera = @import("camera");
const encoding = @import("encoding");
const debug = @import("debug");
const sync = @import("sync_data");
const config = @import("config");
const net = @import("net");

const SIGNALS = [_]i32{
    std.os.SIG.INT,
};

// Bringing the debug allocator as seperate object dut to seperate deinit
// process. (release builds don't have deinit in the same way. So we need
// access to this parent object)
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

    var threaded : std.Io.Threaded = .init(allocator, .{ .environ = .empty });
    defer threaded.deinit();

    const io = threaded.io();

    try config.establish_config(io);
    var camera_obj = try camera.init(config.get_camera_hardware_name(), allocator);
    defer camera_obj.deinit();

    var group : std.Io.Group = .init;
    defer group.await(io) catch {};

    var sync_data: sync.SynchronousData = .{};
    var upload_data : sync.UploadData = .init(allocator, io);

    try group.concurrent(io, encoding.encoding_thread, .{&sync_data, allocator, io, &upload_data});
    try group.concurrent(io, camera.infinite_capture, .{&camera_obj, io, &sync_data});
    try group.concurrent(io, net.upload_thread, .{ io, &upload_data });
}
