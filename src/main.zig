const std = @import("std");
const camera = @import("camera");

pub fn main() !void {
    try camera.init();
}
