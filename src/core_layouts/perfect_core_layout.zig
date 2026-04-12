const std = @import("std");
const builtin = @import("builtin");
const camera = @import("camera");
const encoding = @import("encoding");
const debug = @import("debug");
const sync = @import("sync_data");
const config = @import("config");
const net = @import("net");
const sys = @import("sys");

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

    // Establish/Read config file to determine specific behaviors.
    config.establish_config(io) catch {
        @panic("Something went wrong with the file");
    };

    //Make sure that there is a path to store the files.
    //The path makes cleanup simpler as we progress the project, and builds out
    //the ability for meshed uploading in the future. (Dedicated folders for
    //different cameras if this client is also a server)
    try sys.establish_directories(io);

    // Try to create camera object (making sure system works) before starting 
    // multithreaded portion.
    var camera_obj = try camera.init(config.get_camera_hardware_name(), allocator);
    defer camera_obj.deinit();

    var group : std.Io.Group = .init;
    defer group.await(io) catch {};

    // Create data stuctures for sharing data between threads.
    var sync_data: sync.SynchronousData = .{};
    var shutdown_flag : std.atomic.Value(bool) = .init(false);

    try group.concurrent(io, encoding.encoding_thread, .{ io, allocator, *camera_obj.frame_cache });
    try group.concurrent(io, camera.infinite_capture, .{&camera_obj, io, &sync_data, &shutdown_flag});
    try group.concurrent(io, net.upload_thread, .{ allocator, io, &sync_data });
    if (.NoDeletions != config.get_cleanup_stategy()) {
        try group.concurrent(io, sys.file_cleanup_thread, .{ allocator, io, &shutdown_flag });
    }
}
