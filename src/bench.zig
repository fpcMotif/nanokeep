const std = @import("std");
const nanoui = @import("nanoui");
const measure = @import("measure.zig");
const run = @import("run.zig");
const App = @import("app.zig").App;
const Page = @import("app.zig").Page;
const objc = nanoui.objc;
const start = @import("main.zig").start;
const seconds = @import("main.zig").seconds;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn getpid() c_int;
extern "c" fn system(cmd: [*:0]const u8) c_int;
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fwrite(buf: [*]const u8, size: usize, n: usize, f: *anyopaque) usize;
extern "c" fn fclose(f: *anyopaque) c_int;
extern "c" fn IOPMAssertionCreateWithName(kind: objc.Object, level: u32, name: objc.Object, id: *u32) c_int;
extern "c" fn IOPMAssertionDeclareUserActivity(name: objc.Object, kind: c_int, id: *u32) c_int;
extern "c" fn IOPMAssertionRelease(id: u32) c_int;

// Tightened after each win; `target` is what issue #1 asks for.
const budgets = [_]measure.Budget{
    .{ .name = "cold_start_ms", .budget = 500, .target = 35 },
    .{ .name = "page_switch_p50_ms", .budget = 9, .target = 0.28 },
    .{ .name = "page_switch_p95_ms", .budget = 18, .target = 0.28 },
    .{ .name = "hover_p50_ms", .budget = 9, .target = 0.28 },
    .{ .name = "hover_p95_ms", .budget = 17, .target = 0.29 },
    .{ .name = "scroll_p50_ms", .budget = 9, .target = 0.28 },
    .{ .name = "scroll_p95_ms", .budget = 17, .target = 0.28 },
    .{ .name = "page_switch_cpu_p50_ms", .budget = 2.1, .target = 0.28 },
    .{ .name = "page_switch_cpu_p95_ms", .budget = 10.7, .target = 0.28 },
    .{ .name = "hover_cpu_p50_ms", .budget = 0.33, .target = 0.28 },
    .{ .name = "hover_cpu_p95_ms", .budget = 0.5, .target = 0.29 },
    .{ .name = "scroll_cpu_p50_ms", .budget = 0.45, .target = 0.28 },
    .{ .name = "scroll_cpu_p95_ms", .budget = 1.8, .target = 0.28 },
    .{ .name = "hover_rebuilds", .budget = 0, .target = 0 },
    .{ .name = "sample_p50_ms", .budget = 6, .target = 1.36 },
    .{ .name = "sample_p95_ms", .budget = 8, .target = 1.65 },
    .{ .name = "idle_mb", .budget = 300, .target = 40 },
    .{ .name = "scan_ms", .budget = 100, .target = 40 },
    .{ .name = "scan_peak_mb", .budget = 303, .target = 60 },
    .{ .name = "repeat_scan_ms", .budget = 61, .target = 1.4 },
    .{ .name = "hidden_mb", .budget = 88, .target = 20 },
    .{ .name = "show_ms", .budget = 375, .target = 2.9 },
    .{ .name = "cycle_growth_mb", .budget = 3, .target = 2 },
    .{ .name = "peak_mb", .budget = 327, .target = 60 },
    .{ .name = "leaks", .budget = 0, .target = 0 },
};

const pages = std.enums.values(Page);
const cycles = 20;
const deep_levels = 400;
const occlusion_visible = 2;
const assertion_on = 255;
const can_join_all_spaces = 1;

extern "c" fn clock_gettime_nsec_np(clock: c_int) u64;
const CLOCK_THREAD_CPUTIME_ID = 16;

fn threadCpu() f64 {
    return @as(f64, @floatFromInt(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID))) / 1e9;
}

fn ms(since: f64) f64 {
    return (seconds() - since) * 1000;
}

fn mb(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1 << 20);
}

extern "c" const NSDefaultRunLoopMode: objc.Object;

// What [NSApp run] does once: AppKit events (occlusion, show) need dispatching.
fn pumpOnce(timeout: f64) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    const until = objc.msg(objc.Object, objc.class("NSDate"), "dateWithTimeIntervalSinceNow:", .{timeout});
    const ev = objc.msg(?objc.Object, nsapp, "nextEventMatchingMask:untilDate:inMode:dequeue:", .{ @as(objc.NSUInteger, std.math.maxInt(objc.NSUInteger)), until, NSDefaultRunLoopMode, objc.YES });
    if (ev) |e| objc.msg(void, nsapp, "sendEvent:", .{e});
}

fn occluded(err: anyerror) anyerror {
    std.debug.print("the bench window must stay uncovered on the active Space while the bench runs\n", .{});
    return err;
}

fn pump(secs: f64) void {
    const end = seconds() + secs;
    while (seconds() < end) pumpOnce(@min(0.05, end - seconds()));
}

const Bench = struct {
    gpa: std.mem.Allocator,
    a: *App,
    window: *nanoui.Window,
    metrics: std.ArrayList(measure.Metric) = .empty,

    fn surface(b: *Bench) @TypeOf(b.window.surface.?) {
        return b.window.surface.?;
    }

    fn put(b: *Bench, name: []const u8, value: f64) !void {
        try b.metrics.append(b.gpa, .{ .name = name, .value = value });
    }

    fn putStats(b: *Bench, comptime name: []const u8, samples: []f64) !void {
        const s = measure.Stats.of(samples);
        try b.put(name ++ "_p50_ms", s.p50);
        try b.put(name ++ "_p95_ms", s.p95);
    }

    fn visible(b: *Bench) bool {
        return objc.msg(objc.NSUInteger, b.window.nswindow, "occlusionState", .{}) & occlusion_visible != 0;
    }

    const Timed = struct { wall: f64, cpu: f64 };

    fn timedFrame(b: *Bench) !Timed {
        const covered = seconds();
        while (true) {
            const t = seconds();
            const cpu = threadCpu();
            b.surface().frame();
            const took: Timed = .{ .wall = ms(t), .cpu = (threadCpu() - cpu) * 1000 };
            pumpOnce(0);
            if (!b.surface().pending) return took;
            if (seconds() - covered > 30) return occluded(error.WindowOccluded);
            pump(0.2);
        }
    }

    fn putFrames(b: *Bench, comptime name: []const u8, frames: []Timed) !void {
        var wall: [256]f64 = undefined;
        var cpu: [256]f64 = undefined;
        for (frames, 0..) |f, i| {
            wall[i] = f.wall;
            cpu[i] = f.cpu;
        }
        try b.putStats(name, wall[0..frames.len]);
        try b.putStats(name ++ "_cpu", cpu[0..frames.len]);
    }

    fn pageSwitches(b: *Bench) !void {
        var frames: [pages.len * 3]Timed = undefined;
        var n: usize = 0;
        for (0..3) |_| for (pages) |p| {
            b.a.page = p;
            frames[n] = try b.timedFrame();
            n += 1;
        };
        try b.putFrames("page_switch", frames[0..n]);
    }

    fn hovers(b: *Bench) !void {
        b.a.page = .processes;
        _ = try b.timedFrame();
        const ctx = &b.surface().ctx;
        var frames: [2 * 70]Timed = undefined;
        for (&frames, 0..) |*f, i| {
            const row: f32 = @floatFromInt(i % 70);
            ctx.input.mouse = .{ .x = 640, .y = 150 + row * 8 };
            ctx.updateHot();
            f.* = try b.timedFrame();
        }
        try b.putFrames("hover", &frames);
    }

    fn scrolls(b: *Bench) !void {
        b.a.page = .processes;
        _ = try b.timedFrame();
        const ctx = &b.surface().ctx;
        ctx.input.mouse = .{ .x = 640, .y = 420 };
        ctx.updateHot();
        var frames: [60]Timed = undefined;
        for (&frames, 0..) |*f, i| {
            const dy: f32 = if (i < 30) -40 else 40;
            if (!ctx.applyScroll(dy)) ctx.input.scroll = .{ .y = dy };
            f.* = try b.timedFrame();
        }
        try b.putFrames("scroll", &frames);
    }

    fn sampling(b: *Bench) !void {
        var times: [20]f64 = undefined;
        for (&times) |*s| {
            b.a.last = -1e9;
            const t = seconds();
            _ = b.a.tick(t);
            s.* = ms(t);
        }
        try b.putStats("sample", &times);
    }

    fn scan(b: *Bench) !f64 {
        b.a.page = .cleanup;
        const t = seconds();
        b.a.cleaner.scan();
        while (b.a.cleaner.job != null) {
            if (seconds() - t > 300) return error.ScanTimedOut;
            pumpOnce(0.01);
        }
        if (!b.a.cleaner.scanned) return error.ScanIncomplete;
        return ms(t);
    }

    fn hideAndShow(b: *Bench) !void {
        b.window.hide();
        pump(3);
        b.surface().frame();
        if (!b.surface().pending) return error.FrameDrawnWhileHidden;
        try b.put("hidden_mb", mb(measure.footprint().now));
        const before = b.surface().ctx.frame;
        const t = seconds();
        b.window.focus();
        while (b.surface().ctx.frame == before) {
            if (seconds() - t > 5) {
                std.debug.print("no frame 5 s after show: occlusion visible={} pending={} ordered in={}\n", .{ b.visible(), b.surface().pending, b.window.isVisible() });
                return b.put("show_ms", std.math.inf(f64));
            }
            pumpOnce(0.005);
        }
        try b.put("show_ms", ms(t));
    }

    fn cycle(b: *Bench) !void {
        _ = try b.scan();
        for (pages) |p| {
            b.a.page = p;
            _ = try b.timedFrame();
        }
        for (0..3) |_| {
            b.a.last = -1e9;
            _ = b.a.tick(seconds());
        }
    }

    fn leaks(b: *Bench) !void {
        var pid: [16]u8 = undefined;
        const out = try run.capture(b.gpa, &.{ "/usr/bin/leaks", try std.fmt.bufPrint(&pid, "{d}", .{getpid()}) });
        defer out.deinit(b.gpa);
        const count = measure.parseLeaks(out.out);
        try b.put("leaks", if (count) |c| @floatFromInt(c) else std.math.inf(f64));
    }
};

fn makeFixture(root: []const u8) !void {
    var cmd: [2048]u8 = undefined;
    const script = try std.fmt.bufPrintSentinel(&cmd,
        \\set -e; F='{s}'; rm -rf "$F"; mkdir -p "$F/tmp" "$F/home/Library/Caches" "$F/home/Library/Logs" "$F/home/Library/Developer/Xcode/DerivedData"
        \\cd "$F/home/Library/Caches"
        \\for a in $(seq 1 120); do mkdir -p com.bench.app$a/data; cd com.bench.app$a/data; for f in $(seq 1 250); do printf x > f$f; done; cd ../..; done
        \\mkdir com.bench.deep; cd com.bench.deep; for i in $(seq 1 {d}); do mkdir d; cd d; printf x > f; done
        \\cd "$F/home/Library/Logs"; for f in $(seq 1 200); do printf x > log$f.log; done
        \\cd "$F/home/Library/Developer/Xcode/DerivedData"; for p in $(seq 1 10); do mkdir -p P$p/Build/Intermediates/o; dd if=/dev/zero of=P$p/Build/Intermediates/o/big bs=65536 count=16 2>/dev/null; done
    , .{ root, deep_levels }, 0);
    if (system(script) != 0) return error.Fixture;
}

fn writeJson(gpa: std.mem.Allocator, metrics: []const measure.Metric) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{\n  \"metrics\": {\n");
    for (metrics, 0..) |m, i| {
        const v = measure.judge(m, &budgets);
        try out.print(gpa, "    \"{s}\": {{ \"value\": ", .{m.name});
        if (std.math.isFinite(m.value)) try out.print(gpa, "{d:.2}", .{m.value}) else try out.appendSlice(gpa, "null");
        if (v.budget) |bud| try out.print(gpa, ", \"budget\": {d}, \"target\": {d}", .{ bud.budget, bud.target });
        try out.print(gpa, ", \"ok\": {} }}{s}\n", .{ v.ok(), if (i + 1 < metrics.len) "," else "" });
    }
    try out.appendSlice(gpa, "  }\n}\n");
    return out.toOwnedSlice(gpa);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const home: [:0]const u8 = if (getenv("HOME")) |h| std.mem.span(h) else "/";
    const user_apps = try std.fmt.allocPrint(gpa, "{s}/Applications", .{home});
    defer gpa.free(user_apps);
    const app_dirs = [_][]const u8{ "/Applications", user_apps };
    const app = try nanoui.App.create(init, .{ .name = "nanokeep-bench" });
    defer app.destroy();
    var a: App = .init(gpa, home, "", &app_dirs);
    defer a.deinit();
    const window = try start(&a, app);
    const cold = measure.sinceStart();
    // A sleeping display occludes every window, and nanokeep then draws nothing.
    var woke: u32 = 0;
    var awake: u32 = 0;
    {
        const pool = objc.Pool.push();
        defer pool.pop();
        const why = objc.nsString("nanokeep bench");
        _ = IOPMAssertionDeclareUserActivity(why, 0, &woke);
        _ = IOPMAssertionCreateWithName(objc.nsString("PreventUserIdleDisplaySleep"), assertion_on, why, &awake);
    }
    defer _ = IOPMAssertionRelease(woke);
    defer _ = IOPMAssertionRelease(awake);
    window.setAlwaysOnTop(true);
    // Shown again after hiding, the window must land on the Space in front, not the one it left.
    objc.msg(void, window.nswindow, "setCollectionBehavior:", .{@as(objc.NSUInteger, can_join_all_spaces)});
    objc.msg(void, app.nsapp, "finishLaunching", .{});
    objc.msg(void, app.nsapp, "activateIgnoringOtherApps:", .{objc.YES});

    var b: Bench = .{ .gpa = gpa, .a = &a, .window = window };
    defer b.metrics.deinit(gpa);
    try b.put("cold_start_ms", cold);

    const tmp = std.mem.trimEnd(u8, if (getenv("TMPDIR")) |t| std.mem.span(t) else "/tmp", "/");
    if (std.mem.indexOfScalar(u8, tmp, '\'') != null) return error.QuoteInTmpdir;
    const root = try std.fmt.allocPrint(gpa, "{s}/nanokeep-bench-{d}", .{ tmp, getpid() });
    defer gpa.free(root);
    defer removeFixture(root);
    try makeFixture(root);
    const fixture_home = try std.fmt.allocPrint(gpa, "{s}/home", .{root});
    defer gpa.free(fixture_home);
    const fixture_tmp = try std.fmt.allocPrint(gpa, "{s}/tmp", .{root});
    defer gpa.free(fixture_tmp);
    a.cleaner.deinit();
    a.cleaner = .init(gpa, fixture_home, fixture_tmp);
    a.listen();

    const shown = seconds();
    while (!b.visible()) {
        if (seconds() - shown > 10) return occluded(error.WindowNotVisible);
        pumpOnce(0.05);
    }
    pump(1);
    try b.pageSwitches();
    a.page = .processes;
    _ = try b.timedFrame();
    const rebuilt = a.rebuilds;
    const sampled = a.sampler.samples;
    const inventoried = a.apps_version;
    try b.hovers();
    try b.scrolls();
    const explained = (a.sampler.samples - sampled) + (a.apps_version - inventoried);
    try b.put("hover_rebuilds", @floatFromInt((a.rebuilds - rebuilt) -| explained));
    try b.sampling();
    a.page = .overview;
    pump(6);
    const idle = measure.footprint().now;
    try b.put("idle_mb", mb(idle));

    measure.resetPeak();
    try b.put("scan_ms", try b.scan());
    try b.put("scan_peak_mb", mb(measure.footprint().interval_peak));
    try b.put("repeat_scan_ms", try b.scan());
    a.page = .overview;

    for (0..cycles) |_| try b.cycle();
    a.page = .overview;
    pump(6);
    try b.put("cycle_growth_mb", mb(measure.footprint().now) - mb(idle));
    try b.hideAndShow();
    try b.put("peak_mb", mb(measure.footprint().peak));
    try b.leaks();

    const json = try writeJson(gpa, b.metrics.items);
    defer gpa.free(json);
    std.debug.print("{s}", .{json});
    for (try init.minimal.args.toSlice(init.arena.allocator())) |arg| {
        if (!std.mem.startsWith(u8, arg, "--out=")) continue;
        const path = try init.arena.allocator().dupeSentinel(u8, arg["--out=".len..], 0);
        const f = fopen(path, "w") orelse return error.Write;
        _ = fwrite(json.ptr, 1, json.len, f);
        _ = fclose(f);
    }
    var failed = false;
    for (b.metrics.items) |m| {
        const v = measure.judge(m, &budgets);
        if (v.ok()) continue;
        failed = true;
        if (v.budget) |bud| std.debug.print("over budget: {s} = {d:.2} > {d}\n", .{ m.name, m.value, bud.budget }) else std.debug.print("no budget: {s} = {d:.2}\n", .{ m.name, m.value });
    }
    if (failed) return error.OverBudget;
}

fn removeFixture(root: []const u8) void {
    var cmd: [512]u8 = undefined;
    _ = system(std.fmt.bufPrintSentinel(&cmd, "rm -rf '{s}'", .{root}, 0) catch return);
}
