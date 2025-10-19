const std = @import("std");
const config = @import("config");
const camera = @import("camera");

pub fn main() !void {
    std.debug.print("Number of cores: {d}\n", .{config.number_of_cores});
    try camera.init();
}
