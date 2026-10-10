const std = @import("std");
const config = @import("config");
const flags = @import("flags");
const net = @import("net");

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
) std.Io.Cancelable!void {
    while (true) {
        try io.checkCancel();
        failable_version_of_cleanup_thread(allocator, io) catch |err| {
            std.log.err("Issue found when running cleanup thread: {any}\n", .{ err });
            return;
        };
    }
}

fn failable_version_of_cleanup_thread(
    allocator : std.mem.Allocator,
    io : std.Io,
) !void {
    switch (config.get_cleanup_stategy()) {
        .DeleteArchivedImmediatelyUnprotected => {
            try delete_archived_files(io, allocator);
        },
        .DeleteArchivedImmediatelyProtected, => {
            try delete_archived_files(io, allocator);
        },
        .GeneralProtected => {
            try general_protected_strategy(io, allocator);
        },
        .GeneralUnprotected => {
            try general_unprotected_strategy(io, allocator);
        },
        else => unreachable,
    }
}

fn delete_archived_files(
    io : std.Io,
    allocator : std.mem.Allocator,
) !void {

    const archived_dir = try std.Io.Dir.openDir(
        .cwd(),
        io,
        PATH_TO_ARCHIVED_DIR,
        .{
            .iterate = true,
            .follow_symlinks = false,
        }
    );
    defer archived_dir.close(io);

    var dir_walker = try std.Io.Dir.walk(archived_dir, allocator);
    defer dir_walker.deinit();

    while (dir_walker.next(io)) |nullable_entry| {
        const entry = nullable_entry orelse break;
        switch (entry.kind) {
            .file => {
                try std.Io.Dir.deleteFile(archived_dir, io, entry.path);
            },
            .directory => {
                continue;
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
    allocator : std.mem.Allocator,
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

    try delete_hidden_files(io, allocator);
}



//******************************************************************************
// Function:    delete_hidden_files
//
// Description: This is a function that goes through and deletes all hidden files
//              in the video directory. This is mostly helpful for development
//              because the most common use case for hidden files persisting is
//              a reset where the clip was compromised. 
//
//              The only real practical time to call this is on startup. That way
//              your system doesn't have it's memory wasted with corrupted
//              recordings that can't safely be cleaned by the system until
//              they are uploaded.
//******************************************************************************
fn delete_hidden_files(
    io : std.Io,
    allocator : std.mem.Allocator,
) !void {
    const vid_dir = try std.Io.Dir.openDir(
        .cwd(),
        io,
        MAIN_VIDEO_FOLDER,
        .{
            .iterate = true,
            .follow_symlinks = false,
        },
    );
    defer vid_dir.close(io);

    var dir_walker = try std.Io.Dir.walk(vid_dir, allocator);
    defer dir_walker.deinit();

    while (dir_walker.next(io)) |nullable_entry| {
        const entry = nullable_entry orelse break;

        if (entry.kind != .file) {
            continue;
        }

        if (entry.basename[0] == '.') {
            try std.Io.Dir.deleteFile(vid_dir, io, entry.path);
        }
    }
    else |err| {
        return err;
    }
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

const file_name_and_size = struct {
    path : []const u8,
    file_name : []const u8,
    size : u64,
};


//******************************************************************************
// Function: 
//
// Description: 
//******************************************************************************
fn general_protected_strategy(
    io : std.Io,
    allocator : std.mem.Allocator,
) !void {
    while(true) {

        const to_be_archived_size = try get_size_of_files_yet_to_archive(io, allocator);
        if (to_be_archived_size >= config.get_allocated_memory()) {
            @panic("To Be Implemented: You've exceeded your allocated memory in files not yet backed up with a protective strategy for memory handling. Program is deliberatly crashing to prevent data loss");
        }
        
        var list_of_files_and_sizes : std.ArrayList(file_name_and_size) = .empty;
        defer {
            for (list_of_files_and_sizes.items) |item| {
                allocator.free(item.file_name);
                allocator.free(item.path);
            }
            list_of_files_and_sizes.deinit(allocator);
        }

        const current_uploaded_size = try get_list_of_files_and_names(
            io,
            allocator,
            PATH_TO_ARCHIVED_DIR,
            &list_of_files_and_sizes
        );
        var cumulative_size_on_disk = to_be_archived_size + current_uploaded_size;

        var index : usize = 0;
        var buffer_for_adjusted_path : [512]u8 = undefined;

        while (cumulative_size_on_disk > config.get_allocated_memory()) : (index += 1) {
            const adjusted_path = try std.fmt.bufPrint(
                &buffer_for_adjusted_path,
                "{s}{c}{s}",
                .{ 
                    PATH_TO_ARCHIVED_DIR,
                    std.fs.path.sep,
                    list_of_files_and_sizes.items[index].path 
                }
            );
            try std.Io.Dir.deleteFile(.cwd(), io, adjusted_path);
            cumulative_size_on_disk -= list_of_files_and_sizes.items[index].size;
        }
    }
}


//******************************************************************************
// Function: 
//
// Description: 
//******************************************************************************
fn general_unprotected_strategy(
    io : std.Io,
    allocator : std.mem.Allocator,
) !void {
    while(true) {
        var list_of_files_and_sizes : std.ArrayList(file_name_and_size) = .empty;
        defer {
            for (list_of_files_and_sizes.items) |item| {
                allocator.free(item.file_name);
                allocator.free(item.path);
            }
            list_of_files_and_sizes.deinit(allocator);
        }

        var current_size = try get_list_of_files_and_names(io, allocator, MAIN_VIDEO_FOLDER, &list_of_files_and_sizes);

        sort_file_list(&list_of_files_and_sizes);

        var index : usize = 0;

        var buffer_for_adjusted_path : [512]u8 = undefined;

        while (current_size > config.get_allocated_memory()) : (index += 1) {
            const adjusted_path = try std.fmt.bufPrint(
                &buffer_for_adjusted_path,
                "{s}{c}{s}",
                .{ 
                    MAIN_VIDEO_FOLDER,
                    std.fs.path.sep,
                    list_of_files_and_sizes.items[index].path 
                }
            );
            try std.Io.Dir.deleteFile(.cwd(), io, adjusted_path);
            current_size -= list_of_files_and_sizes.items[index].size;
        }
    }
}


//******************************************************************************
// Function: 
//
// Description: 
//******************************************************************************
fn get_list_of_files_and_names(
    io : std.Io,
    allocator : std.mem.Allocator,
    starting_dir : []const u8,
    list : *std.ArrayList(file_name_and_size),
) !u64 {

    var return_total_size : u64 = 0;

    var walkable_dir = try std.Io.Dir.openDir(
        .cwd(),
        io,
        starting_dir,
        .{
            .iterate = true,
        }
    );
    defer walkable_dir.close(io);

    var walker = try walkable_dir.walk(allocator);
    defer walker.deinit();

    while(walker.next(io)) |nullable_entry| {
        const entry = nullable_entry orelse break;
        //Skipping hidden files... those are actively being encoded (so there
        //should only be one)
        if (entry.basename[0] == '.') continue;
        if (entry.kind != .file) continue;

        const copied_path = try std.mem.Allocator.dupe(allocator, u8, entry.path);
        errdefer allocator.free(copied_path);

        const local_copy_base_name, _ = std.mem.cut(u8, entry.basename, ".") orelse return error.NoFileExtension;
        const copied_base_name = try std.mem.Allocator.dupe(allocator, u8, local_copy_base_name);
        errdefer allocator.free(copied_base_name);

        const file = try std.Io.Dir.openFile(walkable_dir, io, entry.path, .{});
        defer file.close(io);

        const file_stat = try std.Io.File.stat(file, io);
        return_total_size += file_stat.size;

        try list.append(
            allocator,
           .{
               .path = copied_path,
               .file_name = copied_base_name,
               .size = file_stat.size,
           },
        );
    }
    else |err| {
        std.debug.print("Error iterating over directory: {any}\n", .{ err });
        std.debug.print("Aborting thread\n", .{});
        return err;
    }

    return return_total_size;
}


//******************************************************************************
// Function: 
//
// Description: 
//******************************************************************************
fn sort_file_list(list : *std.ArrayList(file_name_and_size)) void {
    std.mem.sort(file_name_and_size, list.items, {}, file_name_less_than);
}


//******************************************************************************
// Function: 
//
// Description: 
//******************************************************************************
fn file_name_less_than(_ : void, a : file_name_and_size, b : file_name_and_size) bool {
    return std.mem.order(u8, a.file_name, b.file_name) == .lt;
}


//******************************************************************************
// Function: 
//
// Description: 
//******************************************************************************
fn get_size_of_files_yet_to_archive(
    io : std.Io,
    allocator : std.mem.Allocator,
) !u64 {
    var size : u64 = 0;

    var walkable_dir = try std.Io.Dir.openDir(
        .cwd(),
       io,
       PATH_TO_TO_ARCHIVE_DIR,
       .{ .iterate = true, }
    );
    defer walkable_dir.close(io);

    var dir_walker = try walkable_dir.walk(allocator);
    defer dir_walker.deinit();

    while (dir_walker.next(io)) |nullable_entry| {
        const entry = nullable_entry orelse break;
        //Skipping hidden files... those are actively being encoded (so there
        //should only be one)
        if (entry.basename[0] == '.') continue;
        if (entry.kind != .file) continue;

        const file = try std.Io.Dir.openFile(walkable_dir, io, entry.path, .{});
        defer file.close(io);

        const file_stat = try std.Io.File.stat(file, io);
        size += file_stat.size;
    }
    else |err| {
        std.debug.print("Failed to iterate over walkable dir due to error: {any}\n", .{ err });
        return err;
    }
    return size;
}
