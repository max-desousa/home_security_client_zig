const std = @import("std");
const sync_data = @import("sync_data");
const debug = @import("debug");
const config = @import("config");

pub fn upload_thread(
    allocator : std.mem.Allocator,
    io : std.Io,
    shared_data : *sync_data.SynchronousData
) !void {
    while (null == shared_data.sync_error) {

        if (shared_data.upload_data.file_list.items.len > 0) {
            shared_data.upload_data.mutex.lock(io) catch { continue; };
            const last_index = shared_data.upload_data.file_list.items.len - 1;
            const file_name = shared_data.upload_data.file_list.items[last_index];
            shared_data.upload_data.mutex.unlock(io);
            const upload_result = upload_video(allocator, io, file_name);
            if (upload_result) {
                //What do if popping the successfully uploaded file errors out?
                //The only thing that can error out is locking the mutex...
                //Only error path is due to mutex being cancelable.
                shared_data.upload_data.pop_file(allocator, io) catch {};
            }
            else |err| {
                debug.print("Error Uploading video:\n", .{});
                debug.print("\tError: {any}\n", .{ err });
                debug.print("\tTrying upload again...\n", .{});
                std.Io.sleep(io, .fromSeconds(@intCast(config.get_config_video_duration() * 2)), .real) catch { continue; };
                continue;
            }
        }
    }
    _ = std.Io.sleep(io, .fromSeconds(@intCast(config.get_config_video_duration() * 2)), .real) catch {};
    debug.print("Printing list before final cleanup...\n", .{});
    for (shared_data.upload_data.file_list.items) |item| {
        debug.print("\t{s}\n", .{ item });
    }
    debug.print("Final attemmpt to upload before crashing program from thread error...\n", .{});
    for (shared_data.upload_data.file_list.items) |item| {
        upload_video(allocator, io, item) catch {
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

fn upload_video(
    allocator : std.mem.Allocator,
    io : std.Io,
    path : [:0]const u8
) !void {
    debug.print("Uploading file: {s}\n", .{ path });

    var client :std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var file : std.Io.File = try std.Io.Dir.openFile(std.Io.Dir.cwd(), io, path, .{});
    defer file.close(io);

    //Get file length in bytes
    const file_stat = try std.Io.File.stat(file, io);
    const file_length = file_stat.size;

    var buffer_for_uri : [512]u8 = undefined;
    const uri_slice = try std.fmt.bufPrint(
        &buffer_for_uri, 
        "http://{s}:{d}/archival/{s}/{s}", 
        .{
            config.get_server_address(), 
            config.get_server_port(),
            config.get_camera_name(),
            path,
        },
    );

    const uri = try std.Uri.parse(uri_slice);
    var req = try client.request(.POST, uri, .{});
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = file_length };

    //All headers must be complete by this point in time. 
    try write_raw_file_content_bytes_to_stream(
        io,
        &file,
        &req,
    );

    var buffer_for_response : [4096]u8 = undefined;
    var response = req.receiveHead(&buffer_for_response) catch |err| {
        std.log.err("Receive head on response errored out: {any}\n", .{ err });
        @panic("Error in receiving response");
    };

    if (.ok == response.head.status) {
        std.log.err("TODO: Mark video for deletion\n", .{});
    }
    else {
        @panic("TBD: Implement handling of upload error");
    }
}


//******************************************************************************
// Function: 
//
// Description: 
//******************************************************************************
fn write_raw_file_content_bytes_to_stream (
    io : std.Io,
    file : *std.Io.File,
    req : *std.http.Client.Request,
) !void {
    // Create reader for transferring video contents
    var buffer_for_file_reader : [4096]u8 = undefined;
    var file_reader = file.reader(io, &buffer_for_file_reader);

    var buffer_for_body_writer : [4096]u8 = undefined;
    var body_writer = try req.sendBodyUnflushed(&buffer_for_body_writer);
    defer body_writer.end() catch {};

    while (file_reader.interface.fillMore()) {
        _ = try body_writer.writer.write(file_reader.interface.buffered());
        file_reader.interface.tossBuffered();
    }
    else |err| {
        if (error.EndOfStream != err) {
            return err;
        }
    }
}
