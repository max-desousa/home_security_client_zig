const std = @import("std");
const config = @import("config");

const DAY_IN_SECONDS : u64 = 86_400;

//##############################################################################
//
// Function: get_current_epoch_sec()
//
// Description: Use this function to get the current epoch seconds as a u64. It
//              uses the posix library.
//
//##############################################################################
pub fn get_current_epoch_sec(io : std.Io, offset : i64) !u64 {
    const raw_epoch_seconds = std.Io.Clock.now(.real, io).toSeconds();
    const epoch : u64 = @intCast(raw_epoch_seconds);

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
//              Note! This function is currently marked "old". We'll see if it
//              gets weaved back into the project, but to minimize data loss
//              (if the camera was attacked) - we need smaller files uploaded
//              to the server. This means the target 10 minute window is
//              impractical. A similar function will be made for generating a
//              file name schema that's for files that will be under 1 minute
//              in duration. 
//
//##############################################################################
pub fn old_get_windowed_time_for_filename_string(
    allocator: std.mem.Allocator,
    io : std.Io, 
    duration : u64
) ![:0]u8 {
    if (DAY_IN_SECONDS < duration) {
        return error.InvalidTimeWindow;
    }

    const raw_epoch_seconds_start = try get_current_epoch_sec(io, config.get_utc_offset_seconds());
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
// Funtion: get_windowed_time_for_filename_string
//
// Description: This function returns a string - WHICH MUST BE FREED
//              (allocator.free()) for a window of time that will be used in
//              the filename for the webcam data. 
//              
//              Output format will be "[camera]-YYYYMMDD_HHMM_SS_ss". This will
//              append to any name for the camera and will be a somewhat
//              convenient way of knowing what time frame the data on the
//              webcam is for.
//
//              In this version SS is the starting seconds within the clock and 
//              ss is the endcing seconds. (this is designed to be sub-minute
//              configuration)
//
//##############################################################################
pub fn get_windowed_time_for_filename_string(
    allocator: std.mem.Allocator,
    io : std.Io, 
    duration : u64
) ![:0]u8 {
    if (DAY_IN_SECONDS < duration) {
        return error.InvalidTimeWindow;
    }

    if (duration > 60) {
        return error.TooLongDurationWhenUsingSubMinuteArchitecture;
    }

    const raw_epoch_seconds_start = try get_current_epoch_sec(io, config.get_utc_offset_seconds());

    const start_epoch_seconds : std.time.epoch.EpochSeconds = .{ .secs = raw_epoch_seconds_start };

    const start_epoch_day = start_epoch_seconds.getEpochDay();
    const start_year_and_day = start_epoch_day.calculateYearDay();
    const year = start_year_and_day.year;
    const start_month_and_day = start_year_and_day.calculateMonthDay();
    const month = start_month_and_day.month.numeric();
    const day = start_month_and_day.day_index + 1;

    const start_day_seconds = start_epoch_seconds.getDaySeconds();
    const start_hour = start_day_seconds.getHoursIntoDay();
    const start_minute = start_day_seconds.getMinutesIntoHour();
    const start_seconds = start_day_seconds.getSecondsIntoMinute();

    var adjusted_seconds = start_seconds + duration;

    if (adjusted_seconds > 60) {
        adjusted_seconds = 60;
    }

    return try std.fmt.allocPrintSentinel(
        allocator,
        "{d:0>4}{d:0>2}{d:0>2}_{d:0>2}{d:0>2}_{d:0>2}_{d:0>2}",
        .{
            year,
            month,
            day,
            start_hour,
            start_minute,
            start_seconds,
            adjusted_seconds,
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
pub fn is_time_in_current_window(io : std.Io, file_name: []const u8) !bool {

    const nullable_period_cut = std.mem.cutLast(u8, file_name, ".");
    const period_cut = nullable_period_cut orelse return error.BadFileNameNoPeriod;
    const nullable_dash_cut = std.mem.cutLast(u8, period_cut.@"0", "-");
    const dash_cut = nullable_dash_cut orelse return error.BadFileNameNoDash;
    const file_name_window_string = dash_cut.@"1";

    // Create epoch object for current time (can err due to posix call)
    const raw_current_epoch_sec = try get_current_epoch_sec(io, config.get_utc_offset_seconds());
    const epoch_seconds : std.time.epoch.EpochSeconds = .{ .secs = raw_current_epoch_sec };

//YYYY
//MM
//DD
//_
//HH
//MM
//_
//SS
//_
//ss
    // Get numerical values from the filename string to compare against
    const target_year = try std.fmt.parseInt(u16, file_name_window_string[0..4], 10);
    const target_month = try std.fmt.parseInt(u8, file_name_window_string[4..6], 10);
    const target_day = try std.fmt.parseInt(u8, file_name_window_string[6..8], 10);
    const target_hour = try std.fmt.parseInt(u17, file_name_window_string[9..11], 10);
    const target_minute = try std.fmt.parseInt(u17, file_name_window_string[11..13], 10);
    const target_start_seconds = try std.fmt.parseInt(u17, file_name_window_string[14..16], 10);
    const target_end_seconds = try std.fmt.parseInt(u17, file_name_window_string[17..], 10);

    //std.debug.print("Checking year...\n", .{});
    // Check that year is valid
    const epoch_day = epoch_seconds.getEpochDay();
    const year_and_day = epoch_day.calculateYearDay();
    const current_year = year_and_day.year;
    if (target_year != current_year) {
        return false;
        //std.debug.print("Current year: {d}\nTarget year: {d}\n", .{current_year, target_year});
        //return error.NotMatchingYear;
    }

    //std.debug.print("Checking month...\n", .{});
    // Check that month is valid
    const month_and_day = year_and_day.calculateMonthDay();
    const current_month = month_and_day.month.numeric();
    if (target_month != current_month) {
        return false;
        //return error.NotMatchingMonth;
    }

    //std.debug.print("Checking day...\n", .{});
    // Check that day is valid
    const current_day = month_and_day.day_index + 1;
    if (target_day != current_day) {
        return false;
        //return error.NotMatchingDay;
    }

    //std.debug.print("Checking hour...\n", .{});
    const epoch_day_seconds = epoch_seconds.getDaySeconds();
    const current_hour = epoch_day_seconds.getHoursIntoDay();
    if (target_hour != current_hour) {
        return false;
        //return error.NotMatchingHour;
    }

    //std.debug.print("Checking minute...\n", .{});
    const current_minute = epoch_day_seconds.getMinutesIntoHour();
    if (target_minute != current_minute) {
        return false;
        //return error.NotMatchingMinute;
    }

    const current_seconds = epoch_day_seconds.getSecondsIntoMinute();
    if (current_seconds < target_start_seconds) {
        return false;
        //return error.FirstSecondCheck;
    }

    if (current_seconds >= target_end_seconds) {
        return false;
        //return error.SecondSecondCheck;
    }

    if ((target_end_seconds == 60) and
        (current_seconds < 30)) {
        return false;
    }

    return true;
}
