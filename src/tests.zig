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
const fda = @import("fda.zig");
const metrics = @import("metrics.zig");
const machine = @import("machine.zig");
const iokit = @import("iokit.zig");
const view_clean = @import("view_clean.zig");
const view_card = @import("view_card.zig");
const objc = nanoui.objc;

extern "c" const kCFRunLoopDefaultMode: *anyopaque;
extern "c" fn CFRunLoopRunInMode(mode: *anyopaque, seconds: f64, once: bool) i32;
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

test "Full Disk Access is read from whether the TCC database opens" {
    const t = try Tmp.make();
    defer t.remove();
    try std.testing.expect(!fda.granted(t.path()));
    try t.sh("mkdir -p 'Library/Application Support/com.apple.TCC' && printf x > 'Library/Application Support/com.apple.TCC/TCC.db'", .{});
    try std.testing.expect(fda.granted(t.path()));
    try t.sh("chmod 000 'Library/Application Support/com.apple.TCC/TCC.db'", .{});
    if (std.c.getuid() != 0) try std.testing.expect(!fda.granted(t.path()));
    const home = std.mem.span(std.c.getenv("HOME").?);
    var p: [1024]u8 = undefined;
    const db = try std.fmt.bufPrint(&p, "{s}/Library/Application Support/com.apple.TCC/TCC.db", .{home});
    const readable = try run.capture(gpa, &.{ "/bin/test", "-r", db });
    defer readable.deinit(gpa);
    try std.testing.expectEqual(readable.code == 0, fda.granted(home));
}

test "the guide sits under System Settings, or low in the middle, inside the screen" {
    const screen: objc.CGRect = .{ .origin = .{ .x = 0, .y = 25 }, .size = .{ .width = 1440, .height = 875 } };
    const under = fda.anchor(.{ .origin = .{ .x = 400, .y = 300 }, .size = .{ .width = 700, .height = 500 } }, screen);
    try std.testing.expectEqual(@as(f64, 400 + 350 - 190), under.origin.x);
    try std.testing.expectEqual(@as(f64, 300 - 110 + 20), under.origin.y);
    const alone = fda.anchor(null, screen);
    try std.testing.expectEqual(@as(f64, 720 - 190), alone.origin.x);
    try std.testing.expectEqual(@as(f64, 25 + 80), alone.origin.y);
    const edge = fda.anchor(.{ .origin = .{ .x = 1300, .y = 0 }, .size = .{ .width = 300, .height = 60 } }, screen);
    try std.testing.expectEqual(@as(f64, 1440 - 380 - 12), edge.origin.x);
    try std.testing.expectEqual(@as(f64, 25 + 8), edge.origin.y);
}

test "the drag card hands over the app's file URL and allows a copy" {
    const pool = objc.Pool.push();
    defer pool.pop();
    _ = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    const item = fda.draggingItem("/Applications/Safari.app");
    defer objc.release(item);
    const writer = objc.msg(objc.Object, item, "item", .{});
    try std.testing.expect(objc.msg(objc.BOOL, writer, "isKindOfClass:", .{objc.class("NSURL")}));
    try std.testing.expect(objc.msg(objc.BOOL, writer, "isFileURL", .{}));
    try std.testing.expectEqualStrings("/Applications/Safari.app", objc.fromNSString(objc.msg(?objc.Object, writer, "path", .{})));

    var g: fda.Guide = .{ .home = "/nonexistent", .on_granted = undefined };
    g.build();
    defer g.dismiss();
    const panel = g.panel.?;
    try std.testing.expect(!objc.msg(objc.BOOL, panel, "isVisible", .{}));
    try std.testing.expect(!objc.msg(objc.BOOL, panel, "hidesOnDeactivate", .{}));
    try std.testing.expectEqualStrings("Drag nanokeep into the Full Disk Access list", objc.fromNSString(objc.msg(?objc.Object, g.title.?, "stringValue", .{})));
    const card = g.card.?;
    const mask = objc.msg(objc.NSUInteger, card, "draggingSession:sourceOperationMaskForDraggingContext:", .{ @as(?objc.Object, null), @as(objc.NSInteger, 0) });
    try std.testing.expect(mask & 1 != 0);
    const f = objc.msg(objc.CGRect, card, "frame", .{});
    const hit = objc.msg(?objc.Object, card, "hitTest:", .{objc.CGPoint{ .x = f.origin.x + 5, .y = f.origin.y + 5 }});
    try std.testing.expectEqual(@as(?objc.Object, card), hit);
    const miss = objc.msg(?objc.Object, card, "hitTest:", .{objc.CGPoint{ .x = f.origin.x - 5, .y = f.origin.y }});
    try std.testing.expectEqual(@as(?objc.Object, null), miss);
    try std.testing.expect(g.item.len > 0);
    if (std.c.getenv("NANOKEEP_SHOT_GUIDE")) |out| {
        const content = objc.msg(objc.Object, panel, "contentView", .{});
        const bounds = objc.msg(objc.CGRect, content, "bounds", .{});
        const rep = objc.msg(objc.Object, content, "bitmapImageRepForCachingDisplayInRect:", .{bounds});
        objc.msg(void, content, "cacheDisplayInRect:toBitmapImageRep:", .{ bounds, rep });
        const png = objc.msg(objc.Object, rep, "representationUsingType:properties:", .{ @as(objc.NSUInteger, 4), objc.msg(objc.Object, objc.class("NSDictionary"), "dictionary", .{}) });
        try std.testing.expect(objc.msg(objc.BOOL, png, "writeToFile:atomically:", .{ objc.nsString(std.mem.span(out)), objc.YES }));
    }
}

var access_asked: usize = 0;

fn recordAccess(_: *App) void {
    access_asked += 1;
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
    a.access_fn = recordAccess;
    try t.sh("mkdir Downloads && chmod 000 Downloads", .{});
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
    try std.testing.expectEqual(@as(usize, 0), access_asked);
    tester.resize(1100, 1400);
    tester.settle(1);
    try tester.clickText("Allow Full Disk Access");
    tester.settle(1);
    try std.testing.expectEqual(@as(usize, 1), access_asked);
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

test "history finds the sample at or before a time, and charts columns across a range" {
    var h: metrics.History = .{};
    try std.testing.expectEqual(@as(?metrics.Sample, null), h.at(5, 1));
    for (0..5) |i| h.push(.{ .t = @floatFromInt(i * 2), .gpu = @floatFromInt(i * 10) });
    try std.testing.expectEqual(@as(f32, 20), h.at(5, 1).?.gpu);
    try std.testing.expectEqual(@as(f32, 40), h.at(100, 1).?.gpu);
    try std.testing.expectEqual(@as(f32, 0), h.at(-0.5, 1).?.gpu);
    try std.testing.expectEqual(@as(?metrics.Sample, null), h.at(-3, 1));
    try std.testing.expectEqual(@as(f32, 40), h.column(8, 8, 4, 3, 1).?.gpu);
    try std.testing.expectEqual(@as(f32, 10), h.column(8, 8, 4, 0, 1).?.gpu);
    try std.testing.expectEqual(@as(f32, 30), h.column(8, 8, 4, 2, 1).?.gpu);
    try std.testing.expectEqual(@as(?metrics.Sample, null), h.column(8, 60, 4, 0, 1));
    try std.testing.expectEqual(@as(f32, 40), h.peak(3, "gpu"));
    try std.testing.expectEqual(@as(f32, 30), h.average(3, "gpu"));
    for (0..metrics.history_len) |i| h.push(.{ .t = @floatFromInt(100 + i) });
    try std.testing.expectEqual(@as(usize, metrics.history_len), h.len);
    try std.testing.expectEqual(@as(f64, 100), h.get(0).t);
}

test "the disk map gives each found slice a dot and what is left to free space" {
    var dots: [4]usize = undefined;
    view_clean.allocate(&dots, &.{ 1, 0, 500, 0 }, 1000, 100);
    try std.testing.expectEqualSlices(usize, &.{ 1, 0, 50, 49 }, &dots);
    view_clean.allocate(&dots, &.{ 900, 900, 900, 0 }, 1000, 10);
    try std.testing.expectEqual(@as(usize, 10), dots[0] + dots[1] + dots[2] + dots[3]);
    try std.testing.expectEqual(@as(usize, 0), dots[3]);
}

fn ifinfo(buf: []u8, flags: i32, in: u64, out: u64) void {
    @memset(buf, 0);
    std.mem.writeInt(u16, buf[0..2], @intCast(buf.len), .little);
    buf[3] = 0x12;
    std.mem.writeInt(i32, buf[8..12], flags, .little);
    std.mem.writeInt(u64, buf[96..104], in, .little);
    std.mem.writeInt(u64, buf[104..112], out, .little);
}

test "network counters add up the interfaces that are up, leaving out loopback" {
    var buf: [3 * 160]u8 = undefined;
    ifinfo(buf[0..160], 0x1, 1000, 10);
    ifinfo(buf[160..320], 0x1 | 0x8, 5000, 50);
    ifinfo(buf[320..480], 0x0, 7000, 70);
    const got = metrics.sumInterfaces(&buf);
    try std.testing.expectEqual(@as(u64, 1000), got.in);
    try std.testing.expectEqual(@as(u64, 10), got.out);
    const live = metrics.netBytes(gpa);
    try std.testing.expect(live.in > 0);
}

test "the Mac's name comes from system_profiler, or from its model" {
    const json = "{ \"SPHardwareDataType\" : [ { \"_name\" : \"hardware_overview\", \"machine_model\" : \"Mac16,11\", \"machine_name\" : \"Mac mini\" } ] }";
    try std.testing.expectEqualStrings("Mac mini", machine.jsonField(json, "machine_name").?);
    try std.testing.expectEqualStrings("Mac16,11", machine.jsonField(json, "machine_model").?);
    try std.testing.expectEqual(@as(?[]const u8, null), machine.jsonField(json, "serial_number"));
    try std.testing.expectEqualStrings("MacBook Pro", machine.familyOf("MacBookPro18,3"));
    try std.testing.expectEqualStrings("Mac mini", machine.familyOf("Macmini9,1"));
    try std.testing.expectEqualStrings("Mac", machine.familyOf("Mac16,11"));
    try std.testing.expect(iokit.keepsAwake("PreventUserIdleSystemSleep"));
    try std.testing.expect(!iokit.keepsAwake("UserIsActive"));
    try std.testing.expect(iokit.displayKind("NoDisplaySleepAssertion"));
}

test "the metrics sampler reads this machine" {
    var m: metrics.Metrics = .init();
    defer m.deinit();
    m.sample(0, 0);
    try std.testing.expectEqual(@as(usize, 0), m.history.len);
    m.sample(1, 2.5);
    try std.testing.expectEqual(@as(usize, 1), m.history.len);
    try std.testing.expect(m.cpu.count > 0);
    try std.testing.expect(m.cpu.busy() >= 0 and m.cpu.busy() <= 100.5);
    try std.testing.expect(m.memory.total > m.memory.used());
    try std.testing.expect(m.memory.app > 0 and m.memory.wired > 0);
    try std.testing.expect(m.disk.read_total > 0);
    try std.testing.expectEqual(@as(f32, 2.5), m.history.last().?.power);
    var mc: machine.Machine = .{};
    mc.read();
    try std.testing.expect(mc.chip.len > 0 and mc.os.len > 0 and mc.memory > 0 and mc.boot > 0);
    try std.testing.expect(mc.volume.len > 0);
}

fn pump(cl: *const cleaner.Cleaner) void {
    var spins: usize = 0;
    while (cl.job != null and spins < 600) : (spins += 1) _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
}

test "a scan fills in one category at a time, and Cancel stops it" {
    const t = try Tmp.make();
    defer t.remove();
    try t.sh("mkdir -p Library/Caches/com.vendor.app Library/Logs .claude/projects/p && dd if=/dev/urandom of=Library/Caches/com.vendor.app/blob bs=4096 count=10 2>/dev/null && printf x > Library/Logs/a.log && printf '{{}}' > .claude/projects/p/old.jsonl && printf '{{}}' > .claude/projects/p/new.jsonl && touch -t 202001010000 .claude/projects/p/old.jsonl", .{});
    var cl: cleaner.Cleaner = .init(gpa, t.path(), "");
    defer cl.deinit();
    var changes: usize = 0;
    const Count = struct {
        fn f(ctx: *anyopaque) void {
            const n: *usize = @ptrCast(@alignCast(ctx));
            n.* += 1;
        }
    };
    cl.on_change = .{ .ctx = &changes, .func = Count.f };
    cl.scan();
    try std.testing.expectEqual(cleaner.Phase.scanning, cl.phase);
    try std.testing.expect(cl.step() != null);
    pump(&cl);
    try std.testing.expect(cl.scanned);
    try std.testing.expect(changes >= cleaner.specs.len);
    for (&cl.cats) |*cat| try std.testing.expect(cat.measured);
    const agents = &cl.cats[@intFromEnum(cleaner.Kind.agents)];
    try std.testing.expectEqual(@as(usize, 1), agents.items().len);
    try std.testing.expect(std.mem.endsWith(u8, agents.items()[0].path, "old.jsonl"));
    try std.testing.expect(cl.cats[@intFromEnum(cleaner.Kind.caches)].bytes() >= 10 * 4096);
    try std.testing.expectEqual(cl.total(), cl.found());
    cl.scan();
    try std.testing.expect(!cl.scanned);
    cl.cancel();
    pump(&cl);
    try std.testing.expect(cl.cancelled);
    try std.testing.expect(!cl.scanned);
    try std.testing.expectEqual(cleaner.Phase.idle, cl.phase);
}

fn fakeClock() f64 {
    return 0;
}

test "every page draws from this Mac's samples" {
    var a: App = .init(gpa, "/nonexistent-home", "", &.{});
    defer a.deinit();
    a.clock = fakeClock;
    a.cleaner.sync = true;
    a.machine.read();
    a.inventory.loaded = true;
    for (0..6) |i| {
        const tm: f64 = @floatFromInt(i * 2);
        a.sampler.sample(tm);
        a.metrics.sample(tm, a.sampler.system.power);
    }
    a.last = 1e9;
    a.everyone.build(a.sampler.procs.items, .{ .show = .all, .uid = a.sampler.uid }, &a.expanded_groups) catch {};
    try std.testing.expectEqual(@as(usize, 5), a.metrics.history.len);
    var idx: [10]u32 = undefined;
    const n = view_card.top(&a, .memory, &idx);
    try std.testing.expect(n > 0);
    for (idx[1..n], 0..) |gi, k| try std.testing.expect(a.everyone.groups.items[gi].memory <= a.everyone.groups.items[idx[k]].memory);
    var tester: ui.Tester = undefined;
    try tester.init(gpa, .init(&a, view), .{});
    defer tester.deinit();
    tester.resize(1240, 820);
    const Want = struct { page: @import("app.zig").Page, text: []const u8 };
    const pages = [_]Want{
        .{ .page = .overview, .text = "Memory by Type" },
        .{ .page = .cpu, .text = "Processor Load" },
        .{ .page = .memory, .text = "Swap" },
        .{ .page = .gpu, .text = "Engines" },
        .{ .page = .disk, .text = "Disk Activity" },
        .{ .page = .network, .text = "Network Activity" },
        .{ .page = .energy, .text = "Keeping Awake" },
        .{ .page = .about, .text = "Hardware" },
        .{ .page = .cleanup, .text = "Scan to see what can be cleaned." },
    };
    for (pages) |p| {
        a.page = p.page;
        tester.settle(1);
        if (!tester.hasText(p.text)) {
            std.debug.print("missing {s} on {s}\n", .{ p.text, @tagName(p.page) });
            return error.Missing;
        }
        if (std.c.getenv("NANOKEEP_SHOT_DIR")) |dir| {
            var pb: [512]u8 = undefined;
            try tester.screenshot(try std.fmt.bufPrint(&pb, "{s}/{s}.png", .{ std.mem.span(dir), @tagName(p.page) }));
        }
    }
    a.page = .about;
    tester.settle(1);
    try tester.clickText("Show");
    tester.settle(1);
    try std.testing.expect(a.show_serial);
}

test "the cleanup page shows a scan as it runs and what it found" {
    const t = try Tmp.make();
    defer t.remove();
    try t.sh("mkdir -p Library/Caches/com.vendor.big Library/Logs Library/Developer/Xcode/DerivedData/App && dd if=/dev/urandom of=Library/Caches/com.vendor.big/blob bs=4096 count=400 2>/dev/null && dd if=/dev/urandom of=Library/Developer/Xcode/DerivedData/App/o bs=4096 count=200 2>/dev/null && printf x > Library/Logs/app.log", .{});
    var a: App = .init(gpa, t.path(), "", &.{});
    defer a.deinit();
    a.clock = fakeClock;
    a.inventory.loaded = true;
    a.machine.read();
    a.sampler.sample(0);
    a.last = 1e9;
    a.page = .cleanup;
    var tester: ui.Tester = undefined;
    try tester.init(gpa, .init(&a, view), .{});
    defer tester.deinit();
    tester.resize(1240, 820);
    tester.settle(1);
    try std.testing.expect(tester.hasText("Scan to see what can be cleaned."));
    try shotTo(&tester, "cleanup-idle");
    a.cleaner.scan();
    tester.advance(0.5);
    try std.testing.expect(tester.hasText("Cancel"));
    try std.testing.expect(tester.hasText("Measuring caches…"));
    try shotTo(&tester, "cleanup-scanning");
    pump(&a.cleaner);
    tester.settle(2);
    try std.testing.expect(a.cleaner.scanned);
    try std.testing.expect(tester.containsText("Clean "));
    try shotTo(&tester, "cleanup-found");
}

fn shotTo(tester: *ui.Tester, name: []const u8) !void {
    const dir = std.c.getenv("NANOKEEP_SHOT_DIR") orelse return;
    var pb: [512]u8 = undefined;
    try tester.screenshot(try std.fmt.bufPrint(&pb, "{s}/{s}.png", .{ std.mem.span(dir), name }));
}

test {
    _ = walk;
    _ = cleaner;
    _ = procs;
    _ = groups;
    _ = worktree;
    _ = apps;
}
