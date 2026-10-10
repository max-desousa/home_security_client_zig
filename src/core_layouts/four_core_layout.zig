const std = @import("std");
const Camera = @import("camera");
const encoding = @import("encoding");
const amh = @import("amh");

var Videos_To_Uplaod : std.atomic.Value(bool) = .init(false);

pub fn start(
    io : std.Io,
    allocator : std.mem.Allocator,
    camera : *Camera,
) !void {
    var group : std.Io.Group = .init;
    defer group.await(io) catch {};

    var buffer_for_frames_to_encode : [32]usize = undefined;
    var frames_to_encode : std.Io.Queue(usize) = .init(&buffer_for_frames_to_encode);
    var buffer_for_frames_to_requeue : [32]usize = undefined;
    var frames_to_requeue : std.Io.Queue(usize) = .init(&buffer_for_frames_to_requeue);

    try group.concurrent(io, encoding.encoding_thread, .{ io, allocator, camera.frame_metadata, &frames_to_encode, &frames_to_requeue , &Videos_To_Uplaod });
    try group.concurrent(io, Camera.infinite_capture, .{camera, io, &frames_to_encode, &frames_to_requeue });
    try group.concurrent(io, amh.artifact_management_thread, .{ io, allocator, &Videos_To_Uplaod });
}
