const std = @import("std");
const builtin = @import("builtin");

pub fn two_core_layout() !void {
    std.debug.print("Hello from the two core layout\n", .{});
    
    std.debug.print("Starting thread that is both capture and encoding...\n", .{});

    const allocator = blk: {
        if (.ReleaseFast == builtin.mode) {
            break :blk std.heap.smp_allocator;
        } else {

            var gpa : std.heap.GeneralPurposeAllocator(.{}) = .init;
            break :blk gpa.allocator();
        }
    };

    var pool : std.Thread.Pool = undefined;
    try std.Thread.Pool.init(&pool, .{ .allocator = allocator });
    defer pool.deinit();
    
    try pool.spawn(capture_and_encode_thread, .{});
}

fn capture_and_encode_thread() void {
}
