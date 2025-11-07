const std = @import("std");

pub fn check_if_config_file_exists() bool {
    const check_if_file_exists = std.fs.Dir.statFile(std.fs.cwd(), "config.txt");

    if (check_if_file_exists) |_| {
        return true;
    }
    else |_| {
        return false;
    }
}
