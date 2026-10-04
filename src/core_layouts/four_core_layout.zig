const std = @import("std");
const builtin = @import("builtin");
const Camera = @import("camera");
const encoding = @import("encoding");
const sync = @import("sync_data");
const config = @import("config");
const net = @import("net");
const sys = @import("sys");

pub fn start(
    io : std.Io,
    allocator : std.mem.Allocator,
    camera : *Camera,
) !void {
    // Establish/Read config file to determine specific behaviors.
    config.establish_config(io) catch {
        @panic("Something went wrong with the file");
    };
    var group : std.Io.Group = .init;
    defer group.await(io) catch {};

    // Create data stuctures for sharing data between threads.
    var sync_data: sync.SynchronousData = .{};

    var buffer_for_frames_to_encode : [32]usize = undefined;
    var frames_to_encode : std.Io.Queue(usize) = .init(&buffer_for_frames_to_encode);
    var buffer_for_frames_to_requeue : [32]usize = undefined;
    var frames_to_requeue : std.Io.Queue(usize) = .init(&buffer_for_frames_to_requeue);

    try group.concurrent(io, encoding.encoding_thread, .{ io, allocator, camera.frame_metadata, &frames_to_encode, &frames_to_requeue });
    try group.concurrent(io, Camera.infinite_capture, .{camera, io, &frames_to_encode, &frames_to_requeue });
    try group.concurrent(io, net.upload_thread, .{ allocator, io, &sync_data });
    if (.NoDeletions != config.get_cleanup_stategy()) {
        try group.concurrent(io, sys.file_cleanup_thread, .{ allocator, io });
    }
}
