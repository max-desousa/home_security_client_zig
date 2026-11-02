//! Security camera client.
//!
//! Startup order:
//! 1. Load `config.zap`, creating it with defaults when it is missing (`config`).
//! 2. Create `Videos/ToArchive/<camera>` and `Videos/Archived/<camera>` (`sys`).
//! 3. Open the V4L2 device and map its buffers (`camera`).
//! 4. Run the thread layout selected by `-Dnumber_of_cores` (`coreLayouts`).
//!
//! The layout that actually runs on a machine with more than three cores is
//! `four_core_layout`: a capture thread, an H.264 encode thread, and an
//! upload thread, passing V4L2 buffer indexes through two queues.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");
const sys = @import("sys");
const camera = @import("camera");
const coreLayouts = @import("coreLayouts");

// Keeps src/root.zig in the compilation so `zig build docs` rebuilds when
// the generated front page changes.
comptime {
    _ = @import("root.zig");
}

var DEBUG_ALLOCATOR : std.heap.DebugAllocator(.{}) = .init;

/// Load config, prepare the archive directories, open the camera, and run
/// the core layout until the process exits.
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
