const std = @import("std");

pub fn get_current_video_time_stamp() !void {
    var time : std.c.timespec = undefined;
    const ptr_to_time = &time;
    const foo = std.c.clock_gettime((std.c.CLOCK.REALTIME), ptr_to_time);
    std.debug.print("clock_gettime() returns: {any}\n", .{ foo } );
    std.debug.print("timespec: sec={d}, nsec={d}\n", .{ time.sec, time.nsec } );
    std.debug.print("Current video timestamp (nanoseconds since epoch): {d}\n", .{ (time.sec * 1_000_000_000) + time.nsec } );

    var epoch_seconds : std.time.epoch.EpochSeconds = .{ .secs = @intCast(time.sec) };

    var epochDay = epoch_seconds.getEpochDay();

    //const year_and_day = std.time.epoch.EpochDay.calculateYearDay(val.getEpochDay());
    const year_and_day = epochDay.calculateYearDay();

    std.debug.print("Current Year: {d}\n", .{ year_and_day.year });
    std.debug.print("Current Month: {d}\n", .{ year_and_day.calculateMonthDay().month.numeric() });
    std.debug.print("Current Month (name): {s}\n", .{ @tagName(year_and_day.calculateMonthDay().month) });
    std.debug.print("Current Day: {d}\n", .{ year_and_day.calculateMonthDay().day_index });
    std.debug.print("\t(fraction of year = {d}/365)\n", .{ year_and_day.day });
    const epoch_day_seconds = 
    //std.debug.print("Current Hour: {d}\n", .{});
    //std.debug.print("Current Minute: {d}\n", .{});
    //std.debug.print("Current Second: {d}\n", .{});
}

//pub fn main() !void {
//    var debug_allocator : std.heap.DebugAllocator(.{}) = .init;
//    defer _ = debug_allocator.deinit();
//    const allocator = debug_allocator.allocator();
//    //const allocator = std.heap.page_allocator;
//    const temp = try get_current_time_as_string(allocator);
//    defer allocator.free(temp);
//    std.debug.print("The current time is: {s}\n", .{temp});
//
//    const temp2 = try get_time_for_filename_string(allocator, 0);
//    defer allocator.free(temp2);
//    std.debug.print("The filename version of the clock is: {s}\n", .{temp2});
//
//    const start_time = try get_time_for_filename_string(allocator, 0);
//    defer allocator.free(start_time);
//    const end_time = try get_time_for_filename_string(allocator, 600);
//    defer allocator.free(end_time);
//
//    const file_name = try std.fmt.allocPrint(allocator, "FrontDoor_{s}-{s}", .{start_time, end_time});
//    defer allocator.free(file_name);
//    std.debug.print("proposed filename would be: \"{s}\"\n", .{file_name});
//    const are_we = try file_name_actve(file_name);
//    if (are_we) {
//        std.debug.print("yes\n", .{});
//    } else {
//        std.debug.print("no\n", .{});
//    }
//}

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

fn within_time_frame_of_filename(file_name : []const u8) !bool {
    var debug_allocator : std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

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
