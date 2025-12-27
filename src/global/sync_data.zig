const std = @import("std");
const c = @import("c_imports").c;

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
};

pub const SynchronousData = struct {
    const Self = @This();
    const BUFFER_SIZE = 32;
    mutex: std.Thread.Mutex = .{},
    buffers: []CameraBuffer = undefined,
    buffers_ready_to_encode: [BUFFER_SIZE]u8 = std.mem.zeroes([BUFFER_SIZE]u8),
    //free_flags: std.bit_set = std.bit_set.IntegerBitSet(BUFFER_SIZE).initEmpty(),
    free_flags: std.bit_set.IntegerBitSet(BUFFER_SIZE) = std.bit_set.IntegerBitSet(BUFFER_SIZE).initEmpty(),
    sync_error: ?ThreadingErrors = null,
    head: usize = 0,
    tail: usize = 0,

    pub fn pop(self: *Self) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.head == self.tail) {
            return error.Empty;
        }
        const value = self.buffers_ready_to_encode[self.tail];
        self.tail = ((self.tail + 1) % BUFFER_SIZE);
        self.free_flags.set(value);
    }

    pub fn push(self: *Self, buf_num: u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const next_head = ((self.head + 1) % BUFFER_SIZE);
        if (next_head == self.head) {
            return error.Full;
        }
        self.head = next_head;
        self.buffers_ready_to_encode[self.head] = buf_num;
    }

    pub fn get_first(self: *Self) ?u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.head == self.tail) {
            return null;
        }

        return @intCast(self.tail);
    }
};
