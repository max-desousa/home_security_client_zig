const std = @import("std");
const sync_data = @import("sync_data");
const debug = @import("debug");

pub fn upload_thread(io : std.Io, shared_data : *sync_data.UploadData) !void {
    var file_name_backing_buffer : [4096]u8 = undefined;

    while (null == shared_data.reason_to_exit) {
        try io.sleep( std.Io.Duration.fromSeconds(120), .real);

        while (shared_data.pop_file(&file_name_backing_buffer)) |nullable_file_name| {
            const file_name = nullable_file_name orelse break;
            upload_video(file_name) catch {
                debug.print("******** Error uploading to the server **********\n", .{});
            };
        }
        else |err| {
            debug.print("Error popping filename from list: {any}\n", .{ err });
        }
    }
    debug.print("Printing list before final cleanup...\n", .{});
    for (shared_data.file_list.items) |item| {
        debug.print("\t{s}\n", .{ item });
    }
    debug.print("Final attemmpt to upload before crashing program from thread error...\n", .{});
    while (shared_data.pop_file(&file_name_backing_buffer)) |nullable_file_name| {
        const file_name = nullable_file_name orelse break;
        upload_video(file_name) catch {
            debug.print("******** Error uploading to the server **********", .{});
        };
    }
    else |err| {
        debug.print("Error popping filename from list: {any}\n", .{ err });
    }
    debug.print("Printing list after final cleanup...\n", .{});
    for (shared_data.file_list.items) |item| {
        debug.print("\t{s}\n", .{ item });
    }
    debug.print("Ending upload thread due to encoder error: {any}\n", .{ shared_data.reason_to_exit });
    shared_data.deinit();
    shared_data.file_list.deinit(shared_data.allocator);
}

fn upload_video(file : [:0]const u8) !void {
    debug.print("Uploading file: {s}\n", .{ file });
    return error.TBD;
}
