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
) !void {
    _ = &io;
    _ = &allocator;

    const iterable_dir = try std.Io.Dir.openDir(
        .cwd(),
        io,
        PATH_TO_ARCHIVED_DIR,
        .{
            .iterate = true,
            .follow_symlinks = false,
        }
    );

    var running_dir_size : usize = 0;
    var list_of_files : std.ArrayList(FileInfo) = .empty;
    defer {
        for (list_of_files.items) |item| {
            allocator.free(item.camera);
            allocator.free(item.file_name);
        }
        list_of_files.deinit(allocator);
    }

    var dir_walker = try std.Io.Dir.walk(iterable_dir, allocator);
    defer dir_walker.deinit();

    while (dir_walker.next(io)) |nullable_entry| {
        const entry = nullable_entry orelse break;
        if (.file != entry.kind) {
            continue;
        }

        const file = try std.Io.Dir.openFile(.cwd(), io, entry.path, .{});
        const file_stat = try std.Io.File.stat(file, io);
        const file_size = file_stat.size;

        running_dir_size += file_size;

        //Removing sentinel
        const path : []const u8 = entry.path;
        //Getting the camera name (can't reference config due to mesh)
        //path seen by walker is simply: [camera_name]/filname
        const camera_name, _ = std.mem.cut(
            u8,
            path,
            "/",
        ) orelse return error.CantStripExpectedDir;
        const allocated_camera_name = try std.fmt.allocPrint(allocator, "{s}", .{ camera_name });

        //Removing sentinel
        const base_name : []const u8 = entry.basename;
        const allocated_file_name = try std.fmt.allocPrint(allocator, "{s}", .{ base_name });

        try list_of_files.append(
            allocator, 
            .{
                .camera = allocated_camera_name,
                .file_name = allocated_file_name,
                .size = file_size,
            }
        );
    }
    else |err| {
        std.log.err("Error in \"file_cleanup_thread\": {any}\n", .{ err });
        @panic("TBD - What do I do when walker in \"file_cleanup_thread\" fails?");
    }

    if (config.get_allocated_memory() < running_dir_size) {
        @panic("TBD - delete memory due to there being too much");
    }
    else {
        @panic("TBD - Memory within bounds");
    }
}


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
