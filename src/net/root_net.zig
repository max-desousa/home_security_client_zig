const std = @import("std");
const sync_data = @import("sync_data");
const debug = @import("debug");

pub fn upload_thread(io : std.Io, shared_data : *sync_data.UploadData) !void {
    while (true) {
        try io.sleep( std.Io.Duration.fromSeconds(10), .real);

        const nullable_file_name = try shared_data.pop_file();
        const file_name = nullable_file_name orelse continue;

        upload_video(file_name) catch {
            debug.print("******** Error uploading to the server **********", .{});
        };
    }
}

fn upload_video(file : []const u8) !void {
    _ = file;
    return error.TBD;
}
