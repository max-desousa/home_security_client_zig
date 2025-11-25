const std = @import("std");

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
    IOError,
    CameraRunOutOfBuffers,
    CameraCouldNotFreeBuffer,
};

pub const SynchronousData = struct {
    const Self = @This();
    const BUFFER_SIZE = 32;
    mutex: std.Thread.Mutex = .{},
    buffers: [BUFFER_SIZE]u8 = std.mem.zeroes([BUFFER_SIZE]u8),
    sync_error: ?ThreadingErrors = null,
    head: usize = 0,
    tail: usize = 0,

    pub fn pop(self: *Self) !u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.head == self.tail) {
            return error.Empty;
        }
        const value = self.buffers[self.tail];
        self.tail = ((self.tail + 1) % BUFFER_SIZE);
        return value;
    }

    pub fn push(self: *Self, buf_num: u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const next_head = ((self.head + 1) % BUFFER_SIZE);
        if (next_head == self.head) {
            return error.Full;
        }
        self.head = next_head;
        self.buffers[self.head] = buf_num;
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
