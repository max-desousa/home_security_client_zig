const std = @import("std");
const c = @import("c_imports").c;
const debug = @import("debug");

//Buffer used by cameras.
pub const CameraBuffer = struct {
    start: *anyopaque,
    length: u32,
    bytes_used: u32 = 0,
    time_stamp: c.struct_timeval = std.mem.zeroes(c.struct_timeval),
    sequence: u32 = 0,
};

pub const ThreadingErrors = error{
    CameraCouldNotStart,
    CameraCouldNotCaptureFrame,
    CameraUnrecoverable,
    EncoderUnrecoverable,
    EncoderCouldNotBeFound,
    EncoderCouldNotSetContext,
    EncoderCouldNotSetOutputContext,
    EncoderCouldNotOpenCodec,
    EncoderTimedOut,
    EncoderCouldNotCreateFmtCtx,
    PrototypeEncoderNaturallyDone,
    IOError,
    CameraRunOutOfBuffers,
    CameraCouldNotFreeBuffer,
    SigIntRequested,
    EncoderCouldNotGenerateFilename,
    EncoderCouldNotGetCurrentTime,
    ErrorGettingCameraParams,
    DeviceDoesNotSupportFrameRateSetting,
    CameraFrameRateDoesNotMatchRequested,
};

pub const CameraData = struct {
    const Self = @This();
    const BUFFER_SIZE = 32;
    mutex: std.Io.Mutex = .init,
    // Slice of memory mapped addresses and meta data that the camera is saving
    // the data to. (This is allocated in the camera threading. (Not fixed size
    // as this should have kernel influence and we want the same number of
    // buffers as we'll get with our ioctl request)
    buffers: []CameraBuffer = undefined,
    // List of buffer indices for frame buffers ready to be encoded.
    // stored in the order that the encoder needs to send them to the video. 
    buffers_ready_to_encode: [BUFFER_SIZE]u8 = std.mem.zeroes([BUFFER_SIZE]u8),
    // Flags for buffers that no longer need to be reserved for the encoder. 
    free_flags: std.bit_set.IntegerBitSet(BUFFER_SIZE) = std.bit_set.IntegerBitSet(BUFFER_SIZE).initEmpty(),
    // Values to track `buffers_ready_to_encode`
    head: usize = 0,
    tail: usize = 0,

    pub fn pop(self: *Self, io : std.Io) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        if (self.head == self.tail) {
            return error.Empty; }
        const value = self.buffers_ready_to_encode[self.tail];
        self.tail = ((self.tail + 1) % BUFFER_SIZE);
        self.free_flags.set(value);
    }

    pub fn push(self: *Self, io : std.Io, buf_num: u8) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        const next_head = ((self.head + 1) % BUFFER_SIZE);
        if (next_head == self.head) {
            return error.Full;
        }
        self.head = next_head;
        self.buffers_ready_to_encode[self.head] = buf_num;
    }

    pub fn get_first(self: *Self, io : std.Io) ?u8 {
        self.mutex.lock(io) catch |inner_err| {
            debug.print("Error locking mutex: {any}\n", .{inner_err});
        };
        defer self.mutex.unlock(io);

        if (self.head == self.tail) {
            return null;
        }

        return @intCast(self.tail);
    }
};


pub const SynchronousData = struct {
    // shared error state between encoding and camera threads in order for them
    // to inform one another that they've failed. (Ex: We don't want to get
    // stuck in an infinite encoding loop for a program where the camera has
    // crashed )
    sync_error : ?anyerror = null,
    mutex: std.Io.Mutex = .init,
    camera_data : CameraData = .{},
};

