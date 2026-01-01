const std = @import("std");
const config = @import("config");

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

    return try std.fmt.allocPrint(
        allocator, 
        "{d:0>2}:{d:0>2}:{d:0>2}",
        .{hours_into_day, minutes_into_hour, seconds_into_minute}
    );
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
//              uses the posix library.
//
//##############################################################################
pub fn get_current_epoch_sec(offset : i64) !u64 {
    const raw_epoch = try std.posix.clock_gettime(.REALTIME);
    const epoch : u64 = @intCast(raw_epoch.sec);

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

const DAY_IN_SECONDS : u64 = 86_400;

//##############################################################################
//
// Funtion: get_windowed_time_for_filename_string
//
// Description: This function returns a string - WHICH MUST BE FREED
//              (allocator.free()) for a window of time that will be used in
//              the filename for the webcam data. 
//              
//              Output format will be "[camera]-YYYYMMDD_HHMM_hhmm". This will
//              append to any name for the camera and will be a somewhat
//              convenient way of knowing what time frame the data on the
//              webcam is for.
//
//##############################################################################
pub fn get_windowed_time_for_filename_string(allocator: std.mem.Allocator, duration : u64) ![:0]u8 {
    if (DAY_IN_SECONDS < duration) {
        return error.InvalidTimeWindow;
    }

    const raw_epoch_seconds_start = try get_current_epoch_sec(config.get_utc_offset_seconds());
    const raw_epoch_seconds_end = raw_epoch_seconds_start + duration;

    const start_epoch_seconds : std.time.epoch.EpochSeconds = .{ .secs = raw_epoch_seconds_start };
    const end_epoch_seconds : std.time.epoch.EpochSeconds = .{ .secs = raw_epoch_seconds_end };

    const start_epoch_day = start_epoch_seconds.getEpochDay();
    const start_year_and_day = start_epoch_day.calculateYearDay();
    const year = start_year_and_day.year;
    const start_month_and_day = start_year_and_day.calculateMonthDay();
    const month = start_month_and_day.month.numeric();
    const day = start_month_and_day.day_index + 1;

    const start_day_seconds = start_epoch_seconds.getDaySeconds();
    const start_hour = start_day_seconds.getHoursIntoDay();
    const start_minute = start_day_seconds.getMinutesIntoHour();

    const end_day_seconds = end_epoch_seconds.getDaySeconds();
    const end_hour = end_day_seconds.getHoursIntoDay();
    const end_minute = end_day_seconds.getMinutesIntoHour();

    var adjusted_minutes = switch (duration) {
        0...60 => end_minute,
        120 => (@divFloor(end_minute, 2) * 2),
        300 => (@divFloor(end_minute, 5) * 5),
        600 => (@divFloor(end_minute, 10) * 10),
        3_600 => 0,
        7_200 => 0,
        10_800 => 0,
        14_400 => 0,
        21_600 => 0,
        28_800 => 0,
        43_200 => 0,
        86_400 => 0,
        else => end_minute,
    };

    var adjusted_hour = switch (duration) {
        7_200 => (@divFloor(end_hour, 2) * 2),
        10_800 => (@divFloor(end_hour, 3) * 3),
        14_400 => (@divFloor(end_hour, 4) * 4),
        21_600 => (@divFloor(end_hour, 6) * 6),
        28_800 => (@divFloor(end_hour, 8) * 8),
        43_200 => (@divFloor(end_hour, 12) * 12),
        86_400 => 0,
        else => end_hour,
    };

    // Handle when we naturally roll over to midnight. This check is specific
    // to smaller increments that were naturally adjusted and will hit the end
    // of the day.
    if ((0 == adjusted_hour) and
        (0 == adjusted_minutes)) {
        adjusted_hour = 24;
        adjusted_minutes = 0;
    }

    const end_epoch_day = end_epoch_seconds.getEpochDay();
    const end_year_and_day = end_epoch_day.calculateYearDay();
    const end_month_and_day = end_year_and_day.calculateMonthDay();
    const end_day = end_month_and_day.day_index + 1;

    // Handle when a custom time rolls over to the next day (we don't support
    // it in this filename format). When this happens we'll truncate the video
    // to end at 24:00 of the starting day, then the custom time will be picked
    // up in the next file.
    //
    // This instance/check only applies to times that weren't adjustd
    // previously "nice" even times that naturally had 00:00 ending's - (say...
    // a 7 hour video duration selected by the user)
    if (((adjusted_minutes != 0) or 
         (adjusted_hour != 0)) and 
        (end_day != day)){
        adjusted_hour = 24;
        adjusted_minutes = 0;
    }


    return try std.fmt.allocPrintSentinel(
        allocator,
        "{d:0>4}{d:0>2}{d:0>2}_{d:0>2}{d:0>2}_{d:0>2}{d:0>2}",
        .{
            year,
            month,
            day,
            start_hour,
            start_minute,
            adjusted_hour,
            adjusted_minutes,
        },
        0,
    );
}


//##############################################################################
//
// Function:
//
// Description: This is a function that takes the string - intended for the
//              filename for a recording - that represents a window of time and
//              determins if the current time is within that window.
//              
//              The most common (intended) use case for this function is to
//              determine if a new recording file should be started based on
//              the current time and the window of time represented by the
//              filename.
//
//##############################################################################
pub fn is_time_in_current_window(file_name: []const u8) !bool {
    // Create epoch object for current time (can err due to posix call)
    const raw_current_epoch_sec = try get_current_epoch_sec(config.get_utc_offset_seconds());
    const epoch_seconds : std.time.epoch.EpochSeconds = .{ .secs = raw_current_epoch_sec };

    const str_len = file_name.len;

    // Get numerical values from the filename string to compare against
    const target_year = try std.fmt.parseInt(u16, file_name[(str_len - 18)..(str_len - 14)], 10);
    const target_month = try std.fmt.parseInt(u8, file_name[(str_len - 14)..(str_len - 12)], 10);
    const target_day = try std.fmt.parseInt(u8, file_name[(str_len - 12)..(str_len - 10)], 10);
    const target_start_hour = try std.fmt.parseInt(u17, file_name[(str_len - 9)..(str_len - 7)], 10);
    const target_start_minute = try std.fmt.parseInt(u17, file_name[(str_len - 7)..(str_len - 5)], 10);
    const target_end_hour = try std.fmt.parseInt(u17, file_name[(str_len - 4)..(str_len - 2)], 10);
    const target_end_minute = try std.fmt.parseInt(u17, file_name[(str_len - 2)..(str_len)], 10);

    // Check that year is valid
    const epoch_day = epoch_seconds.getEpochDay();
    const year_and_day = epoch_day.calculateYearDay();
    const current_year = year_and_day.year;
    if (target_year != current_year) {
        return false;
    }

    // Check that month is valid
    const month_and_day = year_and_day.calculateMonthDay();
    const current_month = month_and_day.month.numeric();
    if (target_month != current_month) {
        return false;
    }

    // Check that day is valid
    const current_day = month_and_day.day_index + 1;
    if (target_day != current_day) {
        return false;
    }

    // get seconds into the day for current time
    const day_seconds = epoch_seconds.getDaySeconds();
    const seconds_into_day = day_seconds.secs;

    // convert the target times into seconds into the day
    const end_time_in_day_seconds : u17 = @intCast((target_end_hour * 3600) + (target_end_minute * 60));
    const start_time_in_day_seconds : u17 = @intCast((target_start_hour * 3600) + (target_start_minute * 60));

    // Check that current time is within the window (using reference to seconds into the day)
    const in_window = (seconds_into_day >= start_time_in_day_seconds) and (seconds_into_day <= end_time_in_day_seconds);
    return in_window;
}
