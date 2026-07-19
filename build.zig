const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/imports/c_imports.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.linkSystemLibrary("libavcodec", .{});
    const mod_c_imports = translate_c.createModule();

    const toml = b.dependency("toml", .{});

    const mod_config = b.createModule(.{
        .root_source_file = b.path("src/config/root_config.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "toml", .module = toml.module("toml") },
        },
    });

    const mod_sys = b.createModule(.{
        .root_source_file = b.path("src/sys/root_sys.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "config", .module = mod_config },
        },
    });

    const mod_debug = b.createModule(.{
        .root_source_file = b.path("src/debug/root_debug.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod_sync_data = b.createModule(.{
        .root_source_file = b.path("src/global/sync_data.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "c_imports", .module = mod_c_imports },
            .{ .name = "debug", .module = mod_debug },
        },
    });

    const mod_net = b.createModule(.{
        .root_source_file = b.path("src/net/root_net.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sync_data", .module = mod_sync_data },
            .{ .name = "debug", .module = mod_debug },
            .{ .name = "config", .module = mod_config },
            .{ .name = "sys", .module = mod_sys },
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
            .{ .name = "debug", .module = mod_debug },
            .{ .name = "c_imports", .module = mod_c_imports },
            .{ .name = "config", .module = mod_config },
        },
    });

    const mod_encoding = b.createModule(.{
        .root_source_file = b.path("src/encoding/root_encoding.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "debug", .module = mod_debug },
            .{ .name = "sync_data", .module = mod_sync_data },
            .{ .name = "c_imports", .module = mod_c_imports },
            .{ .name = "config", .module = mod_config },
            .{ .name = "time", .module = mod_time },
            .{ .name = "sys", .module = mod_sys },
            .{ .name = "camera", .module = mod_camera },
        },
    });

    const mod_cores = b.createModule(.{
        .root_source_file = b.path("src/core_layouts/root_cores.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "camera", .module = mod_camera },
            .{ .name = "sync_data", .module = mod_sync_data },
            .{ .name = "encoding", .module = mod_encoding },
            .{ .name = "debug", .module = mod_debug },
            .{ .name = "config", .module = mod_config },
            .{ .name = "net", .module = mod_net },
            .{ .name = "sys", .module = mod_sys },
        },
    });

    const exe = b.addExecutable(.{
        .name = "zig_home_security_client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core_layouts", .module = mod_cores },
                .{ .name = "debug", .module = mod_debug },
            },
        }),
    });

    exe.root_module.link_libc = true;
    exe.root_module.linkSystemLibrary("libavformat", .{});
    exe.root_module.linkSystemLibrary("libavcodec", .{});
    exe.root_module.linkSystemLibrary("libavutil", .{});
    exe.root_module.linkSystemLibrary("libswscale", .{});

    const options = b.addOptions();
    const number_of_cores = b.option(usize, "number_of_cores", "Number of CPU cores to use for building") orelse std.Thread.getCpuCount() catch 1;

    options.addOption(usize, "number_of_cores", number_of_cores);

    exe.root_module.addOptions("config", options);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    run_cmd.addPassthruArgs();
}
