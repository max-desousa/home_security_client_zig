pub const Camera = @This();

const std = @import("std");
const file_system = @import("file_system");
const debug = @import("debug");
const sync = @import("sync_data");
const c = @cImport({
    @cInclude("linux/videodev2.h");
    @cInclude("errno.h");
    @cInclude("sys/ioctl.h");
    @cInclude("string.h");
});

pub const buffer = struct {
    start: *anyopaque,
    length: usize,
};

file_descriptor: ?c_int,
device_name: ?[*:0]const u8,
allocator: std.mem.Allocator,
buffers: []buffer = undefined,
n_buffers: u8 = undefined,
private_head: usize = 0,
private_tail: usize = 0,

pub fn run(dev_name: [*:0]const u8, allocator: std.mem.Allocator, sync_data: *sync.SynchronousData) void {
    var cam = init(dev_name, allocator) catch |err| {
        std.debug.print("Error initializing camera...\n", .{});
        std.debug.print("\tError code: {any}\n", .{err});
        return;
    };
    defer cam.deinit();
    cam.infinite_capture(sync_data);
}

pub fn infinite_capture(self: *Camera, sync_data: *sync.SynchronousData) void {
    self.start_capturing() catch |err| {
        std.debug.print("There was an error starting the capturing of frames with the camera...\n", .{});
        std.debug.print("\tError code: {any}\n", .{err});
        {
            sync_data.mutex.lock();
            defer sync_data.mutex.unlock();
            sync_data.sync_error = sync.ThreadingErrors.CameraCouldNotStart;
        }
        return;
    };
    while (true) {
        if (null != sync_data.sync_error) {
            std.debug.print("External error - closing camera thread...\n", .{});
            std.debug.print("\tExternal error was: {any}\n", .{sync_data.sync_error.?});
            return;
        }
        const frame_captured = self.capture_single_frame() catch |err| {
            std.debug.print("Error capturing a frame from the camera...\n", .{});
            std.debug.print("\tError received was: {any}\n", .{err});
            {
                sync_data.mutex.lock();
                defer sync_data.mutex.unlock();
                sync_data.sync_error = sync.ThreadingErrors.CameraCouldNotCaptureFrame;
            }
            return;
        };

        if (null == frame_captured) continue;

        const shared = self.publish_frame_to_sync_data(frame_captured.?, sync_data);
        if (false == shared) {
            sync_data.mutex.lock();
            defer sync_data.mutex.unlock();
            sync_data.sync_error = sync.ThreadingErrors.CameraRunOutOfBuffers;
            std.debug.print("Camera ran out of buffers... aborting\n", .{});
            return;
        }
    }
}

fn publish_frame_to_sync_data(self: *Camera, buff_num: u8, sync_data: *sync.SynchronousData) bool {
    sync_data.push(@intCast(buff_num)) catch return false;
    self.private_head = sync_data.head;
    return true;
}

fn check_and_release_buffer(self: *Camera, sync_data: *sync.SynchronousData) void {
    if (self.private_tail == sync_data.tail) {
        return;
    }

    self.release_buffer(self.private_tail) catch |err| {
        sync_data.mutex.lock();
        defer sync_data.mutex.unlock();
        sync_data.sync_error = sync.ThreadingErrors.CameraCouldNotFreeBuffer;
        std.debug.print("Could not free buffer...\n", .{});
        std.debug.print("\tError received: {any}\n", .{err});
        return;
    };
    self.private_tail = ((self.private_tail + 1) % sync_data.BUFFER_SIZE);
}

pub fn init(dev_name: [*:0]const u8, allocator: std.mem.Allocator) !Camera {
    var camera: Camera = .{
        .file_descriptor = null,
        .device_name = dev_name,
        .allocator = allocator,
    };

    if (!check_if_device_exists(camera)) {
        return error.CameraDeviceNotFound;
    }

    try open_device(&camera);
    errdefer camera.deinit();

    if (!device_supports_video(camera)) {
        return error.DeviceDoesNotSupportVideo;
    }

    try configure_device(&camera);

    return camera;
}

pub fn deinit(self: *Camera) void {
    if (self.file_descriptor) |fd| {
        _ = std.c.close(fd);
        self.file_descriptor = null;
    }

    if (0 < self.buffers.len) {
        self.allocator.free(self.buffers);
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
    if (self.file_descriptor) |fd| {
        var cap: c.struct_v4l2_capability = std.mem.zeroes(c.struct_v4l2_capability);

        if (-1 == xioctl(fd, c.VIDIOC_QUERYCAP, &cap)) {
            std.debug.print("Failed to query device capabilities.\n", .{});
            return false;
        }

        if (0 == (cap.capabilities & c.V4L2_CAP_VIDEO_CAPTURE)) {
            std.debug.print("Device does not support video capture.\n", .{});
            return false;
        }

        if (0 == (cap.capabilities & c.V4L2_CAP_STREAMING)) {
            std.debug.print("Device does not support streaming I/O (our default method for handling cameras... at least for now.\n", .{});
            return false;
        }
    } else {
        return false;
    }

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

fn configure_device(self: *Camera) !void {
    if ((null == self.file_descriptor) or
        (null == self.device_name))
    {
        return error.NullValuesInDeviceObject;
    }
    var cropcap: c.struct_v4l2_cropcap = std.mem.zeroes(c.struct_v4l2_cropcap);
    var crop: c.struct_v4l2_crop = std.mem.zeroes(c.struct_v4l2_crop);
    var fmt: c.v4l2_format = std.mem.zeroes(c.v4l2_format);

    // Setting the crop of the sensor to try and ensure better imaging.
    cropcap.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (0 == xioctl(self.file_descriptor.?, c.VIDIOC_CROPCAP, &cropcap)) {
        crop.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        crop.c = cropcap.defrect;

        if (-1 == xioctl(self.file_descriptor.?, c.VIDIOC_S_CROP, &crop)) {
            const c_errno = std.c._errno().*;

            if ((c.EINVAL == c_errno) or
                (c.ENOTTY == c_errno) or
                (c.ENODEV == c_errno) or
                (c.EPERM == c_errno))
            {
                std.debug.print("Cropping not supported on this device.\n", .{});
            } else {
                std.debug.print("Failed to set crop rectangle.\n", .{});
            }
        } else {
            std.debug.print("Crop rectangle set successfully.\n", .{});
        }
    } else {
        std.debug.print("Failed to get crop capabilities.\n", .{});
    }

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

    try self.initialize_mmap();
}

fn initialize_mmap(self: *Camera) !void {
    if (null == self.file_descriptor) {
        return error.BadStructInstance;
    }

    var req: c.struct_v4l2_requestbuffers = std.mem.zeroes(c.struct_v4l2_requestbuffers);

    req.count = 50;
    req.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    req.memory = c.V4L2_MEMORY_MMAP;

    if (-1 == xioctl(self.file_descriptor.?, c.VIDIOC_REQBUFS, &req)) {
        std.debug.print("Failed to request buffer allocation via mmap.\n", .{});
        return error.RequestBuffersFailed;
    }

    if (2 > req.count) {
        std.debug.print("Insufficient buffer memory on device.\n", .{});
        return error.InsufficientBufferMemory;
    }

    self.buffers = try self.allocator.alloc(buffer, req.count);
    var n_buffers: u8 = 0;

    for (self.buffers) |b| {
        var buf: c.struct_v4l2_buffer = std.mem.zeroes(c.struct_v4l2_buffer);

        buf.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = c.V4L2_MEMORY_MMAP;
        buf.index = n_buffers;

        if (-1 == xioctl(self.file_descriptor.?, c.VIDIOC_QUERYBUF, &buf)) {
            std.debug.print("Failed to query buffer info.\n", .{});
            return error.QueryBufferFailed;
        }

        self.buffers[n_buffers].length = b.length;
        self.buffers[n_buffers].start = std.c.mmap(
            null,
            buf.length,
            std.c.PROT.READ | std.c.PROT.WRITE,
            .{ .TYPE = .SHARED },
            self.file_descriptor.?,
            buf.m.offset,
        );

        if (std.c.MAP_FAILED == self.buffers[n_buffers].start) {
            std.debug.print("Failed to map buffer to user space.\n", .{});
            return error.MmapFailed;
        }

        n_buffers += 1;
    }
}

fn start_capturing(self: Camera) !void {
    if ((null == self.file_descriptor) or
        (2 > self.buffers.len))
    {
        return error.BadStructInstance;
    }

    for (0..self.buffers.len) |index| {
        var buf: c.struct_v4l2_buffer = std.mem.zeroes(c.struct_v4l2_buffer);

        buf.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = c.V4L2_MEMORY_MMAP;
        buf.index = @intCast(index);

        if (-1 == xioctl(self.file_descriptor.?, c.VIDIOC_QBUF, &buf)) {
            std.debug.print("Failed to queue buffer {d}.\n", .{index});
            return error.QueueBufferFailed;
        }
    }

    var vtype: c.enum_v4l2_buf_type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (-1 == xioctl(self.file_descriptor.?, c.VIDIOC_STREAMON, &vtype)) {
        std.debug.print("Failed to start video streaming.\n", .{});
        return error.StartStreamingFailed;
    }
}

pub fn capture_single_frame(self: Camera) !?u8 {
    if (null == self.file_descriptor) {
        return error.BadStructInstance;
    }

    var buf: c.struct_v4l2_buffer = std.mem.zeroes(c.struct_v4l2_buffer);
    buf.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    buf.memory = c.V4L2_MEMORY_MMAP;

    if (-1 == xioctl(self.file_descriptor.?, c.VIDIOC_DQBUF, &buf)) {
        if (c.EAGAIN == std.c._errno().*) {
            return null;
        }
        std.debug.print("Failed to dequeue buffer.\n", .{});
        return error.DequeueBufferFailed;
    }
    std.debug.print("Captured frame in buffer index {d}.\n", .{buf.index});

    std.debug.print("Sending Frame data for encoding...\n", .{});
    return @intCast(buf.index);
}

fn release_buffer(self: Camera, buffer_index: u8) !void {
    var buf: c.struct_v4l2_buffer = std.mem.zeroes(c.struct_v4l2_buffer);
    buf.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    buf.memory = c.V4L2_MEMORY_MMAP;
    buf.index = @intCast(buffer_index);

    if (-1 == xioctl(self.file_descriptor.?, c.VIDIOC_QBUF, &buf)) {
        std.debug.print("Failed to re-queue buffer.\n", .{});
        return error.RequeueBufferFailed;
    }
}

//==============================================================================
// helper function suggested by ai due to ioctl being interruptible
//fn xioctl(fd: c_int, request: c_ulong, arg: *c.v4l2_capability) c_int {
//==============================================================================
fn xioctl(fd: c_int, request: c_ulong, arg: *anyopaque) c_int {
    var r: c_int = -1;
    r = c.ioctl(fd, request, arg);
    while (-1 == r and std.c._errno().* == c.EINTR) {
        r = c.ioctl(fd, request, arg);
    }
    return r;
}
