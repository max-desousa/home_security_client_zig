const std = @import("std");
const config = @import("config");
const net = @import("net");

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
