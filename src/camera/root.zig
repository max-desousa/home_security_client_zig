const std = @import("std");
const c = @cImport({
    @cInclude("linux/videodev2.h");
    @cInclude("errno.h");
    @cInclude("sys/ioctl.h");
});

fn check_if_device_exists(device_name: [*:0]const u8) !bool {
    var stat: std.c.Stat = undefined;

    if (-1 == std.c.stat(device_name, &stat)) {
        std.debug.print("Failed to get device status.\n", .{});
        return error.FStatFailed;
    }

    std.debug.print("Device status obtained.\n", .{});

    if (!std.c.S.ISCHR(stat.mode)) {
        std.debug.print("{s} is not a character device.\n", .{device_name});
        return error.NotCharacterDevice;
    }

    std.debug.print("{s} is a character device.\n", .{device_name});
    return true;
}

fn open_device(device_name: [:0]const u8) !c_int {
    const flags = std.c.O{ .ACCMODE = .RDWR, .NONBLOCK = true };
    const device = std.c.open(device_name, flags, @as(c_int, 0));
    if (-1 == device) {
        return error.OpenDeviceFailed;
    }
    return device;
}

pub fn init() !void {
    const device = try check_if_device_exists("/dev/video0");
    if (device) {
        std.debug.print("Camera device found.\n", .{});
    } else {
        return error.DeviceNotFound;
    }
    try configure_device();
}

fn configure_device() !void {
    var cap: c.v4l2_capability = std.mem.zeroes(c.v4l2_capability);

    const fd = std.c.open("/dev/video0", std.c.O{ .ACCMODE = .RDWR, .NONBLOCK = true });
    if (fd == -1) {
        std.debug.print("Failed to open device.\n", .{});
        return error.OpenDeviceFailed;
    }
    defer _ = std.c.close(fd);

    std.debug.print("Device opened successfully.\n", .{});

    if (-1 == xioctl(fd, c.VIDIOC_QUERYCAP, &cap)) {
        std.debug.print("Failed to query device capabilities.\n", .{});

        if (c.EINVAL == std.c._errno().*) {
            std.debug.print("Not a V4L2 device.\n", .{});
            return error.NotV4L2Device;
        } else {
            std.debug.print("VIDIOC_QUERYCAP error: {}\n", .{std.c._errno().*});
            return error.QueryCapFailed;
        }
        return error.QueryCapFailed;
    }
    std.debug.print("Device capabilities queried successfully.\n", .{});

    if ((cap.capabilities & c.V4L2_CAP_VIDEO_CAPTURE) == 0) {
        std.debug.print("Device does not support video capture.\n", .{});
        return error.NoVideoCaptureSupport;
    }
    std.debug.print("Device supports video capture.\n", .{});

    std.debug.print("Device: {s}\n", .{cap.card});
    std.debug.print("Driver: {s}\n", .{cap.driver});
    std.debug.print("Bus Info: {s}\n", .{cap.bus_info});

    var fmt: c.v4l2_format = std.mem.zeroes(c.v4l2_format);
    fmt.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    fmt.fmt.pix.width = 640;
    fmt.fmt.pix.height = 480;
    fmt.fmt.pix.pixelformat = c.V4L2_PIX_FMT_YUYV;

    if (-1 == xioctl(fd, c.VIDIOC_S_FMT, &fmt)) {
        std.debug.print("Failed to set pixel format.\n", .{});
        return error.SetFormatFailed;
    }

    std.debug.print("Pixel format set successfully.\n", .{});
    std.debug.print("Configured format:\n", .{});
    std.debug.print("\tWidth: {d}\n", .{fmt.fmt.pix.width});
    std.debug.print("\tHeight: {d}\n", .{fmt.fmt.pix.height});
    std.debug.print("\tPixel Format: {x}\n", .{fmt.fmt.pix.pixelformat});
}

// helper function suggested by ai due to ioctl being interruptible
//fn xioctl(fd: c_int, request: c_ulong, arg: *c.v4l2_capability) c_int {
fn xioctl(fd: c_int, request: c_ulong, arg: *anyopaque) c_int {
    var r: c_int = -1;
    r = c.ioctl(fd, request, arg);
    while (-1 == r and std.c._errno().* == c.EINTR) {
        r = c.ioctl(fd, request, arg);
    }
    return r;
}
