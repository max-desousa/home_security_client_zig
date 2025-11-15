const std = @import("std");
const atomic = std.atomic;

pub const BufferQueue = struct {
    const Self = @This();
    const BUFFER_SIZE = 32;

    buffers: [BUFFER_SIZE]?u8,
    head: atomic.Value(u8),
    tail: atomic.Value(u8),

    pub fn init() Self {
        return .{
            .buffers = .{null} ** BUFFER_SIZE,
            .head = atomic.Value(u8).init(0),
            .tail = atomic.Value(u8).init(0),
        };
    }

    pub fn enqueue(self: *Self, buffer_number: u8) bool {
        const head = self.head.load(.monotonic);
        const tail = self.head.load(.monotonic);
        const next_head = (head + 1) % BUFFER_SIZE;

        if (next_head == tail) return false;

        self.buffers[head] = buffer_number;
        self.head.store(next_head, .release);
        return true;
    }

    pub fn dequeue(self: *Self) ?u8 {
        const head = self.head.load(.acquire);
        const tail = self.tail.load(.monotonic);

        if (tail == head) return null;

        const buf_id = self.buffers[tail];
        self.buffers[tail] = null;
        self.tail.store((tail + 1) % BUFFER_SIZE, .release);
        return buf_id;
    }
};

pub var EncodingBuffer: BufferQueue = BufferQueue.init();
