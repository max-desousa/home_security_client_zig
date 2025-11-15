const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod_encoding = b.createModule(.{
        .root_source_file = b.path("src/encoding/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod_globals_buffer_queue = b.createModule(.{
        .root_source_file = b.path("src/global/buffer_queue.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod_file_system = b.createModule(.{
        .root_source_file = b.path("src/file_system/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod_camera = b.createModule(.{
        .root_source_file = b.path("src/camera/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "file_system", .module = mod_file_system },
            .{ .name = "buffer_queue", .module = mod_globals_buffer_queue },
        },
    });

    const mod_cores = b.createModule(.{
        .root_source_file = b.path("src/core_layouts/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "camera", .module = mod_camera },
            .{ .name = "buffer_queue", .module = mod_globals_buffer_queue },
            .{ .name = "encoding", .module = mod_encoding },
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
            },
        }),
    });

    exe.linkLibC();
    exe.linkSystemLibrary("avformat");
    exe.linkSystemLibrary("avcodec");
    exe.linkSystemLibrary("avutil");

    const options = b.addOptions();
    const number_of_cores = b.option(usize, "number_of_cores", "Number of CPU cores to use for building") orelse std.Thread.getCpuCount() catch 1;

    options.addOption(usize, "number_of_cores", number_of_cores);

    exe.root_module.addOptions("config", options);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_camera_tests = b.addTest(.{
        .root_module = mod_camera,
    });

    const run_mod_camera_tests = b.addRunArtifact(mod_camera_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_camera_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
