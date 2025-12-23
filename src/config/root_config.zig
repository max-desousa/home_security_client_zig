const std = @import("std");

const CONFIG_FILE_NAME = "config.zap";

var VIDEO_DURATION_IN_SECONDS : u64 = undefined;

pub fn get_config_video_duration() u64 {
    return VIDEO_DURATION_IN_SECONDS;
}

pub fn establish_config() !void {
    //First, is there an existing config?
    var threaded : std.Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();

    if (std.Io.Dir.openFile(std.Io.Dir.cwd(), io, CONFIG_FILE_NAME, .{})) |file| {
        try parse_file(file, io);
    }
    else |err| {
        if (std.Io.File.OpenError.FileNotFound == err) {
            try make_default_config();
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
        if (std.mem.eql(u8, before, "[video duration]")) {
            VIDEO_DURATION_IN_SECONDS = try std.fmt.parseInt(u64, after, 10);
        }
        else {
            unreachable;
        }
    } else |err| return err;
}

// New IO isn't available on writers yet - this function WILL break
fn make_default_config() !void {
    const new_file = try std.fs.Dir.createFile(
        std.fs.cwd(),
        //io,
        CONFIG_FILE_NAME,
        .{});
    defer new_file.close();
    var writer_buffer : [512]u8 = undefined;
    var writer = std.fs.File.Writer.init(new_file, &writer_buffer);

    //Error to look into... why can't I use variable as format specifier?
    //To prevent possible difference on update
    VIDEO_DURATION_IN_SECONDS = 600;
    try writer.interface.print("[video duration] = {d}\n", .{VIDEO_DURATION_IN_SECONDS});
    try writer.end();
}
