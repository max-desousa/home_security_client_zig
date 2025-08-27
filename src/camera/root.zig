const std = @import("std");

pub fn check_if_device_exists(device_name: []const u8) !bool {
    const file = std.fs.openFileAbsolute(device_name, .{ .mode = .read_only }) catch |err| {
        if (err == error.FileNotFound) return false;
        return err; // Propagate other errors
    };
    defer file.close();
    return true;
}
