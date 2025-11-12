const Camera = @This();

const std = @import("std");
const file_system = @import("file_system");
const c = @cImport({
    @cInclude("linux/videodev2.h");
    @cInclude("errno.h");
    @cInclude("sys/ioctl.h");
});

file_descriptor: ?c_int,
device_name: ?[*:0]const u8,

pub fn init(dev_name: [*:0]const u8) !Camera {
    var camera: Camera = .{
        .file_descriptor = null,
        .device_name = dev_name,
    };

    if (!check_if_device_exists(camera)) {
        return error.CameraDeviceNotFound;
    }
    if (!device_supports_video(camera)) {
        return error.DeviceDoesNotSupportVideo;
    }
    try open_device(&camera);
    errdefer camera.deinit();

    try configure_device(camera);

    return camera;
}

pub fn deinit(self: *Camera) void {
    if (self.file_descriptor) |fd| {
        _ = std.c.close(fd);
        self.file_descriptor = null;
    }
}

fn check_if_device_exists(self: Camera) bool {
    if (self.device_name) |name| {
        var stat: std.c.Stat = undefined;

        if (-1 == std.c.stat(name, &stat)) {
            std.debug.print("Failed to get device status.\n", .{});
            return false;
            //return error.FStatFailed;
        }

        std.debug.print("Device status obtained.\n", .{});

        if (!std.c.S.ISCHR(stat.mode)) {
            std.debug.print("{s} is not a character device.\n", .{name});
            return false;
            //return error.NotCharacterDevice;
        }

        std.debug.print("{s} is a character device.\n", .{name});
        return true;
    } else {
        return false;
    }
}

fn device_supports_video(self: Camera) bool {
    _ = &self;
    return true;
}

fn open_device(self: *Camera) !void {
    var device: c_int = -1;
    if (self.device_name) |name| {
        const flags = std.c.O{ .ACCMODE = .RDWR, .NONBLOCK = true };
        device = std.c.open(name, flags, @as(c_int, 0));
        if (-1 == device) {
            return error.OpenDeviceFailed;
        }
    } else {
        return error.OpenDeviceFailed;
    }
    self.file_descriptor = device;
}

fn configure_device(self: Camera) !void {
    if ((null == self.file_descriptor) or
        (null == self.device_name))
    {
        return error.NullValuesInDeviceObject;
    }

    var cap: c.v4l2_capability = std.mem.zeroes(c.v4l2_capability);

    std.debug.print("Device opened successfully.\n", .{});

    if (-1 == xioctl(self.file_descriptor.?, c.VIDIOC_QUERYCAP, &cap)) {
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

    if (-1 == xioctl(self.file_descriptor.?, c.VIDIOC_S_FMT, &fmt)) {
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
