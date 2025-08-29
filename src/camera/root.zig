const std = @import("std");
const c = @cImport({
    @cInclude("linux/videodev2.h");
    @cInclude("sys/ioctl.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("errno.h");
});

pub fn check_if_device_exists(device_name: []const u8) !bool {
    const file = std.fs.openFileAbsolute(device_name, .{ .mode = .read_only }) catch |err| {
        if (err == error.FileNotFound) return false;
        return err; // Propagate other errors
    };
    defer file.close();
    return true;
}

pub fn open_device(device_name: [:0]const u8) !c_int {
    const device = c.open(device_name, c.O_RDWR | c.O_NONBLOCK, @as(c_int, 0));
    if (-1 == device) {
        return error.OpenDeviceFailed;
    }
    return device;
}
