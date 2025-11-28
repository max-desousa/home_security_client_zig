const std = @import("std");
const config = @import("config");
const core_layouts = @import("core_layouts");
const debug = @import("debug");

pub fn main() !void {
    debug.print("Number of cores: {d}\n", .{config.number_of_cores});

    if (config.number_of_cores < 1) {
        return error.InvalidCoreCount;
    }

    switch (config.number_of_cores) {
        1 => try core_layouts.single_core_layout(),
        2 => try core_layouts.two_core_layout(),
        3...7 => try core_layouts.restricted_core_layout(),
        else => try core_layouts.perfect_core_layout(),
    }
}
