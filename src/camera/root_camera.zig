pub const Camera = @This();

const std = @import("std");
const debug = @import("debug");
const sync = @import("sync_data");
const c = @import("c_imports").c;
const config = @import("config");

const SetupState = enum {
    Naked,
    DeviceNameKnown,
    DeviceNameConfirmed,
    DeviceOpened,
    DeviceVideoSupportConfirmed,
    DeviceCropCapSet,
    DeviceVideoConditionsSet,
    DeviceMemorySetup,
    DeviceBuffersQueued,
};

file_descriptor: ?c_int,
device_name: ?[*:0]const u8,
allocator: std.mem.Allocator,
buffers: []sync.CameraBuffer = &.{},
n_buffers: u8 = undefined,
private_head: usize = 0,


//******************************************************************************
// Function:    infinite_capture()
//
// Description: This is the ultimate caller for taking a camera object and 
//              infinitely capturing video. This is ultimately the function
//              that would be your "camera thread". There does need to be an
//              initialization of the camera first.
//
//              Note: this function (really a thread) does require a consumer
//              of the frames. This function will do nothing to dequeue frames.
//              There needs to be a consumer - in the current application this
//              would be the encoder thread. 
//******************************************************************************
pub fn infinite_capture(self: *Camera, io : std.Io, sync_data: *sync.SynchronousData, shutdown_flag : *std.atomic.Value(bool)) void {
    // Point the buffers (slice) for sync data to the camera's
    // allocated/memory-mapped v4l buffers. 
    sync_data.camera_data.buffers = self.buffers;

    // Queue all buffers and start stream.
    self.start_capturing() catch |err| {
        debug.print("There was an error starting the capturing of frames with the camera...\n", .{});
        debug.print("\tError code: {any}\n", .{err});
        {
            sync_data.mutex.lock(io) catch |inner_err| {
                debug.print("Failed to lock mutex due to error: {any}\n", .{inner_err});
                return;
            };
            defer sync_data.mutex.unlock(io);
            sync_data.sync_error = sync.ThreadingErrors.CameraCouldNotStart;
            shutdown_flag.store(true, .release);
        }
        return;
    };

    // infintely capture frames. 
    while (true) {
        // Check for errors in any of the related threads to see if we should
        // abort capturing frames (and end the application)
        if (null != sync_data.sync_error) {
            debug.print("External error - closing camera thread...\n", .{});
            debug.print("\tExternal error was: {any}\n", .{sync_data.sync_error.?});
            return;
        }

        // Look to see if there are any buffers that can be released back to
        // the camera?
        if (0 != sync_data.camera_data.free_flags.count()) {
            sync_data.mutex.lock(io) catch |inner_err| {
                debug.print("Failed to lock mutex due to error: {any}\n", .{inner_err});
                return;
            };
            defer sync_data.mutex.unlock(io);
            while (sync_data.camera_data.free_flags.findFirstSet()) |num| {
                sync_data.camera_data.free_flags.unset(num);
                self.release_buffer(@intCast(num)) catch |err| {
                    debug.print("Error Freeing buffer...\n", .{});
                    debug.print("\tError code: {any}\n", .{err});
                    break;
                };
            }
        }

        // Attempt to capture / check if next frame is available. 
        const nullable_frame_captured = self.capture_single_frame() catch |err| {
            debug.print("Error capturing a frame from the camera...\n", .{});
            debug.print("\tError received was: {any}\n", .{err});
            {
                sync_data.mutex.lock(io) catch |inner_err| {
                    debug.print("Failed to lock mutex due to error: {any}\n", .{inner_err});
                    return;
                };
                defer sync_data.mutex.unlock(io);
                sync_data.sync_error = sync.ThreadingErrors.CameraCouldNotCaptureFrame;
                shutdown_flag.store(true, .release);
            }
            return;
        };

        // if we're here there was no error in calling the capture logic, but
        // we need to check that a new frame was provided (output was not null)
        const frame_captured = nullable_frame_captured orelse continue;

        // add buffer to list to encode
        sync_data.camera_data.push(io, frame_captured) catch {
            sync_data.mutex.lock(io) catch |inner_err| {
                debug.print("Failed to lock mutex due to error: {any}\n", .{inner_err});
                return;
            };
            defer sync_data.mutex.unlock(io);
            sync_data.sync_error = sync.ThreadingErrors.CameraRunOutOfBuffers;
            shutdown_flag.store(true, .release);
            debug.print("Camera ran out of buffers... aborting\n", .{});
            return;
        };
    }
}


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
        var statx: std.os.linux.Statx = undefined;

        const statx_check = std.c.statx(
            std.c.AT.FDCWD,
            name,
            0,
            .BASIC_STATS,
            &statx,
        );

        if (-1 == statx_check) {
            debug.print("Failed to get device status.\n", .{});
            return false;
            //return error.FStatFailed;
        }

        debug.print("Device status obtained.\n", .{});

        if (!std.c.S.ISCHR(statx.mode)) {
            debug.print("{s} is not a character device.\n", .{name});
            return false;
            //return error.NotCharacterDevice;
        }

        debug.print("{s} is a character device.\n", .{name});
        return true;
    } else {
        return false;
    }
}

fn device_supports_video(self: Camera) bool {
    if (self.file_descriptor) |fd| {
        var cap: c.struct_v4l2_capability = std.mem.zeroes(c.struct_v4l2_capability);

        if (-1 == xioctl(fd, c.VIDIOC_QUERYCAP, &cap)) {
            debug.print("Failed to query device capabilities.\n", .{});
            return false;
        }

        if (0 == (cap.capabilities & c.V4L2_CAP_VIDEO_CAPTURE)) {
            debug.print("Device does not support video capture.\n", .{});
            return false;
        }

        if (0 == (cap.capabilities & c.V4L2_CAP_STREAMING)) {
            debug.print("Device does not support streaming I/O (our default method for handling cameras... at least for now.\n", .{});
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
                debug.print("Cropping not supported on this device.\n", .{});
            } else {
                debug.print("Failed to set crop rectangle.\n", .{});
            }
        } else {
            debug.print("Crop rectangle set successfully.\n", .{});
        }
    } else {
        debug.print("Failed to get crop capabilities.\n", .{});
    }

    fmt.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    fmt.fmt.pix.width = config.get_camera_width();
    fmt.fmt.pix.height = config.get_camera_height();
    fmt.fmt.pix.pixelformat = c.V4L2_PIX_FMT_YUYV;

    if (-1 == xioctl(self.file_descriptor.?, c.VIDIOC_S_FMT, &fmt)) {
        debug.print("Failed to set pixel format.\n", .{});
        return error.SetFormatFailed;
    }

    if (config.get_crash_on_vid_diff()) {
        debug.print("Set to validate camera settings... checking now\n", .{});
        var validated_fmt: c.v4l2_format = std.mem.zeroes(c.v4l2_format);
        validated_fmt.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        if (-1 == xioctl(self.file_descriptor.?, c.VIDIOC_G_FMT, &validated_fmt)) {
            debug.print("Could not get video settings\n", .{});
            return error.CouldNotValidateCameraSettings;
        }
        if ((config.get_camera_width() != validated_fmt.fmt.pix.width) or
            (config.get_camera_height() != validated_fmt.fmt.pix.height)) {
            debug.print("ERROR: Camera not configured correctly\n", .{});
            debug.print("\twidth x height = {d}x{d}\n", .{validated_fmt.fmt.pix.width, validated_fmt.fmt.pix.width});
            return error.CameraSettingsDontMatchConfig;
        } else {
            debug.print("CAMERA SET CORRECTLY\n", .{});
        }
    } else {
        debug.print("Assuming pixel format set successfully.\n", .{});
        debug.print("Configured format:\n", .{});
        debug.print("\tWidth: {d}\n", .{fmt.fmt.pix.width});
        debug.print("\tHeight: {d}\n", .{fmt.fmt.pix.height});
        debug.print("\tPixel Format: {x}\n", .{fmt.fmt.pix.pixelformat});
    }

    try self.attempt_to_set_frame_rate();

    try self.initialize_mmap();
}

fn attempt_to_set_frame_rate(self: *Camera) !void {
    const crash_on_diff = config.get_crash_on_vid_diff();

    var stream_parm : c.struct_v4l2_streamparm = std.mem.zeroes(c.struct_v4l2_streamparm);
    stream_parm.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (-1 == xioctl(self.file_descriptor.?, c.VIDIOC_G_PARM, &stream_parm)) {
        debug.print("Failed to get current frame rate settings.\n", .{});
        return error.ErrorGettingCameraParams;
    }

    const dev_supports_frame_rate : bool = (stream_parm.parm.capture.capability & c.V4L2_CAP_TIMEPERFRAME) != 0;

    if ((!dev_supports_frame_rate) and 
        (crash_on_diff)) {
        debug.print("Device does not support frame rate adjustment and user as asked to crash on difference.\n", .{});
        return error.DeviceDoesNotSupportFrameRateSetting;
    }

    if (!dev_supports_frame_rate) {
        debug.print("Device does not support frame rate adjustment - skipping frame rate set.\n", .{});
        debug.print("Warning: Frame rate may not be as expected and encoder WILL use your requested frame rate regardless of actual camera frame rate.\n", .{});
        return;
    }

    stream_parm = std.mem.zeroes(c.struct_v4l2_streamparm);
    stream_parm.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;

    if (-1 == xioctl(self.file_descriptor.?, c.VIDIOC_G_PARM, &stream_parm)) {
        debug.print("Failed to get parameters to initialize attempt to set frame rate.\n", .{});
        if (crash_on_diff) {
            return error.ErrorGettingCameraParams;
        }
        return;
    }

    stream_parm.parm.capture.timeperframe.numerator = 1;
    stream_parm.parm.capture.timeperframe.denominator = config.get_camera_frame_rate();

    if (-1 == xioctl(self.file_descriptor.?, c.VIDIOC_S_PARM, &stream_parm)) {
        debug.print("Failed to set frame rate.\n", .{});
        if (crash_on_diff) {
            return error.ErrorSettingFrameRate;
        }
        return;
    }
    
    stream_parm = std.mem.zeroes(c.struct_v4l2_streamparm);
    stream_parm.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (-1 == xioctl(self.file_descriptor.?, c.VIDIOC_G_PARM, &stream_parm)) {
        debug.print("Failed to get frame rate after setting it.\n", .{});
        if (crash_on_diff) {
            return error.ErrorGettingCameraParams;
        }
    }
    debug.print("Requested frame rate: {d} fps\n", .{config.get_camera_frame_rate()});
    const actual_frame_rate = @divFloor(stream_parm.parm.capture.timeperframe.denominator, stream_parm.parm.capture.timeperframe.numerator);
    debug.print("Actual frame rate: {d} fps\n", .{actual_frame_rate});
    if ((actual_frame_rate != config.get_camera_frame_rate()) and
        (crash_on_diff))
    {
        debug.print("Frame rate after setting does not match requested frame rate.\n", .{});
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
    var req: c.struct_v4l2_requestbuffers = std.mem.zeroes(c.struct_v4l2_requestbuffers);
    req.count = 32;
    req.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    req.memory = c.V4L2_MEMORY_MMAP;

    if (-1 == xioctl(self.file_descriptor.?, c.VIDIOC_REQBUFS, &req)) {
        debug.print("Failed to request buffer allocation via mmap.\n", .{});
        return error.RequestBuffersFailed;
    }

    if (2 > req.count) {
        debug.print("Insufficient buffer memory on device.\n", .{});
        return error.InsufficientBufferMemory;
    }

    self.buffers = try self.allocator.alloc(sync.CameraBuffer, req.count);
    errdefer self.allocator.free(self.buffers);

    for (0..req.count) |i| {
        var query_buf: c.struct_v4l2_buffer = std.mem.zeroes(c.struct_v4l2_buffer);

        query_buf.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        query_buf.memory = c.V4L2_MEMORY_MMAP;
        query_buf.index = @intCast(i);

        if (-1 == xioctl(self.file_descriptor.?, c.VIDIOC_QUERYBUF, &query_buf)) {
            debug.print("Failed to query buffer info.\n", .{});
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
            debug.print("Failed to map buffer to user space.\n", .{});
            //for (0..i) |j| {
            //    _ = std.c.munmap(self.buffers[j].start, self.buffers[j].length);
            //}
            return error.MmapFailed;
        }

        self.buffers[i] = .{
            .start = start,
            .length = length,
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
        (2 > self.buffers.len)) {
        return error.BadStructInstance;
    }

    // Go through and queue all the buffers for v4l to store data in. 
    for (0..self.buffers.len) |index| {
        var buf: c.struct_v4l2_buffer = std.mem.zeroes(c.struct_v4l2_buffer);

        buf.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = c.V4L2_MEMORY_MMAP;
        buf.index = @intCast(index);

        if (-1 == xioctl(self.file_descriptor.?, c.VIDIOC_QBUF, &buf)) {
            debug.print("Failed to queue buffer {d}.\n", .{index});
            return error.QueueBufferFailed;
        }
    }

    // Trigger the stream to allow the camera to start storing to those queued
    // buffers.
    var vtype: c.enum_v4l2_buf_type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (-1 == xioctl(self.file_descriptor.?, c.VIDIOC_STREAMON, &vtype)) {
        debug.print("Failed to start video streaming.\n", .{});
        return error.StartStreamingFailed;
    }
}

pub fn capture_single_frame(self: Camera) !?u8 {
    // Rudamentary check that object was initialized. 
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
        debug.print("Failed to dequeue buffer.\n", .{});
        return error.DequeueBufferFailed;
    }
    debug.print("Captured frame in buffer index {d}.\n", .{buf.index});

    debug.print("Updating camera data for recent capture\n:", .{});
    debug.print("\tUpdating buffer {d}'s bytes used (val = {d})...\n", .{ buf.index, buf.bytesused });
    self.buffers[buf.index].bytes_used = buf.bytesused;
    //debug.print("\tUpdating buffer {d}'s timestamp...\n", .{buf.index});
    self.buffers[buf.index].time_stamp = buf.timestamp;
    debug.print("Just aquired timestamp: {d}.{d}\n", .{buf.timestamp.tv_sec, buf.timestamp.tv_usec});
    debug.print("\tUpdating buffer {d}'s sequence...\n", .{buf.index});
    self.buffers[buf.index].sequence = buf.sequence;

    debug.print("Sending Frame data for encoding...\n", .{});
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
    var buf: c.struct_v4l2_buffer = std.mem.zeroes(c.struct_v4l2_buffer);
    buf.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    buf.memory = c.V4L2_MEMORY_MMAP;
    buf.index = buffer_index;

    if (-1 == xioctl(self.file_descriptor.?, c.VIDIOC_QBUF, &buf)) {
        debug.print("Failed to re-queue buffer.\n", .{});
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
