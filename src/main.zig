const std = @import("std");
const camera = @import("camera");

pub fn main() !void {
    const device_exists = try camera.check_if_device_exists("/dev/video0");
    if (device_exists) {
        std.debug.print("Camera device found!\n", .{});
    } else {
        std.debug.print("Camera device not found.\n", .{});
    }
    const fd = try camera.openDevice("/dev/video0");
    defer std.c.close(fd);
    try camera.setFrameRate(fd, 30);
}
