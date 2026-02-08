const std = @import("std");
const Shared_Data = @import("shared_data.zig");

pub fn upload_thread(io : std.Io, shared_data : *Shared_Data) !void {
    while (true) {
        try io.sleep( std.Io.Duration.fromSeconds(10), .real);

        const nullable_file_name = try shared_data.pop_file();
        const file_name = nullable_file_name orelse continue;

        upload_video(file_name);
    }
}

fn upload_video(file : []const u8) !void {
    _ = file;
}
