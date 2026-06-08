const std = @import("std");

pub const SystemStates = enum {
    NormalOperation,
    UploadError_MaintainCapture,
    CaptureError_MaintainWireless,
    EverythingBroken_WaitForSystemRecovery,
    SystemShutdown,
};

var ProgramRunning : std.atomic.Value(SystemStates) = .init(.NormalOperation);

pub fn get_current_state() SystemStates {
    return ProgramRunning.load(.seq_cst);
}

pub fn is_operating_normally() bool {
    return (.NormalOperation == ProgramRunning.load(.seq_cst));
}

pub fn is_system_shutdown() bool {
    return (.SystemShutdown == ProgramRunning.load(.seq_cst));
}

pub fn set_upload_error() void {
    const current_state = ProgramRunning.load(.seq_cst);
    switch (current_state) {
        .NormalOperation => ProgramRunning.store(.UploadErrorHaltCapture, .seq_cst),
        .UploadError_MaintainCapture => return, //This function is to set this state... disregard
        .CaptureError_MaintainWireless => ProgramRunning.store(.EverythingBroken_WaitForSystemRecovery, .seq_cst),
        .EverythingBroken_WaitForSystemRecovery => return, //We're already reporting upload errors... disregard
        .SystemShutdown => @panic("System should already be in a shutdown state. If you're trying to error handle here - the program is behaving unexpectedly"),
        else => @panic("This is an unhandled state and we don't want unhandled states"),
    }
}


pub fn set_capture_error() void {
    const current_state = ProgramRunning.load(.seq_cst);
    switch (current_state) {
        .NormalOperation => ProgramRunning.store(.CaptureError_MaintainWireless, .seq_cst),
        .UploadError_MaintainCapture => ProgramRunning.store(.EverythingBroken_WaitForSystemRecovery, .seq_cst),
        .CaptureError_MaintainWireless => return, //This function is to set this state... disregard
        .EverythingBroken_WaitForSystemRecovery => return, //We're already reporting capture errors... disregard
        .SystemShutdown => @panic("System should already be in a shutdown state. If you're trying to error handle here - the program is behaving unexpectedly"),
        else => @panic("This is an unhandled state and we don't want unhandled states"),
    }
}

pub fn set_shutdown_flag() void {
    ProgramRunning.store(.SystemShutdown, .seq_cst);
}
