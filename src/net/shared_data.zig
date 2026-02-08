const Shared_Data = @This();
const std = @import("std");

mutex : std.Io.Mutex,
file_list : std.ArrayList([]u8),
allocator : std.mem.Allocator,
io : std.Io,


pub fn init(
    allocator : std.mem.Allocator,
    io : std.Io,
) Shared_Data {
    return .{
        .mutex = .init,
        .file_list = .empty,
        .allocator = allocator,
        .io = io,
    };
}

pub fn pop_file(self : *Shared_Data) !?[]u8 {
    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);
    return self.file_list.pop();
}

pub fn push_file(self : *Shared_Data, file : []const u8) !void {
    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);
    try self.file_list.append(self.allocator, file);
}
