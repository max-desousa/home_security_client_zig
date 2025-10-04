const std = @import("std");
const c = @cImport({
    @cInclude("linux/videodev2.h"); // V4L2 headers (install linux-headers if needed)
    @cInclude("sys/ioctl.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("errno.h");
});

pub fn check_if_device_exists(device_name: []const u8) !bool {
    const file = std.fs.openFileAbsolute(device_name, .{ .mode = .read_only }) catch |err| {
        if (err == error.FileNotFound) return false;
        return err; // Propagate other errors
    };
    defer file.close();
    return true;
}

pub fn openDevice(path: []const u8) !c_int {
    const allocator = std.heap.page_allocator;
    const null_terminated_path = try allocator.allocSentinel(u8, path.len, 0);
    defer allocator.free(null_terminated_path);

    @memcpy(null_terminated_path[0..path.len], path);

    //const fd = std.c.open(null_terminated_path, std.os.linux.O.RDWR | std.c.O_NONBLOCK, 0);
    const fd = std.c.open(null_terminated_path, .{}, 0);
    if (fd == -1) {
        return error.OpenFailed;
    }
    return fd;
}

pub fn setFrameRate(fd: c_int, fps: u32) !void {
    var fmt: c.struct_v4l2_format = undefined;
    fmt.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;

    // Step 1: Query current format
    if (c.ioctl(fd, c.VIDIOC_G_FMT, &fmt) == -1) {
        return error.QueryFormatFailed;
    }

    // Step 2: Set desired pixel format (e.g., MJPG for compressed, YUYV for raw)
    fmt.fmt.pix.pixelformat = c.V4L2_PIX_FMT_MJPG; // Or V4L2_PIX_FMT_YUYV
    fmt.fmt.pix.field = c.V4L2_FIELD_ANY;

    // Step 3: Set the format (this may implicitly set FPS based on device capabilities)
    if (c.ioctl(fd, c.VIDIOC_S_FMT, &fmt) == -1) {
        return error.SetFormatFailed;
    }

    // Step 4: Explicitly set frame rate (using frame intervals)
    var frameint: c.struct_v4l2_streamparm = undefined;
    frameint.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (c.ioctl(fd, c.VIDIOC_G_PARM, &frameint) == -1) {
        return error.QueryParmFailed;
    }

    frameint.parm.capture.timeperframe.numerator = 1;
    frameint.parm.capture.timeperframe.denominator = fps; // FPS = denominator / numerator
    frameint.parm.capture.capturemode = c.V4L2_MODE_VIDEO; // Or other modes if needed

    if (c.ioctl(fd, c.VIDIOC_S_PARM, &frameint) == -1) {
        std.debug.print("Warning: Could not set FPS to {d} (device may not support it)\n", .{fps});
        // Check errno for details: c.errno
    }

    // Verify
    if (c.ioctl(fd, c.VIDIOC_G_PARM, &frameint) == -1) {
        return error.VerifyParmFailed;
    }
    const actual_fps = frameint.parm.capture.timeperframe.denominator / frameint.parm.capture.timeperframe.numerator;
    std.debug.print("Set FPS: {d} (actual: {d})\n", .{ fps, actual_fps });
}
