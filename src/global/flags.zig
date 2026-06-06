const std = @import("std");

var ProgramRunning : std.atomic.Value(bool) = .init(true);

pub fn is_program_running() bool {
    return ProgramRunning.load(.seq_cst);
}

pub fn set_shutdown_flag() void {
    ProgramRunning.store(false, .seq_cst);
}
