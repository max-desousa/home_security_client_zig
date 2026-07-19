//! Module that manages variables parsed from a file at runtime. 
//!
//! In The event that this file is not present, this module will also create the 
//! file while also setting the defaults I've deemed appropriate.
const std = @import("std");
const toml = @import("toml");

//Name of config file
const CONFIG_FILE_NAME = "config.toml";

pub const FileCleanupStrategy = enum {
    /// No deletions ever. Camera will eventually run out of space and
    /// crash/stop recording. User is fully responsible for external management
    /// or very large storage.
    NoDeletions,

    // ----------------------------------------------------------------------
    /// Delete any successfully archived file immediately. If uploads are
    /// failing and space is full, delete oldest *un-uploaded* files to keep
    /// recording. (Best for "fire-and-forget" with tolerance for flaky
    /// networks)
    DeleteArchivedImmediatelyUnprotected,

    /// Delete any successfully archived file immediately. If uploads are
    /// failing and space is full, **stop recording** to protect pending files.
    /// (Strictest "never lose un-uploaded footage" while still freeing space
    /// from uploaded files)
    DeleteArchivedImmediatelyProtected,

    // ----------------------------------------------------------------------
    /// Keep both archived and pending files up to the configured limit. When
    /// limit reached: delete oldest *archived* files first. If still full due
    /// to pending files (prolonged outage): **stop recording** (crash).
    GeneralProtected,

    /// Keep both archived and pending files up to the configured limit. When
    /// limit reached: delete oldest *archived* files first. If still full due
    /// to pending files: delete oldest *un-uploaded* files to keep recording.
    GeneralUnprotected,
};


const Config = struct {
    video_duration : u64,
    video_frame_rate : u16,
    video_width : u16,
    video_height : u16,
    video_crf : u8,
    camera_device_name : []const u8,
    camera_name_for_archiving : []const u8,
    crash_on_bad_cam_settings : bool,
    crash_poor_cam_performance : bool,
    utc_offset_seconds : i64,
    server_ip_address : []const u8,
    port_of_the_server : u16,
    upload_delay : u64,
    memory_storage_limit : u64,
    cleanup_strategy : FileCleanupStrategy,
};


/// Function to etablish config
pub fn establish_config(io : std.Io, allocator : std.mem.Allocator) !void {

    const file_present = blk: {
        if (std.Io.Dir.access(.cwd(), io, CONFIG_FILE_NAME, .{ .follow_symlinks = false })) {
            break :blk true;
        }
        else |_| {
            break :blk false;
        } 
    };

    if (!file_present) {
        try make_default_config(io);
    }

    var parser = toml.Parser(Config).init(allocator);
    defer parser.deinit();

    var result = try parser.parseFile(io, CONFIG_FILE_NAME);
    _ = &result;
}


// New IO isn't available on writers yet - this function WILL break
///Function to make default config file when it's not present at runtime
fn make_default_config(io : std.Io) !void {
    const new_file = try std.Io.Dir.createFile(
        std.Io.Dir.cwd(),
        io,
        CONFIG_FILE_NAME,
        .{});
    defer new_file.close(io);
    var writer_buffer : [512]u8 = undefined;
    //var writer = std.fs.File.Writer.init(new_file, &writer_buffer);
    var writer = std.Io.File.writer(new_file, io, &writer_buffer);
    defer writer.end() catch {};

    const default_toml = comptime @embedFile("default_config.toml");

    try writer.interface.writeAll(default_toml);
}
