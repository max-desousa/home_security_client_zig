const std = @import("std");

//fn get_setting_from_file(setting : []const u8) []const u8 {
//}

pub fn get_settings_file(filename: []const u8) !std.fs.File.Reader {
    var buffer: [512]u8 = std.mem.zeroes([512]u8);

    var file = std.fs.Dir.openFile(std.fs.cwd(), filename, .{});
    if (file) |val_file| {
        // File opened successfully
        _ = val_file;
    } else {
        file = try std.fs.openFileAbsolute(filename, .{});
    }

    return std.fs.File.Reader.init(file, &buffer);
}
