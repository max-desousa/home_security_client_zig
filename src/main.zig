const std = @import("std");
const config = @import("config");
const camera = @import("camera");
const core_layouts = @import("core_layouts");

pub fn main() !void {
    std.debug.print("Number of cores: {d}\n", .{config.number_of_cores});

    if (config.number_of_cores < 1) {
        return error.InvalidCoreCount;
    }

    switch (config.number_of_cores) {
        1 => core_layouts.single_core_layout(),
        2...7 => core_layouts.restricted_core_layout(),
        else => core_layouts.perfect_core_layout(),
    }

    try camera.init();
}
