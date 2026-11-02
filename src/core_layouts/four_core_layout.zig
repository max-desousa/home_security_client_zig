//! Default thread layout, used when `-Dnumber_of_cores` is greater than 3.
//!
//! Three threads share two queues of V4L2 buffer indexes:
//! - `encoding.encoding_thread` takes indexes from `frames_to_encode` and
//!   returns them on `frames_to_requeue`.
//! - `Camera.infinite_capture` does the opposite.
//! - `amh.artifact_management_thread` uploads finished clips. The encoder
//!   sets `Videos_To_Uplaod` when a file is ready.
//!
//! This layout does not start `sys.file_cleanup_thread`.

const std = @import("std");
const Camera = @import("camera");
const encoding = @import("encoding");
const amh = @import("amh");

var Videos_To_Uplaod : std.atomic.Value(bool) = .init(false);

/// Spawn the encoder, camera, and artifact threads on `io` and return.
/// The `defer group.await` waits for them before `start` actually returns.
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
