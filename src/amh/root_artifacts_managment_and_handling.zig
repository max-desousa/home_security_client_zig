//! Upload thread used by the four-core layout.
//!
//! Every pass calls `net.upload_all_possible_videos`. While `upload_flag` is
//! false the thread sleeps for `config.get_upload_delay_milis` first. The
//! encoder stores `true` after it closes a clip and nobody clears the flag,
//! so from then on the thread uploads in a tight loop. Deletion of uploaded
//! files is not called (`delete_according_to_config_settings` is commented out).

const std = @import("std");
const config = @import("config");
const net = @import("net");

/// Run `failable_version_of_artifact_management_thread` and log its error.
///
/// The core layout passes the same `upload_flag` the encoder sets after it
/// closes a clip.
pub fn artifact_management_thread(
    io : std.Io,
    allocator : std.mem.Allocator,
    upload_flag : *std.atomic.Value(bool),
) void {
    failable_version_of_artifact_management_thread(
        io,
        allocator,
        upload_flag,
    ) catch |err| {
        std.log.err("The thread for uploading/cleaning artifacts has aborted due to: {any}", .{ err });
    };
}

/// Sleep while `upload_flag` is clear, then upload every pending clip.
///
/// Returns when `io` is cancelled. The `error.NotYetImplemented` after the
/// infinite loop is unreachable.
pub fn failable_version_of_artifact_management_thread(
    io : std.Io,
    allocator : std.mem.Allocator,
    upload_flag : *std.atomic.Value(bool),
) !void {
    while (true) {
        io.checkCancel() catch {
            std.log.debug("Quitting artifact management thread due to io cancelation", .{});
            return;
        };

        if (false == upload_flag.load(.seq_cst)) {
            std.log.info("Thread wants to sleep for {d} milliseconds", .{ config.get_upload_delay_milis() });
            try std.Io.sleep(io, .fromMilliseconds(@as(i64, config.get_upload_delay_milis())), .real);
        }

        std.log.debug("Checking for videos to upload", .{});
        const upload_result = net.upload_all_possible_videos(io, allocator);
        _ = &upload_result;
        //delete_according_to_config_settings();
    }
    return error.NotYetImplemented;
}
