const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const worker = b.addExecutable(.{ .name = "frameshift-release-input", .root_module = module });
    b.installArtifact(worker);
    const tests = b.addTest(.{ .root_module = module });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Test bounded request parsing").dependOn(&run_tests.step);
    const command_module = b.createModule(.{
        .root_source_file = b.path("src/command.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const command = b.addExecutable(.{ .name = "frameshift-release-command", .root_module = command_module });
    b.installArtifact(command);
    const command_tests = b.addTest(.{ .root_module = command_module });
    const run_command_tests = b.addRunArtifact(command_tests);
    b.step("test-command", "Test bounded command parsing").dependOn(&run_command_tests.step);
}
