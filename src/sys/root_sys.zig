const std = @import("std");
const config = @import("config");

pub const FOLDER_FOR_FILES_TO_ARCHIVE = "ToArchive";
pub const FOLDER_FOR_ALREADY_ARCHIVED_FILES = "Archived";
pub const MAIN_VIDEO_FOLDER = "Videos";
//pub const PATH_TO_TO_ARCHIVE_DIR = MAIN_VIDEO_FOLDER ++ std.fs.path.sep ++ FOLDER_FOR_FILES_TO_ARCHIVE;
//pub const PATH_TO_ARCHIVED_DIR = MAIN_VIDEO_FOLDER ++ std.fs.path.sep ++ FOLDER_FOR_ALREADY_ARCHIVED_FILES;
pub const PATH_TO_TO_ARCHIVE_DIR = MAIN_VIDEO_FOLDER ++ "/" ++ FOLDER_FOR_FILES_TO_ARCHIVE;
pub const PATH_TO_ARCHIVED_DIR = MAIN_VIDEO_FOLDER ++ "/" ++ FOLDER_FOR_ALREADY_ARCHIVED_FILES;

const FileInfo = struct {
    camera : []const u8,
    file_name : []const u8,
    size : u64,
};



//******************************************************************************
// Function: 
//
// Description: 
//******************************************************************************
pub fn file_cleanup_thread(
    allocator : std.mem.Allocator,
    io : std.Io,
    shutdown_flag : *std.atomic.Value(bool),
) std.Io.Cancelable!void {
    while (true) {
        try io.checkCancel();
        //std.log.debug("Checking shutdown flag\n", .{});
        if (shutdown_flag.load(.acquire)) {
            return;
        }
        //std.log.debug("Shutdown flag not set\n", .{});
        // So many functions are convenient to `try`... and if the thread is
        // capable of failing at all... I want the whole group to close...
        // Since io.concurrent has restrictions on it's ability to return
        // errors... I'll wrap the bread and butter of my thread in another
        // function that handles any error by assisting in cancelling the group
        // without needing to pass it down the callstack.
        //
        // The only restriction is that in order for the previous check cancel
        // called earlier to be effective - there should be some element of
        // tightness to this function so io.checkCancel is frequently checked.
        failable_version_of_cleanup_thread(allocator, io) catch |err| {
            std.log.err("Issue found when running cleanup thread: {any}\n", .{ err });
            shutdown_flag.store(true, .release);
            return;
        };
    }
}

fn failable_version_of_cleanup_thread(
    allocator : std.mem.Allocator,
    io : std.Io,
) !void {
    _ = &allocator;
    switch (config.get_cleanup_stategy()) {
        .DeleteArchivedImmediatelyUnprotected => {
            try delete_archived_files(io);
        },
        .DeleteArchivedImmediatelyProtected, => {
            try delete_archived_files(io);
        },
        .GeneralProtected => {
            @panic("TBD - cleanup strategy GeneralProtected not yet implemented");
        },
        .GeneralUnprotected => {
            @panic("TBD - cleanup strategy GeneralUnprotected not yet implemented");
        },
        else => unreachable,
    }
}

fn delete_archived_files(
    io : std.Io,
) !void {
    const iterable_dir = try std.Io.Dir.openDir(
        .cwd(),
        io,
        PATH_TO_ARCHIVED_DIR,
        .{
            .iterate = true,
            .follow_symlinks = false,
        }
    );
    defer iterable_dir.close(io);

    var dir_iterator = std.Io.Dir.iterate(iterable_dir);

    while (dir_iterator.next(io)) |nullable_entry| {
        const entry = nullable_entry orelse break;
        switch (entry.kind) {
            .file => {
                try std.Io.Dir.deleteFile(iterable_dir, io, entry.name);
            },
            .directory => {
                try std.Io.Dir.deleteTree(iterable_dir, io, entry.name);
            },
            else => {
                return error.InvalidObjectFoundInArchivedDir;
            }
        }
    }
    else |err| {
        return err;
    }
}

//    }
//
//    const iterable_dir = try std.Io.Dir.openDir(
//        .cwd(),
//        io,
//        PATH_TO_ARCHIVED_DIR,
//        .{
//            .iterate = true,
//            .follow_symlinks = false,
//        }
//    );
//
//    var running_dir_size : usize = 0;
//    var list_of_files : std.ArrayList(FileInfo) = .empty;
//    defer {
//        for (list_of_files.items) |item| {
//            allocator.free(item.camera);
//            allocator.free(item.file_name);
//        }
//        list_of_files.deinit(allocator);
//    }
//
//    var dir_walker = try std.Io.Dir.walk(iterable_dir, allocator);
//    defer dir_walker.deinit();
//
//    while (dir_walker.next(io)) |nullable_entry| {
//        const entry = nullable_entry orelse break;
//        if (.file != entry.kind) {
//            continue;
//        }
//
//        const file = try std.Io.Dir.openFile(.cwd(), io, entry.path, .{});
//        const file_stat = try std.Io.File.stat(file, io);
//        const file_size = file_stat.size;
//
//        running_dir_size += file_size;
//
//        //Removing sentinel
//        const path : []const u8 = entry.path;
//        //Getting the camera name (can't reference config due to mesh)
//        //path seen by walker is simply: [camera_name]/filname
//        const camera_name, _ = std.mem.cut(
//            u8,
//            path,
//            "/",
//        ) orelse return error.CantStripExpectedDir;
//        const allocated_camera_name = try std.fmt.allocPrint(allocator, "{s}", .{ camera_name });
//
//        //Removing sentinel
//        const base_name : []const u8 = entry.basename;
//        const allocated_file_name = try std.fmt.allocPrint(allocator, "{s}", .{ base_name });
//
//        try list_of_files.append(
//            allocator, 
//            .{
//                .camera = allocated_camera_name,
//                .file_name = allocated_file_name,
//                .size = file_size,
//            }
//        );
//    }
//    else |err| {
//        std.log.err("Error in \"file_cleanup_thread\": {any}\n", .{ err });
//        @panic("TBD - What do I do when walker in \"file_cleanup_thread\" fails?");
//    }
//
//    if (config.get_allocated_memory() < running_dir_size) {
//        @panic("TBD - delete memory due to there being too much");
//    }
//    else {
//        @panic("TBD - Memory within bounds");
//    }
//}


//******************************************************************************
// Function: 
//
// Description: 
//******************************************************************************
pub fn establish_directories(
    io : std.Io,
) !void {

    var buffer_for_path_names : [512]u8 = undefined;

    var path_name = try std.fmt.bufPrint(
        &buffer_for_path_names, 
        "{s}{c}{s}{c}{s}", 
        .{ 
            MAIN_VIDEO_FOLDER,
            std.fs.path.sep,
            FOLDER_FOR_FILES_TO_ARCHIVE,
            std.fs.path.sep,
            config.get_camera_name(), 
        }
    );

    try std.Io.Dir.createDirPath(.cwd(), io, path_name);

    path_name = try std.fmt.bufPrint(
        &buffer_for_path_names, 
        "{s}{c}{s}{c}{s}", 
        .{ 
            MAIN_VIDEO_FOLDER,
            std.fs.path.sep,
            FOLDER_FOR_ALREADY_ARCHIVED_FILES,
            std.fs.path.sep,
            config.get_camera_name(), 
        }
    );

    try std.Io.Dir.createDirPath(.cwd(), io, path_name);
}


//******************************************************************************
// Function: 
//
// Description: 
//******************************************************************************
pub fn get_to_archive_path_for_camera(
    buffer : []u8,
    camera_name : []u8,
) ![]u8 {
    return try std.fmt.bufPrint(
        buffer,
        "{s}{c}{s}{c}{s}",
        .{
            MAIN_VIDEO_FOLDER,
            std.fs.path.sep,
            FOLDER_FOR_FILES_TO_ARCHIVE,
            std.fs.path.sep,
            camera_name, 
        }
    );
}


//******************************************************************************
// Function: 
//
// Description: 
//******************************************************************************
pub fn get_to_archive_path(
    buffer : []u8,
) ![]u8 {
    return try get_to_archive_path_for_camera(buffer, config.get_camera_name());
}


//******************************************************************************
// Function: 
//
// Description: 
//******************************************************************************
pub fn get_archived_path_for_camera(
    buffer : []u8,
    camera_name : []u8,
) ![]u8 {
    return try std.fmt.bufPrint(
        buffer,
        "{s}{c}{s}{c}{s}",
        .{
            MAIN_VIDEO_FOLDER,
            std.fs.path.sep,
            FOLDER_FOR_ALREADY_ARCHIVED_FILES,
            std.fs.path.sep,
            camera_name, 
        }
    );
}


//******************************************************************************
// Function: 
//
// Description: 
//******************************************************************************
pub fn get_archived_path(
    buffer : []u8,
) ![]u8 {
    return try get_archived_path_for_camera(buffer, config.get_camera_name());
}
