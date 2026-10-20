const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const nanoui = b.dependency("nanoui", .{ .target = target, .optimize = optimize }).module("nanoui");
    const imports: []const std.Build.Module.Import = &.{.{ .name = "nanoui", .module = nanoui }};

    const exe = b.addExecutable(.{ .name = "nanokeep", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = imports,
    }) });
    exe.root_module.linkFramework("CoreServices", .{});
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run nanokeep").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = imports,
    }) });
    tests.root_module.linkFramework("CoreServices", .{});
    b.step("test", "Run nanokeep tests").dependOn(&b.addRunArtifact(tests).step);
}
