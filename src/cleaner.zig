const std = @import("std");
const nanoui = @import("nanoui");
const walk = @import("walk.zig");
const run = @import("run.zig");
const worktree = @import("worktree.zig");
const objc = nanoui.objc;

extern "c" fn clock_gettime_nsec_np(clock: c_int) u64;
extern "c" fn time(t: ?*i64) i64;
extern "c" fn opendir(path: [*:0]const u8) ?*anyopaque;
extern "c" fn readdir(dir: *anyopaque) ?*const Dirent;
extern "c" fn closedir(dir: *anyopaque) c_int;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;

const CLOCK_MONOTONIC_RAW = 4;
const stale_seconds = 3 * 24 * 3600;

const Dirent = extern struct { ino: u64, seekoff: u64, reclen: u16, namlen: u16, kind: u8, name: [1024]u8 };

pub const Kind = enum { caches, logs, packages, developer, temporary, installers, trash };

pub const Filter = enum { any, not_apple, installer };

pub const SourceKind = enum { children, worktrees, temp };

pub const Source = struct { dir: []const u8 = "", filter: Filter = .any, kind: SourceKind = .children };

pub const Spec = struct {
    kind: Kind,
    title: []const u8,
    desc: []const u8,
    note: []const u8,
    color: u24,
    sources: []const Source,
    forever: bool = false,
    selected: bool = true,
};

pub const specs = [_]Spec{
    .{ .kind = .caches, .title = "Caches", .desc = "Apps make them again as they need them", .note = "Open apps may rebuild some of them right away.", .color = 0x0a84ff, .sources = &.{.{ .dir = "Library/Caches", .filter = .not_apple }} },
    .{ .kind = .logs, .title = "Logs", .desc = "Apps' logs and crash reports", .note = "Crash reports you have not sent go too.", .color = 0xff9f0a, .sources = &.{.{ .dir = "Library/Logs" }} },
    .{ .kind = .packages, .title = "Package Caches", .desc = "Downloads package managers fetch again as they install", .note = "The next install downloads these packages again.", .color = 0xff6b00, .selected = false, .sources = &.{
        .{ .dir = ".npm/_cacache" },
        .{ .dir = ".bun/install/cache" },
        .{ .dir = ".cache/uv" },
        .{ .dir = ".cache/zig" },
        .{ .dir = ".cargo/registry/cache" },
        .{ .dir = ".gradle/caches" },
    } },
    .{ .kind = .developer, .title = "Developer", .desc = "Xcode's builds, and git worktrees with nothing to commit", .note = "Xcode builds from scratch the next time. Git removes the worktrees; their branches and commits stay.", .color = 0xff375f, .selected = false, .sources = &.{
        .{ .dir = "Library/Developer/Xcode/DerivedData" },
        .{ .dir = "Library/Developer/Xcode/iOS DeviceSupport" },
        .{ .dir = "Library/Developer/Xcode/macOS DeviceSupport" },
        .{ .dir = "Library/Developer/Xcode/UserData/Previews" },
        .{ .dir = "Library/Developer/CoreSimulator/Caches" },
        .{ .kind = .worktrees },
    } },
    .{ .kind = .temporary, .title = "Temporary Files", .desc = "Left by apps, unchanged for three days", .note = "Only files nothing changed for three days.", .color = 0x30b0c7, .sources = &.{.{ .kind = .temp, .filter = .not_apple }} },
    .{ .kind = .installers, .title = "Installers", .desc = "Disk images and packages left in Downloads", .note = "Download them again to install the apps again.", .color = 0xa2845e, .selected = false, .sources = &.{.{ .dir = "Downloads", .filter = .installer }} },
    .{ .kind = .trash, .title = "Trash", .desc = "Deleted for good", .note = "What is in the Trash is deleted for good.", .color = 0x8e8e93, .forever = true, .selected = false, .sources = &.{.{ .dir = ".Trash" }} },
};

pub const Item = struct {
    path: [:0]u8,
    repo: ?[:0]u8 = null,
    size: walk.Size = .{},

    fn free(it: Item, gpa: std.mem.Allocator) void {
        gpa.free(it.path);
        if (it.repo) |r| gpa.free(r);
    }
};

pub const Gathered = struct {
    items: std.ArrayList(Item) = .empty,
    denied: bool = false,

    fn clear(g: *Gathered, gpa: std.mem.Allocator) void {
        for (g.items.items) |it| it.free(gpa);
        g.items.clearRetainingCapacity();
        g.denied = false;
    }
};

pub const Category = struct {
    spec: *const Spec,
    found: Gathered = .{},
    selected: bool,

    pub fn items(cat: *const Category) []const Item {
        return cat.found.items.items;
    }

    pub fn bytes(cat: *const Category) u64 {
        var n: u64 = 0;
        for (cat.found.items.items) |it| n += it.size.bytes;
        return n;
    }

    pub fn files(cat: *const Category) u64 {
        var n: u64 = 0;
        for (cat.found.items.items) |it| n += it.size.files;
        return n;
    }

    pub fn newest(cat: *const Category) i64 {
        var n: i64 = 0;
        for (cat.found.items.items) |it| n = @max(n, it.size.newest);
        return n;
    }
};

pub const Phase = enum { idle, scanning, cleaning };

pub const Result = struct {
    moved: u64 = 0,
    deleted: u64 = 0,
    failed: u32 = 0,
};

pub const Notify = struct { ctx: *anyopaque, func: *const fn (*anyopaque) void };

pub const TrashFn = *const fn ([]const u8) bool;

const How = enum { trash, forever, worktree };

const Action = struct { path: [:0]u8, repo: ?[:0]u8, how: How, bytes: u64 };

pub fn keep(filter: Filter, name: []const u8) bool {
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return switch (filter) {
        .any => true,
        .not_apple => !std.mem.startsWith(u8, name, "com.apple."),
        .installer => std.mem.endsWith(u8, name, ".dmg") or std.mem.endsWith(u8, name, ".pkg"),
    };
}

pub const Env = struct { home: []const u8, tmpdir: []const u8, now: i64 };

pub fn gather(gpa: std.mem.Allocator, env: Env, lists: *[specs.len]Gathered) void {
    for (lists, &specs) |*g, *spec| for (spec.sources) |src| listSource(gpa, env, g, src) catch {};
    var paths: std.ArrayList([:0]const u8) = .empty;
    defer paths.deinit(gpa);
    for (lists) |*g| for (g.items.items) |it| paths.append(gpa, it.path) catch return;
    const out = gpa.alloc(walk.Size, paths.items.len) catch return;
    defer gpa.free(out);
    @memset(out, .{});
    var pool: walk.Pool = .{ .gpa = std.heap.smp_allocator, .paths = paths.items, .out = out };
    pool.run();
    var i: usize = 0;
    for (lists) |*g| for (g.items.items) |*it| {
        it.size = out[i];
        i += 1;
    };
    const temp = &lists[@intFromEnum(Kind.temporary)];
    var k: usize = 0;
    while (k < temp.items.items.len) {
        const it = temp.items.items[k];
        if (env.now - it.size.newest < stale_seconds) {
            it.free(gpa);
            _ = temp.items.swapRemove(k);
        } else k += 1;
    }
    for (lists) |*g| std.mem.sort(Item, g.items.items, {}, struct {
        fn gt(_: void, a: Item, b: Item) bool {
            return a.size.bytes > b.size.bytes;
        }
    }.gt);
}

fn listSource(gpa: std.mem.Allocator, env: Env, g: *Gathered, src: Source) !void {
    if (src.kind == .worktrees) {
        var found = try worktree.find(gpa, env.home);
        defer found.deinit(gpa);
        for (found.items) |f| try g.items.append(gpa, .{ .path = f.path, .repo = f.repo });
        return;
    }
    if (src.kind == .temp and env.tmpdir.len == 0) return;
    const dir_z = if (src.kind == .temp)
        try std.fmt.allocPrintSentinel(gpa, "{s}", .{std.mem.trimEnd(u8, env.tmpdir, "/")}, 0)
    else
        try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ env.home, src.dir }, 0);
    defer gpa.free(dir_z);
    if (access(dir_z, 0) != 0) return;
    const dir = opendir(dir_z) orelse {
        g.denied = true;
        return;
    };
    defer _ = closedir(dir);
    while (readdir(dir)) |ent| {
        const name = ent.name[0..ent.namlen];
        if (!keep(src.filter, name)) continue;
        const path = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ dir_z, name }, 0);
        g.items.append(gpa, .{ .path = path }) catch {
            gpa.free(path);
            return error.OutOfMemory;
        };
    }
}

fn perform(gpa: std.mem.Allocator, actions: []const Action, trash_fn: TrashFn) Result {
    var r: Result = .{};
    var forever: std.ArrayList([]const u8) = .empty;
    defer forever.deinit(gpa);
    forever.appendSlice(gpa, &.{ "/bin/rm", "-rf", "--" }) catch return r;
    var forever_bytes: u64 = 0;
    for (actions) |a| switch (a.how) {
        .trash => if (trash_fn(a.path)) {
            r.moved += a.bytes;
        } else {
            r.failed += 1;
        },
        .worktree => if (worktree.remove(gpa, a.repo.?, a.path)) {
            r.deleted += a.bytes;
        } else {
            r.failed += 1;
        },
        .forever => {
            forever.append(gpa, a.path) catch continue;
            forever_bytes += a.bytes;
        },
    };
    if (forever.items.len > 3) {
        const done = run.capture(gpa, forever.items) catch null;
        if (done) |d| {
            d.deinit(gpa);
            if (d.code == 0) r.deleted += forever_bytes else r.failed += 1;
        } else r.failed += 1;
    }
    return r;
}

const Job = struct {
    cl: *Cleaner,
    env: Env,
    clean: bool,
    lists: [specs.len]Gathered = @splat(.{}),
    actions: []Action = &.{},
    result: Result = .{},
    thread: ?std.Thread = null,

    fn work(j: *Job) void {
        j.execute();
        objc.dispatchMain(j, finished);
    }

    fn execute(j: *Job) void {
        if (j.clean) {
            j.result = perform(j.cl.gpa, j.actions, j.cl.trash_fn);
        } else gather(j.cl.gpa, j.env, &j.lists);
    }

    fn finished(ctx: ?*anyopaque) callconv(.c) void {
        const j: *Job = @ptrCast(@alignCast(ctx));
        j.cl.complete(j);
    }

    fn destroy(j: *Job, gpa: std.mem.Allocator) void {
        for (&j.lists) |*g| {
            g.clear(gpa);
            g.items.deinit(gpa);
        }
        for (j.actions) |a| {
            gpa.free(a.path);
            if (a.repo) |r| gpa.free(r);
        }
        gpa.free(j.actions);
        gpa.destroy(j);
    }
};

pub const Cleaner = struct {
    gpa: std.mem.Allocator,
    home: []const u8,
    tmpdir: []const u8,
    cats: [specs.len]Category,
    phase: Phase = .idle,
    scanned: bool = false,
    scanned_at: i64 = 0,
    started: u64 = 0,
    scan_ms: u64 = 0,
    last: ?Result = null,
    job: ?*Job = null,
    sync: bool = false,
    on_change: ?Notify = null,
    trash_fn: TrashFn = trashPath,

    pub fn init(gpa: std.mem.Allocator, home: []const u8, tmpdir: []const u8) Cleaner {
        var cats: [specs.len]Category = undefined;
        for (&cats, &specs) |*cat, *spec| cat.* = .{ .spec = spec, .selected = spec.selected };
        return .{ .gpa = gpa, .home = home, .tmpdir = tmpdir, .cats = cats };
    }

    pub fn deinit(cl: *Cleaner) void {
        if (cl.job) |j| {
            if (j.thread) |t| t.join();
            j.destroy(cl.gpa);
            cl.job = null;
        }
        for (&cl.cats) |*cat| {
            cat.found.clear(cl.gpa);
            cat.found.items.deinit(cl.gpa);
        }
    }

    pub fn total(cl: *const Cleaner) u64 {
        var n: u64 = 0;
        for (&cl.cats) |*c| n += c.bytes();
        return n;
    }

    pub fn selectedBytes(cl: *const Cleaner) u64 {
        var n: u64 = 0;
        for (&cl.cats) |*c| if (c.selected) {
            n += c.bytes();
        };
        return n;
    }

    pub fn selectedItems(cl: *const Cleaner) usize {
        var n: usize = 0;
        for (&cl.cats) |*c| if (c.selected) {
            n += c.items().len;
        };
        return n;
    }

    pub fn selectedForever(cl: *const Cleaner) bool {
        for (&cl.cats) |*c| if (c.selected and c.items().len > 0) {
            if (c.spec.forever) return true;
            for (c.items()) |it| if (it.repo != null) return true;
        };
        return false;
    }

    pub fn scan(cl: *Cleaner) void {
        if (cl.job != null) return;
        cl.start(.{ .cl = cl, .env = cl.env(), .clean = false }, .scanning);
    }

    pub fn clean(cl: *Cleaner) void {
        if (cl.job != null) return;
        var actions: std.ArrayList(Action) = .empty;
        for (&cl.cats) |*c| {
            if (!c.selected) continue;
            for (c.items()) |it| {
                const how: How = if (it.repo != null) .worktree else if (c.spec.forever) .forever else .trash;
                const path = cl.gpa.dupeSentinel(u8, it.path, 0) catch continue;
                const repo = if (it.repo) |r| cl.gpa.dupeSentinel(u8, r, 0) catch null else null;
                actions.append(cl.gpa, .{ .path = path, .repo = repo, .how = how, .bytes = it.size.bytes }) catch {
                    cl.gpa.free(path);
                    if (repo) |r| cl.gpa.free(r);
                };
            }
        }
        const owned = actions.toOwnedSlice(cl.gpa) catch return actions.deinit(cl.gpa);
        cl.start(.{ .cl = cl, .env = cl.env(), .clean = true, .actions = owned }, .cleaning);
    }

    fn env(cl: *const Cleaner) Env {
        return .{ .home = cl.home, .tmpdir = cl.tmpdir, .now = time(null) };
    }

    fn start(cl: *Cleaner, job: Job, phase: Phase) void {
        const j = cl.gpa.create(Job) catch return;
        j.* = job;
        cl.job = j;
        cl.phase = phase;
        cl.started = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
        if (cl.sync) {
            j.execute();
            return cl.complete(j);
        }
        j.thread = std.Thread.spawn(.{}, Job.work, .{j}) catch {
            j.execute();
            return cl.complete(j);
        };
        cl.tell();
    }

    fn complete(cl: *Cleaner, j: *Job) void {
        if (j.thread) |t| t.join();
        j.thread = null;
        cl.job = null;
        cl.phase = .idle;
        if (j.clean) {
            cl.last = j.result;
            j.destroy(cl.gpa);
            cl.tell();
            return cl.scan();
        }
        for (&cl.cats, &j.lists) |*c, *g| std.mem.swap(Gathered, &c.found, g);
        cl.scan_ms = (clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) -| cl.started) / std.time.ns_per_ms;
        cl.scanned = true;
        cl.scanned_at = j.env.now;
        j.destroy(cl.gpa);
        cl.tell();
    }

    fn tell(cl: *Cleaner) void {
        if (cl.on_change) |n| n.func(n.ctx);
    }
};

fn trashPath(path: []const u8) bool {
    return nanoui.shell.trash(path);
}
