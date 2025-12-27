const std = @import("std");
//##############################################################################
//
// Enum for time zones. This will almost eclusively be used with the
// get_timezone_offset_in_sec function.
//
//###############################################################################
const Timezone = enum {
    EST,
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
fn get_windowed_time_for_filename_string(allocator: std.mem.Allocator, offset : u64) ![]const u8 {
    const start_time = try get_time_for_filename_string(allocator, 0);
    defer allocator.free(start_time);
    const end_time = try get_windowed_time_for_filename_string(allocator, offset);
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
pub fn get_current_epoch_sec(offset : i64) void {
    const epoch = try std.posix.clock_gettime(.REALTIME);
    //This is the hardcoded offset for EST
    const positive_offset : bool = (offset > 0);
    const abs_offset = @abs(offset);
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
