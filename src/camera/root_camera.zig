//! V4L2 capture device.
//!
//! `init` opens the device, checks that it can capture video, and memory-maps
//! the driver buffers into `frame_metadata`. `infinite_capture` is the camera
//! thread: it starts streaming, dequeues a filled buffer, and pushes that
//! buffer's index to the encoder. The encoder sends indexes back when it is
//! done so this thread can requeue them with `VIDIOC_QBUF`.

pub const Camera = @This();

const std = @import("std");
const sync = @import("sync_data");
const v4l = @import("v4l");
const config = @import("config");

/// One memory-mapped V4L2 buffer and the frame currently stored in it.
pub const MemoryMappedFrame = struct {
    /// Address returned by the V4L2 memory map.
    start_address: *anyopaque,
    /// Size of the mapped buffer, in bytes.
    max_length: u32,
    /// Bytes occupied by the frame currently in this buffer.
    bytes_used: u32 = 0,
    /// Capture timestamp. The encoder uses it to pace frames when the camera lags.
    time_stamp: v4l.struct_timeval = std.mem.zeroes(v4l.struct_timeval),
};

file_descriptor: ?c_int,
device_name: ?[*:0]const u8,
allocator: std.mem.Allocator,
frame_metadata: []MemoryMappedFrame = &.{},


/// Camera thread. `init` must have succeeded first.
///
/// Queues the mapped buffers, starts streaming, and loops:
/// requeue every index sitting on `frames_to_requeue`, dequeue one captured
/// frame, then push that buffer index onto `frames_to_encode`.
///
/// This thread does not encode and does not free a buffer until the encoder
/// returns its index. Closing either queue, or an ioctl error, ends the thread.
pub fn infinite_capture(
    self: *Camera, 
    io : std.Io, 
    frames_to_encode : *std.Io.Queue(usize),
    frames_to_requeue : *std.Io.Queue(usize),
) void {
    // Queue all buffers and start stream.
    self.start_capturing() catch |err| {
        std.log.debug("There was an error starting the capturing of frames with the camera...", .{});
        std.log.debug("\tError code: {any}", .{err});
        frames_to_encode.close(io);
        return;
    };

    // infintely capture frames. 
    while (true) {
        //returning all possible frames to v4l after they've been encoded
        {
        var frames_to_free : [32]usize = undefined;
        const number_of_frames_to_free = frames_to_requeue.get(
            io, 
            &frames_to_free,
            0
        ) catch |err| {
            std.log.err("Aborting camera capture logic due to encoder closing communication: {any}\n", .{ err });
            return;
        };
        for (0..number_of_frames_to_free) |i| {
            self.release_buffer(@intCast(frames_to_free[i])) catch |err| {
                std.log.err("Error freeing the buffer and returning it to v4l. Closing comms with encoder and aborting camera thread. (error: {any})\n", .{ err });
                frames_to_encode.close(io);
                return;
            };
        }
        }


        // Attempt to capture / check if next frame is available. 
        const nullable_frame_captured = self.capture_single_frame() catch |err| {
            std.log.debug("Error capturing a frame from the camera...", .{});
            std.log.debug("\tError received was: {any}", .{err});
            std.log.debug("\tClosing comms with encoder and ending camera infinite capturing", .{});
            frames_to_encode.close(io);
            return;
        };

        // if we're here there was no error in calling the capture logic, but
        // we need to check that a new frame was provided (output was not null)
        const frame_captured = nullable_frame_captured orelse continue;

        // add buffer to list to encode
        frames_to_encode.putOne(io, @intCast(frame_captured)) catch |err| {
            std.log.debug("Issue detected giving frame index to encoder for transfer: {any}", .{ err });
            std.log.debug("Closing queue (probably redundant) and aborting camera capture...", .{});
            frames_to_encode.close(io);
            return;
        };
    }
}


/// Open `dev_name`, require video capture, and map the driver's buffers.
///
/// Returns `error.CameraDeviceNotFound` when the path does not exist and
/// `error.DeviceDoesNotSupportVideo` when the device is not a capture device.
/// On any later failure the file descriptor is closed before the error returns.
pub fn init(dev_name: [:0]const u8, allocator: std.mem.Allocator) !Camera {
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

/// Close the device and free the frame-metadata slice.
pub fn deinit(self: *Camera) void {
    if (self.file_descriptor) |fd| {
        _ = std.c.close(fd);
        self.file_descriptor = null;
    }

    if (0 < self.frame_metadata.len) {
        self.allocator.free(self.frame_metadata);
    }
}

fn check_if_device_exists(self: Camera) bool {
    if (self.device_name) |name| {
        var statx: std.os.linux.Statx = undefined;

        const statx_check = std.c.statx(
            std.c.AT.FDCWD,
            name,
            0,
            .BASIC_STATS,
            &statx,
        );

        if (-1 == statx_check) {
            std.log.debug("Failed to get device status.", .{});
            return false;
            //return error.FStatFailed;
        }

        if (!std.c.S.ISCHR(statx.mode)) {
            std.log.err("{s} is not a character device.", .{name});
            return false;
            //return error.NotCharacterDevice;
        }
        return true;
    } 
    else {
        return false;
    }
}

fn device_supports_video(self: Camera) bool {
    if (self.file_descriptor) |fd| {
        var cap: v4l.struct_v4l2_capability = std.mem.zeroes(v4l.struct_v4l2_capability);

        if (-1 == xioctl(fd, v4l.VIDIOC_QUERYCAP, &cap)) {
            std.log.debug("Failed to query device capabilities.", .{});
            return false;
        }

        if (0 == (cap.capabilities & v4l.V4L2_CAP_VIDEO_CAPTURE)) {
            std.log.debug("Device does not support video capture.", .{});
            return false;
        }

        if (0 == (cap.capabilities & v4l.V4L2_CAP_STREAMING)) {
            std.log.debug("Device does not support streaming I/O (our default method for handling cameras... at least for now.", .{});
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
        const flags = std.c.O{ .ACCMODE = .RDWR };
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
    var cropcap: v4l.struct_v4l2_cropcap = std.mem.zeroes(v4l.struct_v4l2_cropcap);
    var crop: v4l.struct_v4l2_crop = std.mem.zeroes(v4l.struct_v4l2_crop);
    var fmt: v4l.v4l2_format = std.mem.zeroes(v4l.v4l2_format);

    // Setting the crop of the sensor to try and ensure better imaging.
    cropcap.type = v4l.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (0 == xioctl(self.file_descriptor.?, v4l.VIDIOC_CROPCAP, &cropcap)) {
        crop.type = v4l.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        crop.c = cropcap.defrect;

        if (-1 == xioctl(self.file_descriptor.?, v4l.VIDIOC_S_CROP, &crop)) {
            const c_errno = std.c._errno().*;

            if ((v4l.EINVAL == c_errno) or
                (v4l.ENOTTY == c_errno) or
                (v4l.ENODEV == c_errno) or
                (v4l.EPERM == c_errno))
            {
                std.log.warn("Cropping not supported on this device.", .{});
            } else {
                std.log.err("Failed to set crop rectangle.", .{});
            }
        } else {
            std.log.info("Crop rectangle set successfully.", .{});
        }
    } else {
        std.log.err("Failed to get crop capabilities.\n", .{});
    }

    fmt.type = v4l.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    fmt.fmt.pix.width = config.get_camera_width();
    fmt.fmt.pix.height = config.get_camera_height();
    fmt.fmt.pix.pixelformat = v4l.V4L2_PIX_FMT_YUYV;

    if (-1 == xioctl(self.file_descriptor.?, v4l.VIDIOC_S_FMT, &fmt)) {
        std.log.debug("Failed to set pixel format.", .{});
        return error.SetFormatFailed;
    }

    if (config.get_crash_on_vid_diff()) {
        std.log.debug("Set to validate camera settings... checking now", .{});
        var validated_fmt: v4l.v4l2_format = std.mem.zeroes(v4l.v4l2_format);
        validated_fmt.type = v4l.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        if (-1 == xioctl(self.file_descriptor.?, v4l.VIDIOC_G_FMT, &validated_fmt)) {
            std.log.debug("Could not get video settings", .{});
            return error.CouldNotValidateCameraSettings;
        }
        if ((config.get_camera_width() != validated_fmt.fmt.pix.width) or
            (config.get_camera_height() != validated_fmt.fmt.pix.height)) {
            std.log.err("Camera not configured correctly", .{});
            std.log.debug("\twidth x height = {d}x{d}", .{validated_fmt.fmt.pix.width, validated_fmt.fmt.pix.width});
            return error.CameraSettingsDontMatchConfig;
        } else {
            std.log.debug("CAMERA SET CORRECTLY", .{});
        }
    } else {
        std.log.debug("Assuming pixel format set successfully.", .{});
        std.log.debug("Configured format:", .{});
        std.log.debug("\tWidth: {d}", .{fmt.fmt.pix.width});
        std.log.debug("\tHeight: {d}", .{fmt.fmt.pix.height});
        std.log.debug("\tPixel Format: {x}", .{fmt.fmt.pix.pixelformat});
    }

    try self.attempt_to_set_frame_rate();

    try self.initialize_mmap();
}

fn attempt_to_set_frame_rate(self: *Camera) !void {
    const crash_on_diff = config.get_crash_on_vid_diff();

    var stream_parm : v4l.struct_v4l2_streamparm = std.mem.zeroes(v4l.struct_v4l2_streamparm);
    stream_parm.type = v4l.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (-1 == xioctl(self.file_descriptor.?, v4l.VIDIOC_G_PARM, &stream_parm)) {
        std.log.debug("Failed to get current frame rate settings.", .{});
        return error.ErrorGettingCameraParams;
    }

    const dev_supports_frame_rate : bool = (stream_parm.parm.capture.capability & v4l.V4L2_CAP_TIMEPERFRAME) != 0;

    if ((!dev_supports_frame_rate) and 
        (crash_on_diff)) {
        std.log.debug("Device does not support frame rate adjustment and user as asked to crash on difference.", .{});
        return error.DeviceDoesNotSupportFrameRateSetting;
    }

    if (!dev_supports_frame_rate) {
        std.log.debug("Device does not support frame rate adjustment - skipping frame rate set.", .{});
        std.log.debug("Warning: Frame rate may not be as expected and encoder WILL use your requested frame rate regardless of actual camera frame rate.", .{});
        return;
    }

    stream_parm = std.mem.zeroes(v4l.struct_v4l2_streamparm);
    stream_parm.type = v4l.V4L2_BUF_TYPE_VIDEO_CAPTURE;

    if (-1 == xioctl(self.file_descriptor.?, v4l.VIDIOC_G_PARM, &stream_parm)) {
        std.log.debug("Failed to get parameters to initialize attempt to set frame rate.", .{});
        if (crash_on_diff) {
            return error.ErrorGettingCameraParams;
        }
        return;
    }

    stream_parm.parm.capture.timeperframe.numerator = 1;
    stream_parm.parm.capture.timeperframe.denominator = config.get_camera_frame_rate();

    if (-1 == xioctl(self.file_descriptor.?, v4l.VIDIOC_S_PARM, &stream_parm)) {
        std.log.debug("Failed to set frame rate.", .{});
        if (crash_on_diff) {
            return error.ErrorSettingFrameRate;
        }
        return;
    }
    
    stream_parm = std.mem.zeroes(v4l.struct_v4l2_streamparm);
    stream_parm.type = v4l.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (-1 == xioctl(self.file_descriptor.?, v4l.VIDIOC_G_PARM, &stream_parm)) {
        std.log.debug("Failed to get frame rate after setting it.", .{});
        if (crash_on_diff) {
            return error.ErrorGettingCameraParams;
        }
    }
    std.log.debug("Requested frame rate: {d} fps", .{config.get_camera_frame_rate()});
    const actual_frame_rate = @divFloor(stream_parm.parm.capture.timeperframe.denominator, stream_parm.parm.capture.timeperframe.numerator);
    std.log.debug("Actual frame rate: {d} fps", .{actual_frame_rate});
    if ((actual_frame_rate != config.get_camera_frame_rate()) and
        (crash_on_diff))
    {
        std.log.debug("Frame rate after setting does not match requested frame rate.", .{});
        return error.CameraFrameRateDoesNotMatchRequested;
    }
}

//##############################################################################
//##############################################################################
fn initialize_mmap(self: *Camera) !void {
    if (null == self.file_descriptor) {
        return error.BadStructInstance;
    }

    //Initializing request for 32 buffers from camera.
    var req: v4l.struct_v4l2_requestbuffers = std.mem.zeroes(v4l.struct_v4l2_requestbuffers);
    req.count = 32;
    req.type = v4l.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    req.memory = v4l.V4L2_MEMORY_MMAP;

    if (-1 == xioctl(self.file_descriptor.?, v4l.VIDIOC_REQBUFS, &req)) {
        std.log.debug("Failed to request buffer allocation via mmap.", .{});
        return error.RequestBuffersFailed;
    }

    if (2 > req.count) {
        std.log.debug("Insufficient buffer memory on device.", .{});
        return error.InsufficientBufferMemory;
    }

    self.frame_metadata = try self.allocator.alloc(MemoryMappedFrame, req.count);
    errdefer self.allocator.free(self.frame_metadata);

    for (0..req.count) |i| {
        var query_buf: v4l.struct_v4l2_buffer = std.mem.zeroes(v4l.struct_v4l2_buffer);

        query_buf.type = v4l.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        query_buf.memory = v4l.V4L2_MEMORY_MMAP;
        query_buf.index = @intCast(i);

        if (-1 == xioctl(self.file_descriptor.?, v4l.VIDIOC_QUERYBUF, &query_buf)) {
            std.log.debug("Failed to query buffer info.", .{});
            return error.QueryBufferFailed;
        }

        const length = query_buf.length;
        const start = std.c.mmap(
            null,
            length,
            .{ .READ = true, .WRITE = true},
            .{ .TYPE = .SHARED },
            self.file_descriptor.?,
            query_buf.m.offset,
        );

        if (std.c.MAP_FAILED == start) {
            std.log.debug("Failed to map buffer to user space.", .{});
            //for (0..i) |j| {
            //    _ = std.c.munmap(self.buffers[j].start, self.buffers[j].length);
            //}
            return error.MmapFailed;
        }

        self.frame_metadata[i] = .{
            .start_address = start,
            .max_length = length,
        };
    }
}

//******************************************************************************
// Function:    start_capturing
//
// Description: This function is a wrapper for sending the ioctl sequnce for the
//              configured camera to begin the process of filling the memory
//              mapped buffers.
//******************************************************************************
fn start_capturing(self: Camera) !void {
    if ((null == self.file_descriptor) or
        (2 > self.frame_metadata.len)) {
        return error.BadStructInstance;
    }

    // Go through and queue all the buffers for v4l to store data in. 
    for (0..self.frame_metadata.len) |index| {
        var buf: v4l.struct_v4l2_buffer = std.mem.zeroes(v4l.struct_v4l2_buffer);

        buf.type = v4l.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = v4l.V4L2_MEMORY_MMAP;
        buf.index = @intCast(index);

        if (-1 == xioctl(self.file_descriptor.?, v4l.VIDIOC_QBUF, &buf)) {
            std.log.debug("Failed to queue buffer {d}.", .{index});
            return error.QueueBufferFailed;
        }
    }

    // Trigger the stream to allow the camera to start storing to those queued
    // buffers.
    var vtype: v4l.enum_v4l2_buf_type = v4l.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (-1 == xioctl(self.file_descriptor.?, v4l.VIDIOC_STREAMON, &vtype)) {
        std.log.debug("Failed to start video streaming.", .{});
        return error.StartStreamingFailed;
    }
}

/// Dequeue one filled buffer and record its size and timestamp.
///
/// Returns the buffer index. The buffer stays checked out until
/// `infinite_capture` requeues it. `error.BadStructInstance` means `init`
/// did not leave a file descriptor.
pub fn capture_single_frame(self: Camera) !?u8 {
    // Rudamentary check that object was initialized. 
    const camera_device = self.file_descriptor orelse return error.BadStructInstance;

    var buf: v4l.struct_v4l2_buffer = std.mem.zeroes(v4l.struct_v4l2_buffer);
    buf.type = v4l.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    buf.memory = v4l.V4L2_MEMORY_MMAP;

    if (-1 == xioctl(camera_device, v4l.VIDIOC_DQBUF, &buf)) {
        if (v4l.EAGAIN == std.c._errno().*) {
            //return null;
            @panic("Camera should be blocking - according to v4l documentation this line should be unreachable (due to error EAGAIN when reading errno.");
        }
        std.log.debug("Failed to dequeue buffer.", .{});
        return error.DequeueBufferFailed;
    }
    std.log.debug("Captured frame in buffer index {d}.", .{buf.index});

    std.log.debug("Updating camera data for recent capture:", .{});
    std.log.debug("\tUpdating buffer {d}'s bytes used (val = {d})...", .{ buf.index, buf.bytesused });
    self.frame_metadata[buf.index].bytes_used = buf.bytesused;
    //std.log.debug("\tUpdating buffer {d}'s timestamp...", .{buf.index});
    self.frame_metadata[buf.index].time_stamp = buf.timestamp;
    std.log.debug("Just aquired timestamp: {d}.{d}", .{buf.timestamp.tv_sec, buf.timestamp.tv_usec});

    std.log.debug("Sending Frame data for encoding...", .{});
    return @intCast(buf.index);
}

//##############################################################################
// Function:    release_buffer
// 
// Description: When a frame is captured it's stored in a buffer that is 
//              reserved with the relevant frame data until the application
//              indicates that it's free to overwrite. This function is the
//              ioctl wrapper for that indication.
//##############################################################################
fn release_buffer(self: Camera, buffer_index: u32) !void {
    var buf: v4l.struct_v4l2_buffer = std.mem.zeroes(v4l.struct_v4l2_buffer);
    buf.type = v4l.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    buf.memory = v4l.V4L2_MEMORY_MMAP;
    buf.index = buffer_index;

    if (-1 == xioctl(self.file_descriptor.?, v4l.VIDIOC_QBUF, &buf)) {
        std.log.debug("Failed to re-queue buffer.", .{});
        return error.RequeueBufferFailed;
    }
}

//==============================================================================
// helper function suggested by ai due to ioctl being interruptible
//fn xioctl(fd: c_int, request: c_ulong, arg: *v4l.v4l2_capability) c_int {
//==============================================================================
fn xioctl(fd: c_int, request: c_ulong, arg: *anyopaque) c_int {
    var r: c_int = -1;
    r = v4l.ioctl(fd, request, arg);
    while (-1 == r and std.c._errno().* == v4l.EINTR) {
        r = v4l.ioctl(fd, request, arg);
    }
    return r;
}
