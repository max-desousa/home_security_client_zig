const std = @import("std");
const sync_data = @import("sync_data");
const debug = @import("debug");
const config = @import("config");
const sys = @import("sys");
const flags = @import("flags");

pub fn upload_thread(
    allocator : std.mem.Allocator,
    io : std.Io,
) void {
    //In the event that the program was terminated wtihin this thread (i.e. -
    //the program running flag still needs to be set... we'll make sure it's
    //clear here at the start that the mechanism for getting the system to
    //shutdown works.
    defer flags.set_shutdown_flag();

    // -- Beginning of Thread --

    while (flags.is_operating_normally()) {
        const iterable_dir = std.Io.Dir.openDir(
            .cwd(), 
            io, 
            sys.PATH_TO_TO_ARCHIVE_DIR,
            .{
                .iterate = true,
                .follow_symlinks = false,
            },
        ) catch @panic("TBD - what do I do when folder cannot be opened?");
        defer iterable_dir.close(io);

        var walker = std.Io.Dir.walk(iterable_dir, allocator) catch @panic("TBD - what do I do when walker won't initialize?");
        defer walker.deinit();

        while (walker.next(io)) |nullable_entry| {
            const entry = nullable_entry orelse break;
            if (.file != entry.kind) {
                continue;
            }
            if (1 < std.mem.count(u8, entry.path, ".")) {
                continue;
            }

            var buffer_for_adjusted_path : [512]u8 = undefined;
            const adjusted_path = adjust_path_due_to_iterator(
                &buffer_for_adjusted_path,
                entry.path,
            ) catch {
                continue;
            };

            upload_video(allocator, io, adjusted_path) catch {
                //Continue to try next file if upload fails? Why just continue?
                //Simple... file cleanup thread will cause panic if it must for
                //the preservation of files, else it will gracefully delete.
                //The only purpose in identifying the error state of uploading
                //is to prevent other operations that would induce a crash or
                //break our process (like moving a file to the folder of
                //successfully archived videos if it hasn't been uploaded yet. 
                std.log.warn("Uploading video failed", .{});
                continue;
            };

            move_file_to_archived_folder(io, adjusted_path) catch |err| {
                std.log.err("Error retrieved: {any}\n", .{ err });
                std.log.debug("\tsubmitted path: {s}\n", .{ adjusted_path });
                @panic("TBD - what do I want to do when \"move_file_to_archived_folder\" fails?");
            };
        }
        else |err| {
            std.log.err("Iterator failed with error: {any}\n", .{ err });
            @panic("TBD - what do I do when the iterator fails?");
        }
        std.debug.print("Done printing list of detected files\n", .{});

        const delay = config.get_upload_delay();
        if (delay > 0) {
            std.Io.sleep(io, .fromSeconds(@intCast(delay)), .real) catch continue;
        }
    }
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
    const uri_slice = try generate_uri_string_for_archival(&buffer_for_uri, path);

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
    const response = req.receiveHead(&buffer_for_response) catch |err| {
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


//******************************************************************************
// Function: 
//
// Description: 
//******************************************************************************
fn move_file_to_archived_folder(
    io : std.Io,
    path : []const u8,
) !void {
    std.log.debug("Starting an run of `move_file_to_archived_folder`\n", .{});

    _, const sub_path = std.mem.cut(u8, path, sys.FOLDER_FOR_FILES_TO_ARCHIVE) orelse return error.CouldNotFindFolderToReplaceInPath;

    var buffer_for_new_path : [512]u8 = undefined;
    const new_path = try std.fmt.bufPrint(
        &buffer_for_new_path,
        "{s}{s}",
        .{
            sys.PATH_TO_ARCHIVED_DIR,
            sub_path,
        }
    );

    const dir_path, _ = std.mem.cutLast(u8, new_path, "/") orelse return error.NoSlash;

    try std.Io.Dir.createDirPath(.cwd(), io, dir_path);

    std.log.debug("Provided path: {s}\n", .{ path });
    std.log.debug("New path: {s}\n", .{ new_path });

    try std.Io.Dir.rename(
        .cwd(),
        path,
        .cwd(),
        new_path,
        io, 
    );
}


//******************************************************************************
// Function: generate_uri_string_for_archival
//
// Description: This is a function that takes the path provided by the
//              directory walker and creating a string that will create a
//              string for the address that will be used for uploading a video
//              file. 
//
//              This will use the path and also address the ability to upload
//              videos that are planned for future meshing. 
//******************************************************************************
fn generate_uri_string_for_archival(
    buffer : []u8, 
    path : []const u8,
) ![]u8 {
    // Desired String
    //"http://{s}:{d}/archival/{s}/{s}", 
    //
    //Path format:
    //[cwd]/${sys.MAIN_VIDEO_FOLDER}/file_state/${config.get_camera_name()/[filename]}

    _, const string_camera_and_file_name = std.mem.cut(
        u8,
        path, 
        sys.PATH_TO_TO_ARCHIVE_DIR
    ) orelse return error.FileDoesNotHavePathForMainFolder;

    const string_camera_name, const string_file_name = std.mem.cut(
        u8,
        string_camera_and_file_name,
        "/",
    ) orelse return error.NoSlashPresent;

    return try std.fmt.bufPrint(
        buffer,
        "http://{s}:{d}/archival{s}/{s}",
        .{
            config.get_server_address(), 
            config.get_server_port(),
            string_camera_name,
            string_file_name
        }
    );
}


//******************************************************************************
// Function: adjust_path_due_to_iterator
//
// Description: When we iterate over the directory that contains all the
//              videos, it doesnt' contain the folder that is actively being
//              iterated. This means that the path develops an issue when
//              trying to open files for transfer. So, we need to compensate by
//              addressing the issue with the path string. That's what this
//              function does. 
//******************************************************************************
fn adjust_path_due_to_iterator(
    buffer : []u8,
    malformed_path : []const u8,
) ![:0]u8 {
    return try std.fmt.bufPrintSentinel(
        buffer,
        "{s}/{s}",
        .{
            sys.PATH_TO_TO_ARCHIVE_DIR,
            malformed_path,
        },
        0,
    );
}
