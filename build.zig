const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const translate_c_ffmpeg = b.addTranslateC(.{
        .root_source_file = b.path("src/imports/c_imports_ffmpeg.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c_ffmpeg.linkSystemLibrary("libavcodec", .{});
    const mod_c_ffmpeg = translate_c_ffmpeg.createModule();

    const translate_c_v4l = b.addTranslateC(.{
        .root_source_file = b.path("src/imports/c_imports_v4l.h"),
        .target = target,
        .optimize = optimize,
    });
    const mod_c_v4l = translate_c_v4l.createModule();

    const mod_config = b.createModule(.{
        .root_source_file = b.path("src/config/root_config.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod_sys = b.createModule(.{
        .root_source_file = b.path("src/sys/root_sys.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "config", .module = mod_config },
        },
    });

    const mod_sync_data = b.createModule(.{
        .root_source_file = b.path("src/global/sync_data.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod_net = b.createModule(.{
        .root_source_file = b.path("src/net/root_net.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sync_data", .module = mod_sync_data },
            .{ .name = "config", .module = mod_config },
            .{ .name = "sys", .module = mod_sys },
        },
    });

    const mod_amh = b.createModule(.{
        .root_source_file = b.path("src/amh/root_artifacts_managment_and_handling.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "config", .module = mod_config },
            .{ .name = "net", .module = mod_net },
        },
    });

    const mod_time = b.createModule(.{
        .root_source_file = b.path("src/time_date/root_time.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "config", .module = mod_config },
        },
    });

    const mod_camera = b.createModule(.{
        .root_source_file = b.path("src/camera/root_camera.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sync_data", .module = mod_sync_data },
            .{ .name = "v4l", .module = mod_c_v4l },
            .{ .name = "config", .module = mod_config },
        },
    });

    const mod_encoding = b.createModule(.{
        .root_source_file = b.path("src/encoding/root_encoding.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sync_data", .module = mod_sync_data },
            .{ .name = "c_imports", .module = mod_c_ffmpeg },
            .{ .name = "config", .module = mod_config },
            .{ .name = "time", .module = mod_time },
            .{ .name = "sys", .module = mod_sys },
            .{ .name = "camera", .module = mod_camera },
        },
    });
    mod_encoding.linkSystemLibrary("libavformat", .{});
    mod_encoding.linkSystemLibrary("libavcodec", .{});
    mod_encoding.linkSystemLibrary("libavutil", .{});
    mod_encoding.linkSystemLibrary("libswscale", .{});

    const mod_root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "config", .module = mod_config },
            .{ .name = "sys", .module = mod_sys },
            .{ .name = "camera", .module = mod_camera },
            .{ .name = "amh", .module = mod_amh },
            .{ .name = "encoding", .module = mod_encoding },
        },
    });

    const exe = b.addExecutable(.{
        .name = "zig_home_security_client",
        .root_module = mod_root,
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();

    const installDir_docs = b.addInstallDirectory(.{
        .source_dir = exe.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const step_docs = b.step("docs", "Generates HTML documentation for the project.");
    step_docs.dependOn(&installDir_docs.step);
}
