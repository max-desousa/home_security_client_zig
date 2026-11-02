//! Security camera client.
//!
//! This file is the front page of `zig build docs`. The process entry is
//! `main`. On a machine with more than three cores the running layout is
//! `four_core_layout`.
//!
//! Pipeline:
//! - `config` loads `config.zap` from the working directory.
//! - `sys` creates `Videos/ToArchive/<camera>` and `Videos/Archived/<camera>`.
//! - `camera` memory-maps the V4L2 device and captures frames.
//! - `encoding` writes those frames to H.264 `.ts` clips.
//! - `amh` uploads finished clips through `net`.
//! - `time` builds the timestamp embedded in each filename.
//!
//! `-Dnumber_of_cores` selects the layout. `1` and `3` are stubs. `2` does
//! not type-check. Any other count uses the four-core layout.

// A real token has to sit between the module docs and the first `///`.
// The docs renderer otherwise treats that `///` as more module text.
const std = @import("std");

/// Process entry. Loads config, creates the video directories, opens the camera.
pub const main = @import("main.zig");

/// `config.zap`: device, clip length, upload target, cleanup policy.
pub const config = @import("config");

/// `Videos/` tree and the file-cleanup thread.
pub const sys = @import("sys");

/// V4L2 capture device and the camera thread.
pub const camera = @import("camera");

/// Build-time choice of thread layout (`-Dnumber_of_cores`).
pub const core_layouts = @import("coreLayouts");

/// H.264 encode thread (libav).
pub const encoding = @import("encoding");

/// Upload thread used by the four-core layout.
pub const amh = @import("amh");

/// HTTP upload of clips in `Videos/ToArchive`.
pub const net = @import("net");

/// Filename time windows.
pub const time = @import("time");

/// Ring buffer shared by the two-core layout. The four-core layout uses queues instead.
pub const sync_data = @import("sync_data");
