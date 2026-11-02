//! Runtime settings loaded from `config.zap` in the process working directory.
//!
//! `establish_config` reads that file once, at startup. When the file is
//! missing it is created and the defaults in `make_default_config` are stored
//! both on disk and in the `VALUE_*` globals. Every other module reads those
//! globals through the `get_*` functions.
//!
//! `FileCleanupStrategy` is the policy the cleanup thread applies when
//! `Videos/` grows. `ConfigSpec` and `ConfigManager` are a separate comptime
//! sketch; the running client does not consult them.
const std = @import("std");

//Name of config file
const CONFIG_FILE_NAME = "config.zap";

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

//Fileds that are accepted/expected 
const FIELD_DURATION = "[video duration]";
const FIELD_HARDWARE_NAME = "[camera device name]";
const FIELD_FRAME_RATE = "[video: frame rate]";
const FIELD_WIDTH = "[video: width]";
const FIELD_HEIGHT = "[video: height]";
const FIELD_CRASH_ON_VID_DIFF = "[crash: on bad cam settings]";
const FIELD_CRASH_ON_POOR_PERF = "[crash: poor cam performance]";
const FIELD_CRF_VALUE = "[video: crf value]";
const FIELD_CAMERA_NAME = "[camera name for archiving]";
const FIELD_UTC_OFFSET_SECONDS = "[utc offset seconds]";
const FIELD_SERVER_ADDRESS = "[ip address of the server]";
const FIELD_SERVER_PORT = "[port of the server]";
const FIELD_MEMORY_ALLOC = "[amount of memory for local storage]";
const FIELD_CLEANUP_STRATEGY = "[strategy for cleanup (lookup options)]";
const FIELD_UPLOAD_DELAY = "[upload delay multiplier]";


// Variables backing global tracking of states
// These are private by nature
var VALUE_VIDEO_DURATION : u64 = undefined;
var BUFFER_FOR_VALUE_CAMERA_HARDWARE_NAME : [64]u8 = undefined;
var VALUE_CAMERA_HARDWARE_NAME : [:0]u8 = BUFFER_FOR_VALUE_CAMERA_HARDWARE_NAME[0..0 :0];
var VALUE_FRAME_RATE : u16 = undefined;
var VALUE_VIDEO_WIDTH : u16 = undefined;
var VALUE_VIDEO_HEIGHT : u16 = undefined;
var VALUE_CRASH_ON_VID_DIFF : bool = undefined;
var VALUE_CRASH_ON_POOR_PERF : bool = undefined;
var VALUE_CRF_VALUE : u8 = undefined;
var BUFFER_FOR_VALUE_CAMERA_NAME : [128]u8 = undefined;
var VALUE_CAMERA_NAME : [:0]u8 = BUFFER_FOR_VALUE_CAMERA_NAME[0..0 :0];
var VALUE_UTC_OFFSET_SECONDS : i64 = undefined;
var BUFFER_FOR_VALUE_SERVER_ADDRESS : [64]u8 = undefined;
var VALUE_SERVER_ADDRESS : [:0]u8 = BUFFER_FOR_VALUE_SERVER_ADDRESS[0..0 : 0];
var VALUE_SERVER_PORT : u16 = undefined;
var VALUE_MEMORY_ALLOC : u64 = undefined;
var BUFFER_FOR_CLEANUP_STRATEGY : [64]u8 = undefined;
var STRING_FOR_CLEANUP_STRATEGY : []u8 = BUFFER_FOR_CLEANUP_STRATEGY[0..0];
var VALUE_CLEANUP_STRATEGY : FileCleanupStrategy = undefined;
var VALUE_UPLOAD_DELAY : f64 = 1.1;


// Getters. Callers cannot write the globals after `establish_config`.

/// Clip length in seconds. Also the base of `get_upload_delay_milis`.
pub fn get_config_video_duration() u64 {
    return VALUE_VIDEO_DURATION;
}

/// V4L2 device path, for example `/dev/video0`.
pub fn get_camera_hardware_name() [:0]u8 {
    return VALUE_CAMERA_HARDWARE_NAME;
}

/// Requested capture width in pixels.
pub fn get_camera_width() u16 {
    return VALUE_VIDEO_WIDTH;
}

/// Requested capture height in pixels.
pub fn get_camera_height() u16 {
    return VALUE_VIDEO_HEIGHT;
}

/// When true, refuse to start if the camera will not accept the requested
/// width, height, or frame rate.
pub fn get_crash_on_vid_diff() bool {
    return VALUE_CRASH_ON_VID_DIFF;
}

/// Requested capture frame rate.
pub fn get_camera_frame_rate() u16 {
    return VALUE_FRAME_RATE;
}

/// x264 CRF passed to the encoder. Lower is higher quality.
pub fn get_crf_value() u8 {
    return VALUE_CRF_VALUE;
}

/// Directory name under `Videos/ToArchive` and `Videos/Archived`.
pub fn get_camera_name() [:0]u8 {
    return VALUE_CAMERA_NAME;
}

/// Seconds added to UTC when naming clips. Negative values are west of UTC.
pub fn get_utc_offset_seconds() i64 {
    return VALUE_UTC_OFFSET_SECONDS;
}

/// Host that receives uploaded clips.
pub fn get_server_address() [:0]u8 {
    return VALUE_SERVER_ADDRESS;
}

/// TCP port of the upload server.
pub fn get_server_port() u16 {
    return VALUE_SERVER_PORT;
}

/// Disk budget, in bytes, consulted by the cleanup strategies that cap storage.
pub fn get_allocated_memory() u64 {
    return VALUE_MEMORY_ALLOC;
}

/// Which `FileCleanupStrategy` the cleanup thread runs.
pub fn get_cleanup_stategy() FileCleanupStrategy {
    return VALUE_CLEANUP_STRATEGY;
}

/// How long the artifact thread waits between upload passes, in milliseconds.
///
/// The file stores `upload delay` as a multiplier of the clip duration.
/// A multiplier of `0` waits 0 ms. Any other value returns
/// `1000 * video_duration * multiplier`.
pub fn get_upload_delay_milis() i64 {
    if (@as(@TypeOf(VALUE_UPLOAD_DELAY), 0) == VALUE_UPLOAD_DELAY) {
        return 0;
    }
    const duration_f64 : f64 = @floatFromInt(VALUE_VIDEO_DURATION);
    const delay_f64 : f64 = ((1000.0 * duration_f64) * VALUE_UPLOAD_DELAY);

    return @as(i64, @intFromFloat(delay_f64));
}


/// Read `config.zap`, or create it with defaults when it is not there.
///
/// Must run before any `get_*` call. A malformed file returns an error.
/// `main` turns that error into a panic.
pub fn establish_config(io : std.Io) !void {
    if (std.Io.Dir.openFile(std.Io.Dir.cwd(), io, CONFIG_FILE_NAME, .{})) |file| {
        try parse_file(file, io);
    }
    else |err| {
        if (std.Io.File.OpenError.FileNotFound == err) {
            try make_default_config(io);
        }
        else return err;
    }
}

fn parse_file(file : std.Io.File, io : std.Io) !void {
    var reader_buffer : [512]u8 = undefined;
    var file_reader = std.Io.File.reader(file, io, &reader_buffer);
    while (file_reader.interface.takeDelimiter('\n')) |nullable_line| {
        const line = nullable_line orelse break;
        const before, const after = std.mem.cut(u8, line, " = ") orelse return error.BadInputFile;
        if (std.mem.eql(u8, before, FIELD_DURATION)) {
            VALUE_VIDEO_DURATION = try std.fmt.parseInt(u64, after, 10);
        }
        else if (std.mem.eql(u8, before, FIELD_HARDWARE_NAME)) {
            @memcpy(BUFFER_FOR_VALUE_CAMERA_HARDWARE_NAME[0..after.len], after);
            BUFFER_FOR_VALUE_CAMERA_HARDWARE_NAME[after.len] = 0;
            VALUE_CAMERA_HARDWARE_NAME = BUFFER_FOR_VALUE_CAMERA_HARDWARE_NAME[0..after.len :0];
        }
        else if (std.mem.eql(u8, before, FIELD_FRAME_RATE)) {
            VALUE_FRAME_RATE = try std.fmt.parseInt(u16, after, 10);
        }
        else if (std.mem.eql(u8, before, FIELD_WIDTH)) {
            VALUE_VIDEO_WIDTH = try std.fmt.parseInt(u16, after, 10);
        }
        else if (std.mem.eql(u8, before, FIELD_HEIGHT)) {
            VALUE_VIDEO_HEIGHT = try std.fmt.parseInt(u16, after, 10);
        }
        else if (std.mem.eql(u8, before, FIELD_CRASH_ON_VID_DIFF)) {
            if (std.mem.eql(u8, after, "true")) {
                VALUE_CRASH_ON_VID_DIFF = true;
            }
            else if (std.mem.eql(u8, after, "false")) {
                VALUE_CRASH_ON_VID_DIFF = false;
            }
            else {
                return error.InvalidBoolSettingInConfig;
            }
        }
        else if (std.mem.eql(u8, before, FIELD_CRASH_ON_POOR_PERF)) {
            if (std.mem.eql(u8, after, "true")) {
                VALUE_CRASH_ON_POOR_PERF = true;
            }
            else if (std.mem.eql(u8, after, "false")) {
                VALUE_CRASH_ON_POOR_PERF = false;
            }
            else {
                return error.InvalidBoolSettingInConfig;
            }
        }
        else if (std.mem.eql(u8, before, FIELD_CRF_VALUE)) {
            VALUE_CRF_VALUE = try std.fmt.parseInt(u8, after, 10);
        }
        else if (std.mem.eql(u8, before, FIELD_CAMERA_NAME)) {
            @memcpy(BUFFER_FOR_VALUE_CAMERA_NAME[0..after.len], after);
            BUFFER_FOR_VALUE_CAMERA_NAME[after.len] = 0;
            VALUE_CAMERA_NAME = BUFFER_FOR_VALUE_CAMERA_NAME[0..after.len :0];
        }
        else if (std.mem.eql(u8, before, FIELD_UTC_OFFSET_SECONDS)) {
            VALUE_UTC_OFFSET_SECONDS = try std.fmt.parseInt(i64, after, 10);
        }
        else if (std.mem.eql(u8, before, FIELD_SERVER_ADDRESS)) {
            @memcpy(BUFFER_FOR_VALUE_SERVER_ADDRESS[0..after.len], after);
            BUFFER_FOR_VALUE_SERVER_ADDRESS[after.len] = 0;
            VALUE_SERVER_ADDRESS = BUFFER_FOR_VALUE_SERVER_ADDRESS[0..after.len :0];
        }
        else if (std.mem.eql(u8, before, FIELD_SERVER_PORT)) {
            VALUE_SERVER_PORT = try std.fmt.parseInt(u16, after, 10);
        }
        else if (std.mem.eql(u8, before, FIELD_MEMORY_ALLOC)) {
            VALUE_MEMORY_ALLOC = try std.fmt.parseInt(u64, after, 10);
        }
        else if (std.mem.eql(u8, before, FIELD_CLEANUP_STRATEGY)) {
            if (std.mem.eql(u8, after, "NoDeletions")) {
                VALUE_CLEANUP_STRATEGY = .NoDeletions;
            }
            else if (std.mem.eql(u8, after, "DeleteArchivedImmediatelyUnprotected")) {
                VALUE_CLEANUP_STRATEGY = .DeleteArchivedImmediatelyUnprotected;
            }
            else if (std.mem.eql(u8, after, "DeleteArchivedImmediatelyProtected")) {
                VALUE_CLEANUP_STRATEGY = .DeleteArchivedImmediatelyProtected;
            }
            else if (std.mem.eql(u8, after, "GeneralProtected")) {
                VALUE_CLEANUP_STRATEGY = .GeneralProtected;
            }
            else if (std.mem.eql(u8, after, "GeneralUnprotected")) {
                VALUE_CLEANUP_STRATEGY = .GeneralUnprotected;
            }
            else {
                return error.InvalidCleanupStrategy;
            }
        }
        else if (std.mem.eql(u8, before, FIELD_UPLOAD_DELAY)) {
            VALUE_UPLOAD_DELAY = try std.fmt.parseFloat(f64, after);
        }
        else {
            return error.InvalidOptionInFile;
        }
    } else |err| return err;
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

    VALUE_VIDEO_DURATION = 15;
    try writer.interface.print("{s} = {d}\n", .{FIELD_DURATION, VALUE_VIDEO_DURATION});

    const device = "/dev/video0";
    @memcpy(BUFFER_FOR_VALUE_CAMERA_HARDWARE_NAME[0..device.len], device);
    BUFFER_FOR_VALUE_CAMERA_HARDWARE_NAME[device.len] = 0;
    VALUE_CAMERA_HARDWARE_NAME = BUFFER_FOR_VALUE_CAMERA_HARDWARE_NAME[0..device.len :0];
    try writer.interface.print("{s} = {s}\n", .{FIELD_HARDWARE_NAME, VALUE_CAMERA_HARDWARE_NAME});

    VALUE_FRAME_RATE = 30;
    try writer.interface.print("{s} = {d}\n", .{FIELD_FRAME_RATE, VALUE_FRAME_RATE});

    VALUE_VIDEO_WIDTH = 640;
    try writer.interface.print("{s} = {d}\n", .{FIELD_WIDTH, VALUE_VIDEO_WIDTH});

    VALUE_VIDEO_HEIGHT = 480;
    try writer.interface.print("{s} = {d}\n", .{FIELD_HEIGHT, VALUE_VIDEO_HEIGHT});

    VALUE_CRASH_ON_VID_DIFF = true;
    try writer.interface.print("{s} = {s}\n", .{FIELD_CRASH_ON_VID_DIFF, if(VALUE_CRASH_ON_VID_DIFF) "true" else "false" });

    VALUE_CRASH_ON_POOR_PERF = false;
    try writer.interface.print("{s} = {s}\n", .{FIELD_CRASH_ON_POOR_PERF, if(VALUE_CRASH_ON_POOR_PERF) "true" else "false" });

    VALUE_CRF_VALUE = 25;
    try writer.interface.print("{s} = {d}\n", .{FIELD_CRF_VALUE, VALUE_CRF_VALUE});

    var prng = std.Random.Xoshiro256.init(blk: {
        var seed: u64 = undefined;
        break :blk @intCast(std.c.getrandom(std.mem.asBytes(&seed), 4, 0));
        //break :blk seed;
    }); 
    const rand = prng.random();
    const rand_number = rand.int(u32);
    const foo = try std.fmt.bufPrint(&BUFFER_FOR_VALUE_CAMERA_NAME, "NewCamera_{d:0>10}", .{rand_number});
    BUFFER_FOR_VALUE_CAMERA_NAME[foo.len] = 0;
    VALUE_CAMERA_NAME = BUFFER_FOR_VALUE_CAMERA_NAME[0..foo.len :0];
    try writer.interface.print("{s} = {s}\n", .{FIELD_CAMERA_NAME, VALUE_CAMERA_NAME});

    VALUE_UTC_OFFSET_SECONDS = -18_000;
    try writer.interface.print("{s} = {d}\n", .{FIELD_UTC_OFFSET_SECONDS, VALUE_UTC_OFFSET_SECONDS});

    const address = "127.0.0.1";
    @memcpy(BUFFER_FOR_VALUE_SERVER_ADDRESS[0..address.len], address);
    BUFFER_FOR_VALUE_SERVER_ADDRESS[address.len] = 0;
    VALUE_SERVER_ADDRESS = BUFFER_FOR_VALUE_SERVER_ADDRESS[0..address.len :0];
    try writer.interface.print("{s} = {s}\n", .{ FIELD_SERVER_ADDRESS, VALUE_SERVER_ADDRESS });

    VALUE_SERVER_PORT = 6969;
    try writer.interface.print("{s} = {d}\n", .{ FIELD_SERVER_PORT, VALUE_SERVER_PORT });

    VALUE_MEMORY_ALLOC = 10_000_000;
    try writer.interface.print("{s} = {d}\n", .{ FIELD_MEMORY_ALLOC, VALUE_MEMORY_ALLOC });

    VALUE_CLEANUP_STRATEGY = FileCleanupStrategy.GeneralUnprotected;
    try writer.interface.print("{s} = GeneralUnprotected\n", .{ FIELD_CLEANUP_STRATEGY });

    VALUE_UPLOAD_DELAY = 1.1;
    try writer.interface.print("{s} = {d}\n", .{ FIELD_UPLOAD_DELAY, VALUE_UPLOAD_DELAY });

    try writer.end();
}



/// Defaults for a comptime config spec.
///
/// Nothing in the running client reads this type. Live settings are the
/// `VALUE_*` globals filled by `establish_config`.
pub const ConfigSpec = struct {
    video_duration: u64 = 15,
    camera_hardware_name: []const u8 = "/dev/video0",
    frame_rate: u16 = 30,
    width: u16 = 640,
    height: u16 = 480,
    crash_on_vid_diff: bool = true,
    crash_on_poor_perf: bool = false,
    crf_value: u8 = 25,
    camera_name: []const u8 = "NewCamera_",
    utc_offset_seconds: i64 = -18000,
    server_address: []const u8 = "127.0.0.1",
    server_port: u16 = 6969,
    memory_alloc: u64 = 10_000_000,
    cleanup_strategy: FileCleanupStrategy = .GeneralUnprotected,
    upload_delay: u64 = 30,
};

// Optional: mapping from config key in file to field
const FieldMapping = struct {
    key: []const u8,
    field_name: []const u8, // or use @tagName / comptime magic
};

/// Stores one value of `Spec` and exposes a comptime `get`.
/// The running client uses `establish_config` and the `get_*` functions.
pub fn ConfigManager(comptime Spec: type) type {
    return struct {
        const Self = @This();

        // Generated storage
        var values: Spec = undefined;

        // Generate getters automatically
        pub fn get(comptime field: std.meta.FieldEnum(Spec)) std.meta.FieldType(Spec, field) {
            return @field(values, @tagName(field));
        }

        // You can also generate specific named getters if you prefer
        pub fn getVideoDuration() u64 { return values.video_duration; }
        // ... or keep using the generic one

        pub fn establish(io: std.Io) !void {
            const file_path = "config.zap"; // or make configurable

            var file = std.Io.Dir.cwd().openFile(io, file_path, .{}) catch |err| {
                if (err == error.FileNotFound) {
                    try createDefault(io, file_path);
                    return;
                }
                return err;
            };
            defer file.close(io);

            try parseFile(file, io);
        }

        fn parseFile(file: std.Io.File, io: std.Io) !void {
            // Use comptime to generate parsing logic for each field
            var buffer: [1024]u8 = undefined;
            var reader = std.Io.File.reader(file, io, &buffer);

            while (try reader.readUntilDelimiterOrEof(&buffer, '\n')) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0 or trimmed[0] == '#') continue;

                const key_end = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
                const key = std.mem.trim(u8, trimmed[0..key_end], " \t");
                const value_str = std.mem.trim(u8, trimmed[key_end + 1 ..], " \t");

                inline for (std.meta.fields(Spec)) |f| {
                    if (std.mem.eql(u8, key, f.name)) {  // or map to custom key
                        @field(values, f.name) = try parseValue(f.type, value_str);
                        break;
                    }
                }
            }
        }

        fn parseValue(comptime T: type, str: []const u8) !T {
            if (T == bool) {
                return std.mem.eql(u8, str, "true");
            } else if (@typeInfo(T) == .Enum) {
                // parse enum by name
                inline for (std.meta.fields(T)) |ef| {
                    if (std.mem.eql(u8, str, ef.name)) return @field(T, ef.name);
                }
                return error.InvalidEnumValue;
            } else {
                return std.fmt.parseInt(T, str, 10) catch error.InvalidValue;
            }
            // add more types as needed (strings, floats, etc.)
        }

        fn createDefault(io: std.Io, path: []const u8) !void {
            const file = try std.Io.Dir.cwd().createFile(io, path, .{});
            defer file.close(io);

            var writer_buf: [2048]u8 = undefined;
            var writer = std.Io.File.writer(file, io, &writer_buf);

            inline for (std.meta.fields(Spec)) |f| {
                const val = @field(Spec{}, f.name); // default value
                try writer.interface.print("{s} = {}\n", .{ f.name, val });
            }

            try writer.end();
        }
    };
}

//Example usage:
//pub const MyConfig = ConfigManager(ConfigSpec);
//
//pub fn main() !void {
//    try MyConfig.establish(io);
//    std.debug.print("Duration: {}\n", .{MyConfig.get(.video_duration)});
//}
