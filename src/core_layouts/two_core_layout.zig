//! Thread layout for `-Dnumber_of_cores=2`.
//!
//! Spawns the encoder, the camera thread, `net.upload_thread`, and, unless
//! the cleanup strategy is `NoDeletions`, `sys.file_cleanup_thread`.
//! `upload_thread` is not a declaration in the net module, and the call to
//! `encoding_thread` omits `upload_flag`, so this file does not type-check.
//! It is compiled only when the build option is exactly 2.

const std = @import("std");
const Camera = @import("camera");
const encoding = @import("encoding");
const net = @import("net");
const config = @import("config");
const sync = @import("sync_data");
const sys = @import("sys");

/// Spawn the two-core threads. See the module note for why this does not build.
pub fn start(
    io : std.Io,
    allocator : std.mem.Allocator,
    camera : *Camera,
) !void {
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
