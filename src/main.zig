const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");
const sys = @import("sys");
const camera = @import("camera");
const coreLayouts = @import("coreLayouts");

var DEBUG_ALLOCATOR : std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    const allocator : std.mem.Allocator = comptime switch (builtin.mode) {
        .debug => DEBUG_ALLOCATOR.allocator(),
        else => std.heap.c_allocator,
    };
    defer {
        if (.debug == builtin.mode) {
            _ = DEBUG_ALLOCATOR.deinit();
        }
    }

    var threaded : std.Io.Threaded = .init(allocator, .{ .environ = .empty });
    defer threaded.deinit();

    const io = threaded.io();

    config.establish_config(io) catch {
        @panic("Something went wrong with reading the config");
    };

    //Make sure that there is a path to store the files.
    //The path makes cleanup simpler as we progress the project, and builds out
    //the ability for meshed uploading in the future. (Dedicated folders for
    //different cameras if this client is also a server)
    try sys.establish_directories(io, allocator);

    // Try to create camera object (making sure system works) before starting 
    // multithreaded portion.
    var camera_obj = try camera.init(config.get_camera_hardware_name(), allocator);
    defer camera_obj.deinit();

    try coreLayouts.startSecurityCamera(io, allocator, &camera_obj);
}
