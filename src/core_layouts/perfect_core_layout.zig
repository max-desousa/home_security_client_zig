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

pub fn main() !void {
    const allocator : std.mem.Allocator = comptime switch (builtin.mode) {
        .debug => DEBUG_ALLOCATOR.allocator(),
        else => std.heap.c_allocator,
    };
    defer {
        if (.debug == builtin.mode) {
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
    try sys.establish_directories(io, allocator);

    // Try to create camera object (making sure system works) before starting 
    // multithreaded portion.
    var camera_obj = try camera.init(config.get_camera_hardware_name(), allocator);
    defer camera_obj.deinit();

    var group : std.Io.Group = .init;
    defer group.await(io) catch {};

    // Create data stuctures for sharing data between threads.
    var sync_data: sync.SynchronousData = .{};

    var buffer_for_frames_to_encode : [32]usize = undefined;
    var frames_to_encode : std.Io.Queue(usize) = .init(&buffer_for_frames_to_encode);
    var buffer_for_frames_to_requeue : [32]usize = undefined;
    var frames_to_requeue : std.Io.Queue(usize) = .init(&buffer_for_frames_to_requeue);

    try group.concurrent(io, encoding.encoding_thread, .{ io, allocator, camera_obj.frame_metadata, &frames_to_encode, &frames_to_requeue });
    try group.concurrent(io, camera.infinite_capture, .{&camera_obj, io, &frames_to_encode, &frames_to_requeue });
    try group.concurrent(io, net.upload_thread, .{ allocator, io, &sync_data });
    if (.NoDeletions != config.get_cleanup_stategy()) {
        try group.concurrent(io, sys.file_cleanup_thread, .{ allocator, io });
    }
}
