const std = @import("std");
const camera = @import("camera");

pub fn main() !void {
    const device_exists = try camera.check_if_device_exists("/dev/video0");
    if (device_exists) {
        std.debug.print("Camera device found!\n", .{});
    } else {
        std.debug.print("Camera device not found.\n", .{});
    }

    const device_name: [:0]const u8 = "/dev/video0";
    const device = try camera.open_device(device_name);
    defer _ = std.c.close(device);
}
