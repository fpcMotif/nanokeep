const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const walk = @import("walk.zig");
const cleaner = @import("cleaner.zig");
const procs = @import("procs.zig");
const groups = @import("groups.zig");
const worktree = @import("worktree.zig");
const apps = @import("apps.zig");
const run = @import("run.zig");
const App = @import("app.zig").App;
const view = @import("view.zig").view;

extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
extern "c" fn system(cmd: [*:0]const u8) c_int;
extern "c" fn popen(cmd: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn pclose(f: *anyopaque) c_int;
extern "c" fn fread(buf: [*]u8, size: usize, n: usize, f: *anyopaque) usize;
extern "c" fn time(t: ?*i64) i64;

const gpa = std.testing.allocator;

const Tmp = struct {
    buf: [64:0]u8,
    len: usize,

    fn make() !Tmp {
        var t: Tmp = .{ .buf = @splat(0), .len = 0 };
        const tmpl = "/tmp/nanokeep-test-XXXXXX";
        @memcpy(t.buf[0..tmpl.len], tmpl);
        _ = mkdtemp(&t.buf) orelse return error.TmpDir;
        t.len = tmpl.len;
        return t;
    }

    fn path(t: *const Tmp) [:0]const u8 {
        return t.buf[0..t.len :0];
    }

    fn sub(t: *const Tmp, buf: []u8, name: []const u8) ![:0]const u8 {
        return std.fmt.bufPrintSentinel(buf, "{s}/{s}", .{ t.path(), name }, 0);
    }

    fn sh(t: *const Tmp, comptime fmt: []const u8, args: anytype) !void {
        var cmd: [4096]u8 = undefined;
        const s = try std.fmt.bufPrintSentinel(&cmd, "cd '{s}' && (" ++ fmt ++ ") >/dev/null", .{t.path()} ++ args, 0);
        if (system(s) != 0) return error.Shell;
    }

    fn remove(t: *const Tmp) void {
        var cmd: [128]u8 = undefined;
        const s = std.fmt.bufPrintSentinel(&cmd, "rm -rf '{s}'", .{t.path()}, 0) catch return;
        _ = system(s);
    }
};

fn shellNumber(comptime fmt: []const u8, args: anytype) !u64 {
    var cmd: [1400]u8 = undefined;
    const s = try std.fmt.bufPrintSentinel(&cmd, fmt, args, 0);
    const f = popen(s, "r") orelse return error.Popen;
    var out: [256]u8 = undefined;
    const n = fread(&out, 1, out.len, f);
    _ = pclose(f);
    const text = std.mem.trim(u8, out[0..n], " \t\n");
    const end = std.mem.indexOfAny(u8, text, " \t") orelse text.len;
    return std.fmt.parseInt(u64, text[0..end], 10);
}

fn duBytes(path: []const u8) !u64 {
    return (try shellNumber("/usr/bin/du -sk '{s}' 2>/dev/null", .{path})) * 1024;
}

fn uniqueFiles(path: []const u8) !u64 {
    return shellNumber("/usr/bin/find '{s}' ! -type d -exec /usr/bin/stat -f %i {{}} + | /usr/bin/sort -u | /usr/bin/wc -l", .{path});
}

fn newestTime(path: []const u8) !u64 {
    return shellNumber("/usr/bin/find '{s}' -exec /usr/bin/stat -f %m {{}} + | /usr/bin/sort -n | /usr/bin/tail -1", .{path});
}

test "the walker agrees with du and find on sizes, files and change times" {
    const t = try Tmp.make();
    defer t.remove();
    try t.sh("mkdir -p a/b/c d && dd if=/dev/urandom of=a/one bs=1000 count=37 2>/dev/null && dd if=/dev/urandom of=a/b/c/two bs=4096 count=300 2>/dev/null && printf x > d/tiny && ln a/b/c/two d/same && dd if=/dev/urandom of=../nanokeep-outside-{s} bs=1m count=3 2>/dev/null && ln -s ../nanokeep-outside-{s} d/link && touch -t 202001010000 a/one", .{ t.path()[19..], t.path()[19..] });
    defer t.sh("rm -f ../nanokeep-outside-{s}", .{t.path()[19..]}) catch {};
    const got = walk.measure(gpa, t.path().ptr);
    try std.testing.expectEqual(try duBytes(t.path()), got.bytes);
    try std.testing.expectEqual(try uniqueFiles(t.path()), got.files);
    try std.testing.expectEqual(try newestTime(t.path()), @as(u64, @intCast(got.newest)));
    try std.testing.expect(got.bytes < 3 * 1024 * 1024);
}

test "the walker agrees with du and find on a real source tree" {
    const tree = "src";
    const got = walk.measure(gpa, tree);
    try std.testing.expectEqual(try duBytes(tree), got.bytes);
    try std.testing.expectEqual(try uniqueFiles(tree), got.files);
    try std.testing.expectEqual(try newestTime(tree), @as(u64, @intCast(got.newest)));
}

test "the walker measures a single file" {
    const t = try Tmp.make();
    defer t.remove();
    try t.sh("dd if=/dev/urandom of=f.dmg bs=4096 count=10 2>/dev/null && touch -t 201901020304 f.dmg", .{});
    var p: [128]u8 = undefined;
    const f = try t.sub(&p, "f.dmg");
    const got = walk.measure(gpa, f.ptr);
    try std.testing.expectEqual(try duBytes(f), got.bytes);
    try std.testing.expectEqual(@as(u64, 1), got.files);
    try std.testing.expectEqual(try newestTime(f), @as(u64, @intCast(got.newest)));
}

test "the parallel pool gives each path its own size" {
    const t = try Tmp.make();
    defer t.remove();
    try t.sh("mkdir x y && dd if=/dev/urandom of=x/f bs=4096 count=50 2>/dev/null && dd if=/dev/urandom of=y/f bs=4096 count=5 2>/dev/null && printf z > y/g", .{});
    var px: [128]u8 = undefined;
    var py: [128]u8 = undefined;
    const paths = [_][:0]const u8{ try t.sub(&px, "x"), try t.sub(&py, "y") };
    var out: [2]walk.Size = .{ .{}, .{} };
    var pool: walk.Pool = .{ .gpa = std.heap.smp_allocator, .paths = &paths, .out = &out };
    pool.run();
    try std.testing.expectEqual(try duBytes(paths[0]), out[0].bytes);
    try std.testing.expectEqual(try duBytes(paths[1]), out[1].bytes);
    try std.testing.expectEqual(@as(u64, 1), out[0].files);
    try std.testing.expectEqual(@as(u64, 2), out[1].files);
}

test "filters keep what each source cleans" {
    try std.testing.expect(cleaner.keep(.any, ".DS_Store"));
    try std.testing.expect(!cleaner.keep(.any, ".."));
    try std.testing.expect(!cleaner.keep(.not_apple, "com.apple.Safari"));
    try std.testing.expect(cleaner.keep(.not_apple, "com.google.Chrome"));
    try std.testing.expect(cleaner.keep(.installer, "Zed.dmg"));
    try std.testing.expect(!cleaner.keep(.installer, "notes.txt"));
}

test "git's porcelain worktree list is parsed" {
    const text =
        \\worktree /r/main
        \\HEAD 1111111111111111111111111111111111111111
        \\branch refs/heads/main
        \\
        \\worktree /r/feature
        \\HEAD 2222222222222222222222222222222222222222
        \\branch refs/heads/feature
        \\
        \\worktree /r/held
        \\HEAD 3333333333333333333333333333333333333333
        \\detached
        \\locked reason here
        \\
        \\worktree /r/gone
        \\HEAD 4444444444444444444444444444444444444444
        \\prunable gitdir file points to non-existent location
        \\
    ;
    const list = try worktree.parseList(gpa, text);
    defer gpa.free(list);
    try std.testing.expectEqual(@as(usize, 4), list.len);
    try std.testing.expectEqualStrings("/r/feature", list[1].path);
    try std.testing.expect(!list[1].locked and !list[1].prunable);
    try std.testing.expect(list[2].locked);
    try std.testing.expect(list[3].prunable);
}

test "only clean, unlocked linked worktrees are found, and removing one keeps its branch" {
    const t = try Tmp.make();
    defer t.remove();
    try t.sh("mkdir -p devv/repo && cd devv/repo && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init && git worktree add -q ../clean -b clean && git worktree add -q ../dirty -b dirty && printf x > ../dirty/new.txt && git worktree add -q ../held -b held && git worktree lock ../held", .{});
    var found = try worktree.find(gpa, t.path());
    defer {
        for (found.items) |f| {
            gpa.free(f.path);
            gpa.free(f.repo);
        }
        found.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 1), found.items.len);
    try std.testing.expect(std.mem.endsWith(u8, found.items[0].path, "/devv/clean"));
    try std.testing.expect(std.mem.endsWith(u8, found.items[0].repo, "/devv/repo"));
    try std.testing.expect(worktree.remove(gpa, found.items[0].repo, found.items[0].path));
    try t.sh("test ! -e devv/clean && git -C devv/repo rev-parse -q --verify refs/heads/clean >/dev/null", .{});
}

test "run captures a child's output and exit code" {
    const ok = try run.capture(gpa, &.{ "/bin/echo", "hello" });
    defer ok.deinit(gpa);
    try std.testing.expectEqualStrings("hello\n", ok.out);
    try std.testing.expectEqual(@as(u8, 0), ok.code);
    const bad = try run.capture(gpa, &.{ "/bin/sh", "-c", "exit 3" });
    defer bad.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 3), bad.code);
}

var trashed: std.ArrayList([]const u8) = .empty;

fn recordTrash(path: []const u8) bool {
    trashed.append(gpa, gpa.dupe(u8, path) catch return false) catch return false;
    return true;
}

fn clearTrashed() void {
    for (trashed.items) |p| gpa.free(p);
    trashed.clearAndFree(gpa);
}

test "cleaning trashes only selected categories, and stale temporary files only" {
    const t = try Tmp.make();
    defer t.remove();
    defer clearTrashed();
    try t.sh("mkdir -p home/Library/Caches/com.vendor.app home/Library/Caches/com.apple.kept home/.Trash home/Downloads tmp/fresh tmp/com.apple.old && dd if=/dev/urandom of=home/Library/Caches/com.vendor.app/blob bs=4096 count=20 2>/dev/null && printf x > home/Downloads/Setup.dmg && printf y > home/Downloads/notes.txt && printf z > home/.Trash/old && printf o > tmp/stale.log && printf n > tmp/fresh/now && touch -t 202001010000 tmp/stale.log tmp/com.apple.old", .{});
    var hb: [128]u8 = undefined;
    var tb: [128]u8 = undefined;
    var cl: cleaner.Cleaner = .init(gpa, try t.sub(&hb, "home"), try t.sub(&tb, "tmp/"));
    defer cl.deinit();
    cl.trash_fn = recordTrash;
    cl.sync = true;
    cl.scan();
    try std.testing.expect(cl.scanned);
    const caches = &cl.cats[@intFromEnum(cleaner.Kind.caches)];
    try std.testing.expectEqual(@as(usize, 1), caches.items().len);
    try std.testing.expect(std.mem.endsWith(u8, caches.items()[0].path, "com.vendor.app"));
    try std.testing.expect(caches.bytes() >= 20 * 4096);
    try std.testing.expectEqual(@as(u64, 1), caches.files());
    const temp = &cl.cats[@intFromEnum(cleaner.Kind.temporary)];
    try std.testing.expectEqual(@as(usize, 1), temp.items().len);
    try std.testing.expect(std.mem.endsWith(u8, temp.items()[0].path, "tmp/stale.log"));
    const installers = &cl.cats[@intFromEnum(cleaner.Kind.installers)];
    try std.testing.expectEqual(@as(usize, 1), installers.items().len);
    try std.testing.expect(!installers.selected);
    try std.testing.expect(!cl.cats[@intFromEnum(cleaner.Kind.trash)].selected);
    try std.testing.expect(!cl.cats[@intFromEnum(cleaner.Kind.developer)].selected);
    try std.testing.expect(!cl.selectedForever());
    cl.clean();
    try std.testing.expectEqual(@as(usize, 2), trashed.items.len);
    var saw_cache = false;
    var saw_temp = false;
    for (trashed.items) |p| {
        saw_cache = saw_cache or std.mem.endsWith(u8, p, "Library/Caches/com.vendor.app");
        saw_temp = saw_temp or std.mem.endsWith(u8, p, "tmp/stale.log");
    }
    try std.testing.expect(saw_cache and saw_temp);
    try std.testing.expect(cl.last.?.moved >= 20 * 4096);
}

test "cleaning the developer category removes clean worktrees with git" {
    const t = try Tmp.make();
    defer t.remove();
    defer clearTrashed();
    try t.sh("mkdir -p devv/repo && cd devv/repo && git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init && git worktree add -q ../spare -b spare && dd if=/dev/urandom of=../spare/data bs=4096 count=8 2>/dev/null && git -C ../spare add data && git -C ../spare -c user.email=t@t -c user.name=t commit -q -m data", .{});
    var cl: cleaner.Cleaner = .init(gpa, t.path(), "");
    defer cl.deinit();
    cl.trash_fn = recordTrash;
    cl.sync = true;
    cl.scan();
    const dev = &cl.cats[@intFromEnum(cleaner.Kind.developer)];
    try std.testing.expectEqual(@as(usize, 1), dev.items().len);
    try std.testing.expect(dev.items()[0].repo != null);
    try std.testing.expect(dev.bytes() >= 8 * 4096);
    for (&cl.cats) |*c| c.selected = c.spec.kind == .developer;
    try std.testing.expect(cl.selectedForever());
    cl.clean();
    try std.testing.expectEqual(@as(usize, 0), trashed.items.len);
    try t.sh("test ! -e devv/spare && git -C devv/repo rev-parse -q --verify refs/heads/spare >/dev/null", .{});
    try std.testing.expectEqual(@as(usize, 0), dev.items().len);
}

fn refuse(_: c_int, _: c_int) callconv(.c) c_int {
    return -1;
}

var sent: std.ArrayList([2]c_int) = .empty;

fn record(pid: c_int, sig: c_int) callconv(.c) c_int {
    sent.append(gpa, .{ pid, sig }) catch return -1;
    return 0;
}

test "quitting refuses itself and other users' processes" {
    defer sent.clearAndFree(gpa);
    var s: procs.Sampler = .init(gpa, "/");
    defer s.deinit();
    try s.procs.append(gpa, .{ .pid = s.self_pid, .uid = s.uid });
    try s.procs.append(gpa, .{ .pid = 1, .uid = 0 });
    try s.procs.append(gpa, .{ .pid = 4242, .uid = s.uid });
    try std.testing.expectError(error.Itself, s.quit(s.self_pid, .quit, record));
    if (s.uid != 0) try std.testing.expectError(error.NotYours, s.quit(1, .force, record));
    try s.quit(4242, .force, record);
    try std.testing.expectEqual([2]c_int{ 4242, 9 }, sent.items[0]);
    try std.testing.expectError(error.Failed, s.quit(4242, .quit, refuse));
}

test "the sampler reads this machine" {
    var s: procs.Sampler = .init(gpa, "/");
    defer s.deinit();
    s.sample(0);
    s.sample(1);
    try std.testing.expect(s.procs.items.len > 10);
    const me = s.find(s.self_pid).?;
    try std.testing.expect(me.threads >= 1);
    try std.testing.expect(me.cpu_time_ns > 0);
    try std.testing.expect(me.user.len > 0);
    try std.testing.expect(s.system.mem_total > s.system.mem_used);
    try std.testing.expect(s.system.disk_total > s.system.disk_free);
}

test "processes group under their outermost app" {
    try std.testing.expectEqualStrings("/Applications/Zed.app", procs.outerBundle("/Applications/Zed.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"));
    try std.testing.expectEqualStrings("", procs.outerBundle("/usr/libexec/logd"));
    const zed = "/Applications/Zed.app";
    const items = [_]procs.Proc{
        .{ .pid = 10, .uid = 501, .name = "Zed", .bundle = zed, .memory = 300, .cpu = 2, .threads = 20, .known = true },
        .{ .pid = 11, .uid = 501, .name = "Zed Helper", .bundle = zed, .memory = 200, .cpu = 1, .threads = 5, .known = true },
        .{ .pid = 12, .uid = 501, .name = "zsh", .memory = 50, .known = true },
        .{ .pid = 1, .uid = 0, .name = "launchd", .memory = 900, .known = true },
    };
    var expanded: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer expanded.deinit(gpa);
    var t: groups.Table = .{ .gpa = gpa };
    defer t.deinit();
    try t.build(&items, .{ .show = .all, .uid = 501 }, &expanded);
    try std.testing.expectEqual(@as(usize, 3), t.groups.items.len);
    try std.testing.expectEqualStrings("launchd", t.groups.items[0].name);
    const g = t.groups.items[1];
    try std.testing.expectEqualStrings("Zed", g.name);
    try std.testing.expectEqual(@as(u32, 2), g.count);
    try std.testing.expectEqual(@as(u64, 500), g.memory);
    try std.testing.expectEqual(@as(u32, 25), g.threads);
    try std.testing.expectEqual(@as(i32, 10), g.pid);
    try std.testing.expectEqual(@as(usize, 3), t.rows.items.len);
    try expanded.put(gpa, g.key, {});
    try t.build(&items, .{ .show = .all, .uid = 501 }, &expanded);
    try std.testing.expectEqual(@as(usize, 5), t.rows.items.len);
    var pids: std.ArrayList(i32) = .empty;
    defer pids.deinit(gpa);
    try t.pidsOf(t.group(g.key).?, &items, &pids);
    std.mem.sort(i32, pids.items, {}, std.sort.asc(i32));
    try std.testing.expectEqualSlices(i32, &.{ 10, 11 }, pids.items);
    try t.build(&items, .{ .show = .apps, .uid = 501 }, &expanded);
    try std.testing.expectEqual(@as(usize, 1), t.groups.items.len);
    try t.build(&items, .{ .show = .system, .uid = 501 }, &expanded);
    try std.testing.expectEqualStrings("launchd", t.groups.items[0].name);
    try t.build(&items, .{ .show = .mine, .uid = 501, .sort = .name }, &expanded);
    try std.testing.expectEqualStrings("Zed", t.groups.items[0].name);
    try std.testing.expectEqualStrings("zsh", t.groups.items[1].name);
    try t.build(&items, .{ .show = .all, .uid = 501, .query = "helper" }, &expanded);
    try std.testing.expectEqual(@as(usize, 1), t.shown);
}

fn header64(cpu: u32) [32]u8 {
    var h: [32]u8 = @splat(0);
    std.mem.writeInt(u32, h[0..4], 0xfeedfacf, .little);
    std.mem.writeInt(u32, h[4..8], cpu, .little);
    return h;
}

fn fatHeader(magic: u32, step: usize, cpus: []const u32) [128]u8 {
    var h: [128]u8 = @splat(0);
    std.mem.writeInt(u32, h[0..4], magic, .big);
    std.mem.writeInt(u32, h[4..8], @intCast(cpus.len), .big);
    for (cpus, 0..) |cpu, i| std.mem.writeInt(u32, h[8 + i * step ..][0..4], cpu, .big);
    return h;
}

test "an app's kind comes from its Mach-O header" {
    try std.testing.expectEqual(apps.Kind.apple, apps.kindOf(&header64(0x0100000c)));
    try std.testing.expectEqual(apps.Kind.intel, apps.kindOf(&header64(0x01000007)));
    try std.testing.expectEqual(apps.Kind.universal, apps.kindOf(&fatHeader(0xcafebabe, 20, &.{ 0x01000007, 0x0100000c })));
    try std.testing.expectEqual(apps.Kind.apple, apps.kindOf(&fatHeader(0xcafebabf, 32, &.{0x0100000c})));
    try std.testing.expectEqual(apps.Kind.unknown, apps.kindOf("#!/bin/sh\n"));
    const f = std.c.fopen("/usr/bin/true", "rb") orelse return error.Open;
    defer _ = std.c.fclose(f);
    var buf: [512]u8 = undefined;
    const n = std.c.fread(&buf, 1, buf.len, f);
    const archs = try run.capture(gpa, &.{ "/usr/bin/lipo", "-archs", "/usr/bin/true" });
    defer archs.deinit(gpa);
    const arm = std.mem.indexOf(u8, archs.out, "arm64") != null;
    const x86 = std.mem.indexOf(u8, archs.out, "x86_64") != null;
    const want: apps.Kind = if (arm and x86) .universal else if (arm) .apple else .intel;
    try std.testing.expectEqual(want, apps.kindOf(buf[0..n]));
}

test "bytes, durations and dates read as Finder shows them" {
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("999 B", procs.bytes(&b, 999));
    try std.testing.expectEqualStrings("1.5 MB", procs.bytes(&b, 1_500_000));
    try std.testing.expectEqualStrings("120 GB", procs.bytes(&b, 120_000_000_000));
    try std.testing.expectEqualStrings("0:01.50", procs.duration(&b, 1_500_000_000));
    try std.testing.expectEqualStrings("1:01:05", procs.duration(&b, 3665 * std.time.ns_per_s));
    const now: i64 = 1_800_000_000;
    try std.testing.expectEqualStrings("–", procs.ago(&b, now, 0));
    try std.testing.expectEqualStrings("Just now", procs.ago(&b, now, now - 10));
    try std.testing.expectEqualStrings("5 min ago", procs.ago(&b, now, now - 300));
    try std.testing.expectEqualStrings("3 hours ago", procs.ago(&b, now, now - 3 * 3600));
    try std.testing.expectEqualStrings("Yesterday", procs.ago(&b, now, now - 30 * 3600));
    try std.testing.expectEqualStrings("4 days ago", procs.ago(&b, now, now - 4 * 86400));
    try std.testing.expectEqualStrings("2 years ago", procs.ago(&b, now, now - 800 * 86400));
}

const plist =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<plist version="1.0"><dict>
    \\<key>CFBundleName</key><string>Fake Tool</string>
    \\<key>CFBundleExecutable</key><string>fake</string>
    \\<key>CFBundleShortVersionString</key><string>2.4.1</string>
    \\<key>CFBundleIdentifier</key><string>dev.nanokeep.fake</string>
    \\</dict></plist>
;

test "the window shows every page, asks before cleaning and before uninstalling" {
    const t = try Tmp.make();
    defer t.remove();
    defer clearTrashed();
    try t.sh("mkdir -p Library/Caches/com.vendor.big Library/Logs Apps/Fake.app/Contents/MacOS && dd if=/dev/urandom of=Library/Caches/com.vendor.big/blob bs=4096 count=40 2>/dev/null && printf x > Library/Logs/app.log && cp /usr/bin/true Apps/Fake.app/Contents/MacOS/fake && printf '%s' '{s}' > Apps/Fake.app/Contents/Info.plist", .{plist});
    var ab: [128]u8 = undefined;
    const dirs = [_][]const u8{try t.sub(&ab, "Apps")};
    var a: App = .init(gpa, t.path(), "", &dirs);
    defer a.deinit();
    a.cleaner.trash_fn = recordTrash;
    a.trash_app = recordTrash;
    a.cleaner.sync = true;
    a.inventory.sync = true;
    a.cleaner.scan();
    var tester: ui.Tester = undefined;
    try tester.init(gpa, .init(&a, view), .{});
    defer tester.deinit();
    tester.resize(1100, 720);
    tester.frame();
    try std.testing.expect(tester.hasText("Overview"));
    try tester.clickText("Processes");
    tester.settle(1);
    try std.testing.expect(tester.hasText("Force Quit"));
    try std.testing.expect(tester.hasText("Threads"));
    try std.testing.expect(tester.hasText("CPU Time"));
    try shot(&tester, "NANOKEEP_SHOT_PROCS");
    try tester.clickText("Apps");
    tester.settle(1);
    try std.testing.expect(tester.hasText("Fake Tool"));
    try std.testing.expect(tester.hasText("2.4.1"));
    try std.testing.expect(a.inventory.apps.items[0].kind != .unknown);
    try std.testing.expect(tester.hasText(a.inventory.apps.items[0].kind.title()));
    try std.testing.expect(a.inventory.apps.items[0].measured);
    try shot(&tester, "NANOKEEP_SHOT_APPS");
    try tester.clickText("Fake Tool");
    tester.settle(1);
    try tester.clickText("Uninstall");
    tester.settle(1);
    try std.testing.expect(a.confirm_uninstall);
    try std.testing.expectEqual(@as(usize, 0), trashed.items.len);
    try tester.clickText("Move to Trash");
    tester.settle(1);
    try std.testing.expectEqual(@as(usize, 1), trashed.items.len);
    try std.testing.expect(std.mem.endsWith(u8, trashed.items[0], "Apps/Fake.app"));
    try std.testing.expect(!tester.hasText("Fake Tool"));
    clearTrashed();
    try tester.clickText("Cleanup");
    tester.settle(1);
    try std.testing.expect(tester.hasText("Caches"));
    try std.testing.expect(tester.hasText("Temporary Files"));
    try std.testing.expect(tester.hasText("Modified"));
    try std.testing.expect(tester.hasText("Other files"));
    a.expanded[@intFromEnum(cleaner.Kind.caches)] = true;
    tester.settle(1);
    try std.testing.expect(tester.hasText("com.vendor.big"));
    try shot(&tester, "NANOKEEP_SHOT");
    try tester.clickText(cleanLabel(&a));
    tester.settle(1);
    try std.testing.expect(a.confirm_clean);
    try std.testing.expectEqual(@as(usize, 0), trashed.items.len);
    try tester.clickText("Clean");
    tester.settle(1);
    try std.testing.expectEqual(@as(usize, 2), trashed.items.len);
}

fn shot(tester: *ui.Tester, env: [:0]const u8) !void {
    const path = std.c.getenv(env) orelse return;
    tester.settle(1);
    try tester.screenshot(std.mem.span(path));
}

var label_buf: [48]u8 = undefined;

fn cleanLabel(a: *App) []const u8 {
    var b: [32]u8 = undefined;
    return std.fmt.bufPrint(&label_buf, "Clean {s}", .{procs.bytes(&b, a.cleaner.selectedBytes())}) catch unreachable;
}

test {
    _ = walk;
    _ = cleaner;
    _ = procs;
    _ = groups;
    _ = worktree;
    _ = apps;
}
