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

pub const Kind = enum { caches, packages, developer, agents, installers, logs, temporary, trash };

pub const Filter = enum { any, not_apple, installer };

pub const SourceKind = enum { children, worktrees, temp, sessions };

const session_age = 30 * 24 * 3600;

pub const Source = struct { dir: []const u8 = "", filter: Filter = .any, kind: SourceKind = .children };

pub const Spec = struct {
    kind: Kind,
    title: []const u8,
    desc: []const u8,
    note: []const u8,
    doing: []const u8,
    color: u24,
    sources: []const Source,
    forever: bool = false,
    selected: bool = true,
};

pub const specs = [_]Spec{
    .{ .kind = .caches, .title = "Caches", .desc = "Apps make them again as they need them", .note = "Open apps may rebuild some of them right away.", .doing = "Measuring caches…", .color = 0x0a84ff, .sources = &.{.{ .dir = "Library/Caches", .filter = .not_apple }} },
    .{ .kind = .packages, .title = "Package Caches", .desc = "Downloads package managers fetch again as they install", .note = "The next install downloads these packages again.", .doing = "Measuring package caches…", .color = 0xff6b00, .selected = false, .sources = &.{
        .{ .dir = ".npm/_cacache" },
        .{ .dir = ".bun/install/cache" },
        .{ .dir = ".cache/uv" },
        .{ .dir = ".cache/zig" },
        .{ .dir = ".cargo/registry/cache" },
        .{ .dir = ".gradle/caches" },
    } },
    .{ .kind = .developer, .title = "Developer", .desc = "Xcode's builds, and git worktrees with nothing to commit", .note = "Xcode builds from scratch the next time. Git removes the worktrees; their branches and commits stay.", .doing = "Measuring git worktrees…", .color = 0xff375f, .selected = false, .sources = &.{
        .{ .dir = "Library/Developer/Xcode/DerivedData" },
        .{ .dir = "Library/Developer/Xcode/iOS DeviceSupport" },
        .{ .dir = "Library/Developer/Xcode/macOS DeviceSupport" },
        .{ .dir = "Library/Developer/Xcode/UserData/Previews" },
        .{ .dir = "Library/Developer/CoreSimulator/Caches" },
        .{ .kind = .worktrees },
    } },
    .{ .kind = .agents, .title = "Agent Sessions", .desc = "Claude Code's and Codex's sessions over a month old", .note = "You can't resume these conversations after they go.", .doing = "Looking through agent sessions…", .color = 0x5ac8fa, .selected = false, .sources = &.{
        .{ .dir = ".claude/projects", .kind = .sessions },
        .{ .dir = ".codex/sessions", .kind = .sessions },
        .{ .dir = ".codex/archived_sessions", .kind = .sessions },
    } },
    .{ .kind = .installers, .title = "Installers", .desc = "Disk images and packages left in Downloads", .note = "Download them again to install the apps again.", .doing = "Looking for installers in Downloads…", .color = 0xa2845e, .selected = false, .sources = &.{.{ .dir = "Downloads", .filter = .installer }} },
    .{ .kind = .logs, .title = "Logs", .desc = "Apps' logs and crash reports", .note = "Crash reports you have not sent go too.", .doing = "Measuring logs…", .color = 0xff9f0a, .sources = &.{.{ .dir = "Library/Logs" }} },
    .{ .kind = .temporary, .title = "Temporary Files", .desc = "Left by apps, unchanged for three days", .note = "Only files nothing changed for three days.", .doing = "Measuring temporary files…", .color = 0x30b0c7, .sources = &.{.{ .kind = .temp, .filter = .not_apple }} },
    .{ .kind = .trash, .title = "Trash", .desc = "Deleted for good", .note = "What is in the Trash is deleted for good.", .doing = "Measuring the Trash…", .color = 0x8e8e93, .forever = true, .selected = false, .sources = &.{.{ .dir = ".Trash" }} },
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
    measured: bool = false,

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

pub const Progress = struct {
    stop: std.atomic.Value(bool) = .init(false),
    measured: std.atomic.Value(u64) = .init(0),
};

pub fn gather(gpa: std.mem.Allocator, env: Env, lists: *[specs.len]Gathered) void {
    var progress: Progress = .{};
    for (lists, &specs) |*g, *spec| measureCategory(gpa, env, g, spec, &progress);
}

pub fn measureCategory(gpa: std.mem.Allocator, env: Env, g: *Gathered, spec: *const Spec, progress: *Progress) void {
    for (spec.sources) |src| listSource(gpa, env, g, src) catch {};
    var paths: std.ArrayList([:0]const u8) = .empty;
    defer paths.deinit(gpa);
    for (g.items.items) |it| paths.append(gpa, it.path) catch return;
    const out = gpa.alloc(walk.Size, paths.items.len) catch return;
    defer gpa.free(out);
    @memset(out, .{});
    var pool: walk.Pool = .{ .gpa = std.heap.smp_allocator, .paths = paths.items, .out = out, .stop = &progress.stop, .measured = &progress.measured };
    pool.run();
    for (g.items.items, out) |*it, size| it.size = size;
    const age: ?i64 = switch (spec.kind) {
        .temporary => stale_seconds,
        .agents => session_age,
        else => null,
    };
    if (age) |min_age| {
        var k: usize = 0;
        while (k < g.items.items.len) {
            const it = g.items.items[k];
            if (env.now - it.size.newest < min_age) {
                _ = progress.measured.fetchSub(it.size.bytes, .monotonic);
                it.free(gpa);
                _ = g.items.swapRemove(k);
            } else k += 1;
        }
    }
    std.mem.sort(Item, g.items.items, {}, struct {
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
    if (src.kind == .sessions) {
        const root = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ env.home, src.dir }, 0);
        defer gpa.free(root);
        if (access(root, 0) != 0) return;
        return listSessions(gpa, g, root, 0);
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

fn listSessions(gpa: std.mem.Allocator, g: *Gathered, dir_z: [:0]const u8, depth: usize) !void {
    const DT_DIR = 4;
    const DT_REG = 8;
    const dir = opendir(dir_z) orelse {
        g.denied = true;
        return;
    };
    defer _ = closedir(dir);
    while (readdir(dir)) |ent| {
        const name = ent.name[0..ent.namlen];
        if (!keep(.any, name)) continue;
        if (ent.kind == DT_DIR and depth < 4) {
            const sub = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ dir_z, name }, 0);
            defer gpa.free(sub);
            try listSessions(gpa, g, sub, depth + 1);
        } else if (ent.kind == DT_REG and std.mem.endsWith(u8, name, ".jsonl")) {
            const path = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ dir_z, name }, 0);
            g.items.append(gpa, .{ .path = path }) catch {
                gpa.free(path);
                return error.OutOfMemory;
            };
        }
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
    progress: Progress = .{},
    done: std.atomic.Value(usize) = .init(0),

    fn work(j: *Job) void {
        j.execute(true);
        objc.dispatchMain(j, finished);
    }

    fn execute(j: *Job, threaded: bool) void {
        if (j.clean) {
            j.result = perform(j.cl.gpa, j.actions, j.cl.trash_fn);
            return;
        }
        for (&j.lists, &specs, 0..) |*g, *spec, i| {
            if (j.progress.stop.load(.monotonic)) return;
            measureCategory(j.cl.gpa, j.env, g, spec, &j.progress);
            if (j.progress.stop.load(.monotonic)) return;
            j.done.store(i + 1, .release);
            if (threaded) objc.dispatchMain(j, stepped);
        }
    }

    fn stepped(ctx: ?*anyopaque) callconv(.c) void {
        const j: *Job = @ptrCast(@alignCast(ctx));
        j.cl.apply(j);
        j.cl.tell();
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
    applied: usize = 0,
    cancelled: bool = false,
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
            j.progress.stop.store(true, .monotonic);
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
        for (&cl.cats) |*cat| {
            cat.found.clear(cl.gpa);
            cat.measured = false;
        }
        cl.applied = 0;
        cl.cancelled = false;
        cl.scanned = false;
        cl.start(.{ .cl = cl, .env = cl.env(), .clean = false }, .scanning);
    }

    pub fn cancel(cl: *Cleaner) void {
        const j = cl.job orelse return;
        if (j.clean) return;
        j.progress.stop.store(true, .monotonic);
        cl.cancelled = true;
    }

    pub fn step(cl: *const Cleaner) ?*const Spec {
        const j = cl.job orelse return null;
        if (j.clean) return null;
        return &specs[@min(cl.applied, specs.len - 1)];
    }

    pub fn found(cl: *const Cleaner) u64 {
        const j = cl.job orelse return cl.total();
        if (j.clean) return cl.total();
        return @max(j.progress.measured.load(.monotonic), cl.total());
    }

    fn apply(cl: *Cleaner, j: *Job) void {
        const done = j.done.load(.acquire);
        while (cl.applied < done) : (cl.applied += 1) {
            const c = &cl.cats[cl.applied];
            std.mem.swap(Gathered, &c.found, &j.lists[cl.applied]);
            c.measured = true;
        }
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
            j.execute(false);
            return cl.complete(j);
        }
        j.thread = std.Thread.spawn(.{}, Job.work, .{j}) catch {
            j.execute(false);
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
        cl.apply(j);
        cl.scan_ms = (clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) -| cl.started) / std.time.ns_per_ms;
        if (cl.applied == specs.len) {
            cl.scanned = true;
            cl.scanned_at = j.env.now;
        }
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
