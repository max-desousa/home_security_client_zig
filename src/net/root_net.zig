const std = @import("std");
const sync_data = @import("sync_data");
const debug = @import("debug");

pub fn upload_thread(
    allocator : std.mem.Allocator,
    io : std.Io,
    shared_data : *sync_data.SynchronousData
) !void {
    while (null == shared_data.sync_error) {

        if (shared_data.upload_data.file_list.items.len > 0) {
            shared_data.upload_data.mutex.lock(io) catch { continue; };
            const file_name = shared_data.upload_data.file_list.items[0];
            shared_data.upload_data.mutex.unlock(io);
            const upload_result = upload_video(file_name);
            if (upload_result) {
                unreachable;
            }
            else |err| {
                debug.print("Error Uploading video:\n", .{});
                debug.print("\tError: {any}\n", .{ err });
                debug.print("\tTrying upload again...\n", .{});
                std.Io.sleep(io, .fromSeconds(10), .real) catch { continue; };
                continue;
            }
        }
    }
    _ = std.Io.sleep(io, .fromSeconds(10), .real) catch {};
    debug.print("Printing list before final cleanup...\n", .{});
    for (shared_data.upload_data.file_list.items) |item| {
        debug.print("\t{s}\n", .{ item });
    }
    debug.print("Final attemmpt to upload before crashing program from thread error...\n", .{});
    for (shared_data.upload_data.file_list.items) |item| {
        upload_video(item) catch {
            debug.print("******** Error uploading to the server **********", .{});
        };
    }
    debug.print("Printing list after final cleanup...\n", .{});
    for (shared_data.upload_data.file_list.items) |item| {
        debug.print("\t{s}\n", .{ item });
    }
    debug.print("Ending upload thread due to encoder error: {any}\n", .{ shared_data.sync_error });
    shared_data.upload_data.deinit(allocator);
    shared_data.upload_data.file_list.deinit(allocator);
}

fn upload_video(file : [:0]const u8) !void {
    debug.print("Uploading file: {s}\n", .{ file });
    return error.TBD;
}
