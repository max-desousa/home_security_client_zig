const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");
const sys = @import("sys");
const Camera = @import("camera");
const coreLayouts = @import("coreLayouts");
const encoding = @import("encoding");
const amh = @import("amh");

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

    config.establish_config(io) catch {
        @panic("Something went wrong with reading the config");
    };

    //Make sure that there is a path to store the files.
    //The path makes cleanup simpler as we progress the project, and builds out
    //the ability for meshed uploading in the future. (Dedicated folders for
    //different cameras if this client is also a server)
    try sys.establish_directories(io, allocator);

    // Try to create camera object (making sure system works) before starting 
    // multithreaded portion.
    var camera_obj = try Camera.init(config.get_camera_hardware_name(), allocator);
    defer camera_obj.deinit();

    var Videos_To_Uplaod : std.atomic.Value(bool) = .init(false);

    var group : std.Io.Group = .init;
    defer group.await(io) catch {};

    var buffer_for_frames_to_encode : [32]usize = undefined;
    var frames_to_encode : std.Io.Queue(usize) = .init(&buffer_for_frames_to_encode);
    var buffer_for_frames_to_requeue : [32]usize = undefined;
    var frames_to_requeue : std.Io.Queue(usize) = .init(&buffer_for_frames_to_requeue);

    try group.concurrent(io, encoding.encoding_thread, .{ io, allocator, camera_obj.frame_metadata, &frames_to_encode, &frames_to_requeue , &Videos_To_Uplaod });
    try group.concurrent(io, Camera.infinite_capture, .{&camera_obj, io, &frames_to_encode, &frames_to_requeue });
    try group.concurrent(io, amh.artifact_management_thread, .{ io, allocator, &Videos_To_Uplaod });

}
