const std = @import("std");
const camera = @import("camera");
const file_system = @import("file_system");

pub fn setup_system() !void {
    const camera_capabilities = try camera.get_capabilities();
    const desired_configuration = try file_system.get_home_sec_config();
    //try camera.init(camera_capabilities, desired_configuration);
    try camera.init();
}
