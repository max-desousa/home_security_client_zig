const std = @import("std");

pub fn build(b: *std.Build) void {
    // Define target and optimization
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the camera module
    const camera_module = b.addModule("camera", .{
        .root_source_file = b.path("src/camera/root.zig"),
        .target = target,
    });

    // Create the executable
    const exe = b.addExecutable(.{
        .name = "zig_home_security_client",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add the camera module as a dependency
    exe.root_module.addImport("camera", camera_module);

    // Link system libraries for V4L2
    exe.linkLibC();
    exe.linkSystemLibrary("v4l2");

    // Add include paths for system headers (optional, adjust if needed)
    exe.addIncludePath(.{ .path = "/usr/include" });

    // Install the executable
    b.installArtifact(exe);

    // Add a run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Register the run step
    b.step("run", "Run the app").dependOn(&run_cmd.step);

    // Add test steps for the camera module
    const camera_tests = b.addTest(.{
        .root_module = camera_module,
    });
    const run_camera_tests = b.addRunArtifact(camera_tests);

    // Add test steps for the executable's root module
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // Register the test step
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_camera_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
