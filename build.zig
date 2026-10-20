const std = @import("std");

const info_plist =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    \\<plist version="1.0"><dict>
    \\<key>CFBundleIdentifier</key><string>dev.fpcmotif.nanokeep</string>
    \\<key>CFBundleName</key><string>nanokeep</string>
    \\<key>CFBundleDisplayName</key><string>nanokeep</string>
    \\<key>CFBundleExecutable</key><string>nanokeep</string>
    \\<key>CFBundlePackageType</key><string>APPL</string>
    \\<key>CFBundleShortVersionString</key><string>0.1.0</string>
    \\<key>CFBundleVersion</key><string>1</string>
    \\<key>LSMinimumSystemVersion</key><string>14.0</string>
    \\<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    \\<key>NSHighResolutionCapable</key><true/>
    \\</dict></plist>
    \\
;

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
    exe.root_module.linkFramework("CoreGraphics", .{});
    b.installArtifact(exe);

    const plist = b.addWriteFiles().add("Info.plist", info_plist);
    const bundle = b.addSystemCommand(&.{ "/bin/sh", "-c", "set -e; mkdir -p \"$1/Contents/MacOS\"; cp \"$2\" \"$1/Contents/MacOS/nanokeep\"; cp \"$3\" \"$1/Contents/Info.plist\"; /usr/bin/codesign --force --sign - \"$1\" 2>/dev/null; /usr/bin/codesign --verify --strict \"$1\"", "bundle" });
    const app_dir = bundle.addOutputDirectoryArg("nanokeep.app");
    bundle.addFileArg(exe.getEmittedBin());
    bundle.addFileArg(plist);
    b.installDirectory(.{ .source_dir = app_dir, .install_dir = .prefix, .install_subdir = "nanokeep.app" });
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
    tests.root_module.linkFramework("CoreGraphics", .{});
    b.step("test", "Run nanokeep tests").dependOn(&b.addRunArtifact(tests).step);
}
