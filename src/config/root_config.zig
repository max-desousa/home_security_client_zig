//! Module that manages variables parsed from a file at runtime. 
//!
//! In The event that this file is not present, this module will also create the 
//! file while also setting the defaults I've deemed appropriate.
const std = @import("std");

//Name of config file
const CONFIG_FILE_NAME = "config.zap";

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
var VALUE_MEMORY_ALLOC : usize = undefined;


//Getters to make the data immutable to consumers of the module. 
/// Getter to fetch configured video duration
pub fn get_config_video_duration() u64 {
    return VALUE_VIDEO_DURATION;
}

pub fn get_camera_hardware_name() [:0]u8 {
    return VALUE_CAMERA_HARDWARE_NAME;
}

pub fn get_camera_width() u16 {
    return VALUE_VIDEO_WIDTH;
}

pub fn get_camera_height() u16 {
    return VALUE_VIDEO_HEIGHT;
}

pub fn get_crash_on_vid_diff() bool {
    return VALUE_CRASH_ON_VID_DIFF;
}

pub fn get_camera_frame_rate() u16 {
    return VALUE_FRAME_RATE;
}

pub fn get_crf_value() u8 {
    return VALUE_CRF_VALUE;
}

pub fn get_camera_name() [:0]u8 {
    return VALUE_CAMERA_NAME;
}

pub fn get_utc_offset_seconds() i64 {
    return VALUE_UTC_OFFSET_SECONDS;
}

pub fn get_server_address() [:0]u8 {
    return VALUE_SERVER_ADDRESS;
}

pub fn get_server_port() u16 {
    return VALUE_SERVER_PORT;
}

pub fn get_allocated_memory() usize {
    return VALUE_MEMORY_ALLOC;
}


/// Function to etablish config
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
            VALUE_MEMORY_ALLOC = try std.fmt.parseInt(usize, after, 10);
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

    try writer.end();
}
