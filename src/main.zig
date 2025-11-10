const std = @import("std");
const config = @import("config");
const camera = @import("camera");
const core_layouts = @import("core_layouts");

pub fn main() !void {
    std.debug.print("Number of cores: {d}\n", .{config.number_of_cores});

    if (config.number_of_cores < 1) {
        return error.InvalidCoreCount;
    }

    const system_good_to_run = try initialChecks();

    if (!system_good_to_run) {
        return error.SystemNotCapableOfRunning;
    }
    std.debug.print("System passed initial checks.\n", .{});

    switch (config.number_of_cores) {
        1 => core_layouts.single_core_layout(),
        2...7 => core_layouts.restricted_core_layout(),
        else => try core_layouts.perfect_core_layout(),
    }
}

fn initialChecks() !bool {
    // Perform initial checks to make sure system is capable of running.

    // Initializing camera to start. If camera fails to initialize due
    const camera_initialized = try camera.init();
    if (!camera_initialized) {
        return false;
    }

    return true;
}
