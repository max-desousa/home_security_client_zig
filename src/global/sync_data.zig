//! Types shared by the camera thread and the encoder thread.
//!
//! `ThreadingErrors` is the cross-thread error set. `CameraData` is a mutexed
//! ring of V4L2 buffer indexes. `SynchronousData` adds a `sync_error` slot so
//! one thread can record that the other has failed. The four-core layout does
//! not use this module; it passes `std.Io.Queue` values instead. The two-core
//! layout constructs a `SynchronousData` for its upload thread.

const std = @import("std");

/// Failures one worker can report to the other.
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
    CouldNotRenameFile,
};

/// Mutexed ring of buffer indexes waiting to be encoded.
///
/// Capacity is 32. `push` and `pop` lock `mutex`. `head == tail` means empty.
pub const CameraData = struct {
    const Self = @This();
    const BUFFER_SIZE = 32;
    mutex: std.Io.Mutex = .init,
    // Slice of memory mapped addresses and meta data that the camera is saving
    // the data to. (This is allocated in the camera threading. (Not fixed size
    // as this should have kernel influence and we want the same number of
    // buffers as we'll get with our ioctl request)
    // List of buffer indices for frame buffers ready to be encoded.
    // stored in the order that the encoder needs to send them to the video. 
    buffers_ready_to_encode: [BUFFER_SIZE]u8 = std.mem.zeroes([BUFFER_SIZE]u8),
    // Flags for buffers that no longer need to be reserved for the encoder. 
    free_flags: std.bit_set.IntegerBitSet(BUFFER_SIZE) = .empty,
    // Values to track `buffers_ready_to_encode`
    head: usize = 0,
    tail: usize = 0,

    /// Remove the oldest buffer index. Returns `error.Empty` when the ring is empty.
    pub fn pop(self: *Self, io : std.Io) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        if (self.head == self.tail) {
            return error.Empty; }
        const value = self.buffers_ready_to_encode[self.tail];
        self.tail = ((self.tail + 1) % BUFFER_SIZE);
        self.free_flags.set(value);
    }

    /// Append `buf_num`. Returns `error.Full` when the ring has no free slot.
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

    /// Oldest index, or `null` when the ring is empty. Does not remove it.
    pub fn get_first(self: *Self, io : std.Io) ?u8 {
        self.mutex.lock(io) catch |inner_err| {
            std.log.debug("Error locking mutex: {any}", .{inner_err});
        };
        defer self.mutex.unlock(io);

        if (self.head == self.tail) {
            return null;
        }

        return @intCast(self.tail);
    }
};


/// `CameraData` plus a shared error. `sync_error` stays `null` until a worker sets it.
pub const SynchronousData = struct {
    // shared error state between encoding and camera threads in order for them
    // to inform one another that they've failed. (Ex: We don't want to get
    // stuck in an infinite encoding loop for a program where the camera has
    // crashed )
    sync_error : ?anyerror = null,
    mutex: std.Io.Mutex = .init,
    camera_data : CameraData = .{},
};

