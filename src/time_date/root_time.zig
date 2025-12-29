const std = @import("std");
//##############################################################################
//
// Enum for time zones. This will almost eclusively be used with the
// get_timezone_offset_in_sec function.
//
//###############################################################################
const Timezone = enum {
    EST,
    California,
};


//##############################################################################
//
// Function: get_current_time_as_string
//
// Description: This function is very similar to
//              `get_time_for_filename_string`. It doesn't support an offset -
//              so it will only return the real time value back (timezone
//                  padding is hard coded for now). The output of this function
//              is a string that MUST be freed. The string is in the format;
//              HHMMSS for the current day.
//
//##############################################################################
fn get_current_time_as_string(allocator : std.mem.Allocator) ![]const u8 {
    const epoch = try std.posix.clock_gettime(.REALTIME);
    const offset : u64 = @intCast(epoch.sec - 18_000);

    const epoch_seconds : std.time.epoch.EpochSeconds = .{.secs = offset};
    const day_seconds = epoch_seconds.getDaySeconds();
    const hours_into_day = day_seconds.getHoursIntoDay();
    const minutes_into_hour = day_seconds.getMinutesIntoHour();
    const seconds_into_minute = day_seconds.getSecondsIntoMinute();

    return try std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}:{d:0>2}", .{hours_into_day, minutes_into_hour, seconds_into_minute});
}


//##############################################################################
//
// Functoin: get_time_for_filename_string
//
// Description: This function is used to get the epochtime in a human friendly
//              format. (in a format reflecting calandar date). Posix libraries
//              are used to get epoch seconds and then the epoch library is
//              used to convert them in a numeric fashion. The output will be a
//              string - which MUST be freed - in the format: YYYYMMDDHHSS
//
//##############################################################################
fn get_time_for_filename_string(allocator : std.mem.Allocator, offset : u64) ![]const u8 {
    const epoch = try std.posix.clock_gettime(.REALTIME);
    const epoch_accounting_for_tz : u64 = @intCast(epoch.sec - 18_000);
    const time_to_output = epoch_accounting_for_tz + offset;

    const epoch_seconds : std.time.epoch.EpochSeconds = .{.secs = time_to_output};
    const day_seconds = epoch_seconds.getDaySeconds();
    const hours_into_day = day_seconds.getHoursIntoDay();
    const minutes_into_hour = day_seconds.getMinutesIntoHour();
    const seconds_into_minute = day_seconds.getSecondsIntoMinute();
    const epoch_day = epoch_seconds.getEpochDay();
    const year_and_day = epoch_day.calculateYearDay();
    const year = year_and_day.year;
    const month_and_day = year_and_day.calculateMonthDay();
    const month = month_and_day.month.numeric();
    const day = month_and_day.day_index;
    
    return try std.fmt.allocPrint(
        allocator,
        "{d:0>4}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}",
        .{
            year,
            month,
            day,
            hours_into_day,
            minutes_into_hour,
            seconds_into_minute,
        });
}


//##############################################################################
//
// Funtion: get_windowed_time_for_filename_string
//
// Description: This function returns a string - WHICH MUST BE FREED
//              (allocator.free()) for a window of time that will be used in
//              the filename for the webcam data. 
//              
//              Output format will be "YYYYMMDDHHSS-YYYYMMDDHHSS". This will
//              append to any name for the camera and will be a somewhat
//              convenient way of knowing what time frame the data on the
//              webcam is for.
//
//##############################################################################
pub fn get_windowed_time_for_filename_string(allocator: std.mem.Allocator, offset : u64) ![]const u8 {
    const start_time = try get_time_for_filename_string(allocator, 0);
    defer allocator.free(start_time);
    const end_time = try get_time_for_filename_string(allocator, offset);
    defer allocator.free(end_time);

    return try std.fmt.allocPrint(
        allocator,
        "{s}-{s}",
        .{
            start_time,
            end_time,
        }
    );
}


//##############################################################################
//
// Funtion: get_windowed_time_for_filename_stringZ
//
// Description: This function returns a string - WHICH MUST BE FREED
//              (allocator.free()) for a window of time that will be used in
//              the filename for the webcam data. 
//              
//              Output format will be "YYYYMMDDHHSS-YYYYMMDDHHSS". This will
//              append to any name for the camera and will be a somewhat
//              convenient way of knowing what time frame the data on the
//              webcam is for.
//
//##############################################################################
pub fn get_windowed_time_for_filename_stringZ(allocator: std.mem.Allocator, offset : u64) ![:0]const u8 {
    const start_time = try get_time_for_filename_string(allocator, 0);
    defer allocator.free(start_time);
    const end_time = try get_time_for_filename_string(allocator, offset);
    defer allocator.free(end_time);

    return try std.fmt.allocPrintSentinel(
        allocator,
        "{s}-{s}",
        .{
            start_time,
            end_time,
        },
        0,
    );
}


//##############################################################################
//
// Function: within_time_frame_of_filename
//
// Description: This function takes any filename that contains the output of
//              `get_windowed_time_for_filename_string` at the end of the
//              filename, and calculates whether or not the present moment in
//              time is within the bounds of said files window of coverage (to
//              figure out if a new file should start to be generated)
//
//##############################################################################
fn within_time_frame_of_filename(file_name : []const u8, allocator : std.mem.Allocator) !bool {
    const end_time_end_index = file_name.len;
    const end_time_start_index = end_time_end_index - 14;

    const start_time_end_index = end_time_start_index - 1;
    const start_time_start_index = start_time_end_index - 14;

    const end_time = try std.fmt.parseInt(u64, file_name[end_time_start_index..end_time_end_index], 10);
    const start_time = try std.fmt.parseInt(u64, file_name[start_time_start_index..start_time_end_index], 10);

    const real_time_string = try get_time_for_filename_string(allocator, 0);
    defer allocator.free(real_time_string);
    const real_time = try std.fmt.parseInt(u64, real_time_string, 10);

    if (real_time > end_time) {
        return false;
    }
    if (real_time < start_time) {
        return false;
    }

    return true;
}


//##############################################################################
//
// Function: get_current_epoch_sec()
//
// Description: Use this function to get the current epoch seconds as a u64. It
//              uses the posix library and is currently hardcoded for EST. (I
//              will update this in the future)
//
//##############################################################################
pub fn get_current_epoch_sec(offset : i64) !u64 {
    const raw_epoch = try std.posix.clock_gettime(.REALTIME);
    const epoch : u64 = @intCast(raw_epoch.sec);
    //This is the hardcoded offset for EST
    const positive_offset : bool = (offset > 0);
    const abs_offset : u64 = @abs(offset);
    if (positive_offset) {
        return epoch + abs_offset;
    } else {
        return epoch - abs_offset;
    }
}


//##############################################################################
//
// Function: get_timezone_offset_in_sec()
//
// Description: Function used to simplify conversion of the timezone to get an
//              offset. It's expected that most application will require the
//              user to know their timezone - but as I'm prototyping I want a
//              mechanism to simply get the offset for my timezone. Will
//              consider deletion over widespread use - but that remains to be
//              seen. 
//
//##############################################################################
pub fn get_timezone_offset_in_sec(timezone : Timezone) i64 {
    switch(timezone) {
        .EST => return -18_000,
        else => unreachable,
    }
}

//##############################################################################
//
// Function: is_valid_time_window
//
// Description: This function checks to see if a given configuration for a 
//              duration of videos can be enenly divisible into standard time. 
//              (videos are cleaner when named if they can neglect seconds and 
//              videos are shorter than a day)
//
//##############################################################################
pub fn is_valid_time_window(duration: u64) bool {
    // Check if duration is evenly divisible with a single minute
    if (60 > duration) {
        false;
    }
    if (60 == duration) {
        return true;
    }
    // Check if duration is evenly divisible with a 10 minutes
    if (600 >= duration) {
        return (0 == (600 % duration));
    }
    // Check if duration is evenly divisible with a single hour
    if (3_600 >= duration) {
        return (0 == (3_600 % duration));
    }
    // Check if duration is evenly divisible with a single day
    if (86_400 >= duration) {
        return (0 == (86_400 % duration));
    }
    return false;
}

fn get_divisor(duration: u64) !u64 {
    if (60 == duration) {
        return 1;
    }
    // Check if duration is evenly divisible with a 10 minutes
    if (600 >= duration) {
        return @divFloor(600, duration);
    }
    // Check if duration is evenly divisible with a single hour
    if (3_600 >= duration) {
        return @divFloor(3_600, duration);
    }
    // Check if duration is evenly divisible with a single day
    if (86_400 >= duration) {
        return @divFloor(86_400, duration);
    }
    return error.InvalidDuration;
}
// New file format for simplicity in reading [camera_name]-YYYYMMDD_aabb_AABB
pub fn new_time(allocator: std.mem.Allocator, duration : u64) !void {
    if (false == is_valid_time_window(duration)) {
        return error.InvalidTimeWindow;
    }
    const raw_seconds_epoch = try get_current_epoch_sec(get_timezone_offset_in_sec(.EST));
    const epoch_seconds : std.time.epoch.EpochSeconds = .{ .secs = raw_seconds_epoch };
    const day_seconds = epoch_seconds.getDaySeconds();
    const epoch_day = epoch_seconds.getEpochDay();
    const year_and_day = epoch_day.calculateYearDay();
    const month_and_day = year_and_day.calculateMonthDay();

    const year = year_and_day.year;
    const month = month_and_day.month.numeric();
    const day = month_and_day.day_index;
    const hour = day_seconds.getHoursIntoDay();
    const minute = day_seconds.getMinutesIntoHour();

    var rollover_hour : bool = false;

    const next_minute = blk: {
        var calc_minute : u16 = minute + 10;
        calc_minute = calc_minute % 10;
        if (calc_minute >= 60) {
            calc_minute = 0;
            rollover_hour = true;
        }
        break :blk calc_minute;
    };

    const next_hour = blk: {
        var calc_hour : u16 = hour;
        if (rollover_hour) {
            calc_hour = calc_hour + 1;
            if (calc_hour >= 24) {
                calc_hour = 0;
            }
        }
        break :blk calc_hour;
    };

    return try std.fmt.allocPrint(allocator, "{d:0>4}{d:0>2}{d:0>2}_{d:0>2}{d:0>2}_{d:0>2}{d:0>2}", .{
        year,
        month,
        day,
        hour,
        minute,
        next_hour,
        next_minute,
    });
}

pub fn is_time_in_current_window(file_name: []const u8, allocator: std.mem.Allocator) !bool {
    const raw_current_epoch_sec = try get_current_epoch_sec(get_timezone_offset_in_sec(.EST));
    const epoch_seconds : std.time.epoch.EpochSeconds = .{ .secs = raw_current_epoch_sec };

    const year = try std.fmt.parseInt(u16, file_name[0..4], 10);
    const epoch_day = epoch_seconds.getEpochDay();
    const year_and_day = epoch_day.calculateYearDay();
    const current_year = year_and_day.year;
    if (current_year > year) {
        return false;
    }

    const month = try std.fmt.parseInt(u8, file_name[4..6], 10);
    const month_and_day = year_and_day.calculateMonthDay();
    const current_month = month_and_day.month.numeric();
    if (current_month > month) {
        return false;
    }

    const day = try std.fmt.parseInt(u8, file_name[6..8], 10);
    if (current_day > day) {
        return false;
    }
    if (current_hour > hour) {
        return false;
    }
    if (current_minute > minute) {
        return false;
    }

    const hour = try std.fmt.parseInt(u8, file_name[14..16], 10);
    const minute = try std.fmt.parseInt(u8, file_name[16..18], 10);

    const calculated_epoch_seconds : u64 = blk: {

    };
}
