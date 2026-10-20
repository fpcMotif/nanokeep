const std = @import("std");
const nanoui = @import("nanoui");
const procs = @import("procs.zig");
const groups = @import("groups.zig");
const cleaner = @import("cleaner.zig");
const apps = @import("apps.zig");
const fda = @import("fda.zig");

extern "c" fn time(t: ?*i64) i64;

pub const interval = 2.0;

pub const Page = enum { overview, processes, apps, cleanup };

pub const AppSort = enum { name, version, size, kind, opened, source };

pub const Selection = struct { group: u64, pid: ?i32 = null };

pub const App = struct {
    gpa: std.mem.Allocator,
    sampler: procs.Sampler,
    cleaner: cleaner.Cleaner,
    inventory: apps.Inventory,
    table: groups.Table,
    toaster: nanoui.kit.Toaster,
    page: Page = .overview,
    live: bool = true,
    last: f64 = -1e9,
    show: usize = 2,
    sort: groups.Sort = .memory,
    reversed: bool = false,
    query: nanoui.ui.TextBuffer = .{},
    expanded_groups: std.AutoHashMapUnmanaged(u64, void) = .empty,
    selected: ?Selection = null,
    confirm_quit: bool = false,
    force: bool = false,
    confirm_clean: bool = false,
    expanded: [cleaner.specs.len]bool = @splat(false),
    app_query: nanoui.ui.TextBuffer = .{},
    app_sort: AppSort = .name,
    app_reversed: bool = false,
    app_rows: std.ArrayList(u32) = .empty,
    app_selected: ?usize = null,
    confirm_uninstall: bool = false,
    window: ?*nanoui.Window = null,
    clock: ?*const fn () f64 = null,
    send: *const fn (c_int, c_int) callconv(.c) c_int = procs.sendKill,
    trash_app: cleaner.TrashFn = trashPath,
    guide: ?fda.Guide = null,
    access_fn: *const fn (*App) void = beginGuide,

    pub fn init(gpa: std.mem.Allocator, home: [:0]const u8, tmpdir: []const u8, app_dirs: []const []const u8) App {
        return .{
            .gpa = gpa,
            .sampler = .init(gpa, home),
            .cleaner = .init(gpa, home, tmpdir),
            .inventory = .{ .gpa = gpa, .dirs = app_dirs },
            .table = .{ .gpa = gpa },
            .toaster = .{ .gpa = gpa },
        };
    }

    pub fn listen(a: *App) void {
        a.cleaner.on_change = .{ .ctx = a, .func = changed };
        a.inventory.on_change = .{ .ctx = a, .func = changed };
    }

    pub fn deinit(a: *App) void {
        if (a.guide) |*g| g.deinit();
        a.app_rows.deinit(a.gpa);
        a.expanded_groups.deinit(a.gpa);
        a.table.deinit();
        a.toaster.deinit();
        a.inventory.deinit();
        a.cleaner.deinit();
        a.sampler.deinit();
    }

    pub fn now(_: *const App) i64 {
        return time(null);
    }

    fn changed(ctx: *anyopaque) void {
        const a: *App = @ptrCast(@alignCast(ctx));
        a.reportClean();
        if (a.window) |w| w.redraw();
    }

    pub fn reportClean(a: *App) void {
        const r = a.cleaner.last orelse return;
        a.cleaner.last = null;
        var b1: [32]u8 = undefined;
        var b2: [32]u8 = undefined;
        var msg: [160]u8 = undefined;
        const text = if (r.deleted > 0)
            std.fmt.bufPrint(&msg, "Moved {s} to the Trash, removed {s} for good.", .{ procs.bytes(&b1, r.moved), procs.bytes(&b2, r.deleted) }) catch ""
        else
            std.fmt.bufPrint(&msg, "Moved {s} to the Trash. Empty the Trash to free it.", .{procs.bytes(&b1, r.moved)}) catch "";
        a.toaster.push(.{ .status = if (r.failed > 0) .warning else .success, .title = if (r.failed > 0) "Cleaned, with some left" else "Cleaned", .message = text });
    }

    pub fn tick(a: *App, t: f64) f32 {
        if (a.live and t - a.last >= interval) {
            a.sampler.sample(t);
            a.last = t;
            if (a.sampler.samples == 1) a.last = t - interval + 0.6;
        }
        a.order();
        return @floatCast(@max(0.05, interval - (t - a.last)));
    }

    pub fn order(a: *App) void {
        a.table.build(a.sampler.procs.items, .{
            .show = @enumFromInt(a.show),
            .sort = a.sort,
            .reversed = a.reversed,
            .query = std.mem.trim(u8, a.query.text(), " "),
            .uid = a.sampler.uid,
        }, &a.expanded_groups) catch {};
        a.orderApps();
    }

    pub fn sortBy(a: *App, s: groups.Sort) void {
        if (a.sort == s) a.reversed = !a.reversed else {
            a.sort = s;
            a.reversed = false;
        }
    }

    pub fn toggleGroup(a: *App, key: u64) void {
        if (a.expanded_groups.remove(key)) return;
        a.expanded_groups.put(a.gpa, key, {}) catch {};
    }

    pub fn orderApps(a: *App) void {
        a.app_rows.clearRetainingCapacity();
        const q = std.mem.trim(u8, a.app_query.text(), " ");
        for (a.inventory.apps.items, 0..) |info, i| {
            if (q.len > 0 and std.ascii.findIgnoreCase(info.name, q) == null) continue;
            a.app_rows.append(a.gpa, @intCast(i)) catch return;
        }
        const Ctx = struct {
            list: []const apps.AppInfo,
            sort: AppSort,
            reversed: bool,
            fn lt(c: @This(), x: u32, y: u32) bool {
                const p = c.list[x];
                const q2 = c.list[y];
                const ord: std.math.Order = switch (c.sort) {
                    .name => std.ascii.orderIgnoreCase(p.name, q2.name),
                    .version => std.mem.order(u8, p.version, q2.version),
                    .size => std.math.order(q2.size.bytes, p.size.bytes),
                    .kind => std.math.order(@intFromEnum(p.kind), @intFromEnum(q2.kind)),
                    .opened => std.math.order(q2.last_opened, p.last_opened),
                    .source => std.math.order(@intFromBool(q2.app_store), @intFromBool(p.app_store)),
                };
                if (ord == .eq) return std.ascii.orderIgnoreCase(p.name, q2.name) == .lt;
                return if (c.reversed) ord == .gt else ord == .lt;
            }
        };
        std.mem.sort(u32, a.app_rows.items, Ctx{ .list = a.inventory.apps.items, .sort = a.app_sort, .reversed = a.app_reversed }, Ctx.lt);
    }

    pub fn sortAppsBy(a: *App, s: AppSort) void {
        if (a.app_sort == s) a.app_reversed = !a.app_reversed else {
            a.app_sort = s;
            a.app_reversed = false;
        }
        a.orderApps();
    }

    pub fn quitTargets(a: *App, out: *std.ArrayList(i32)) void {
        const sel = a.selected orelse return;
        if (sel.pid) |pid| {
            out.append(a.gpa, pid) catch {};
            return;
        }
        const g = a.table.group(sel.group) orelse return;
        a.table.pidsOf(g, a.sampler.procs.items, out) catch {};
    }

    pub fn selectionName(a: *App) []const u8 {
        const sel = a.selected orelse return "the process";
        if (sel.pid) |pid| if (a.sampler.find(pid)) |p| return p.name;
        if (a.table.group(sel.group)) |g| return g.name;
        return "the process";
    }

    pub fn quitSelected(a: *App) void {
        var pids: std.ArrayList(i32) = .empty;
        defer pids.deinit(a.gpa);
        a.quitTargets(&pids);
        if (pids.items.len == 0) return;
        const name = a.selectionName();
        var failed: usize = 0;
        var why: []const u8 = "";
        for (pids.items) |pid| a.sampler.quit(pid, if (a.force) .force else .quit, a.send) catch |err| {
            failed += 1;
            why = switch (err) {
                error.NotYours => "It belongs to another user.",
                error.Itself => "nanokeep can't quit itself here.",
                error.Failed => "The process didn't take the signal.",
            };
        };
        var msg: [160]u8 = undefined;
        if (failed > 0) {
            const title = if (pids.items.len == 1) std.fmt.bufPrint(&msg, "Couldn't quit {s}", .{name}) else std.fmt.bufPrint(&msg, "Couldn't quit {d} of {d}", .{ failed, pids.items.len });
            a.toaster.push(.{ .status = .danger, .title = title catch "Couldn't quit", .message = why });
        } else {
            a.toaster.push(.{ .status = .success, .title = std.fmt.bufPrint(&msg, "{s} {s}", .{ if (a.force) "Force quit" else "Asked to quit", name }) catch "Quit" });
        }
        a.selected = null;
    }

    pub fn requestAccess(a: *App) void {
        a.access_fn(a);
    }

    fn beginGuide(a: *App) void {
        if (a.guide == null) a.guide = .{ .home = a.sampler.home, .on_granted = .{ .ctx = a, .func = accessGranted } };
        a.guide.?.begin();
    }

    fn accessGranted(ctx: *anyopaque) void {
        const a: *App = @ptrCast(@alignCast(ctx));
        a.toaster.push(.{ .status = .success, .title = "Full Disk Access is on", .message = "Looking through Installers and the Trash now." });
        a.cleaner.scan();
        if (a.window) |w| w.redraw();
    }

    pub fn selectedApp(a: *App) ?*apps.AppInfo {
        const i = a.app_selected orelse return null;
        if (i >= a.inventory.apps.items.len) return null;
        return &a.inventory.apps.items[i];
    }

    pub fn appRunning(a: *const App, info: *const apps.AppInfo) bool {
        return a.sampler.running(info.path);
    }

    pub fn uninstallSelected(a: *App) void {
        const i = a.app_selected orelse return;
        const info = a.selectedApp() orelse return;
        var msg: [160]u8 = undefined;
        if (a.appRunning(info)) {
            a.toaster.push(.{ .status = .warning, .title = std.fmt.bufPrint(&msg, "{s} is open", .{info.name}) catch "It's open", .message = "Quit it first, then uninstall it." });
            return;
        }
        if (!a.trash_app(info.path)) {
            a.toaster.push(.{ .status = .danger, .title = std.fmt.bufPrint(&msg, "Couldn't move {s} to the Trash", .{info.name}) catch "Couldn't uninstall", .message = "macOS may ask an administrator's password for apps it installed." });
            return;
        }
        a.toaster.push(.{ .status = .success, .title = std.fmt.bufPrint(&msg, "Moved {s} to the Trash", .{info.name}) catch "Uninstalled", .message = "Its settings and data stay. You can put it back from the Trash." });
        a.app_selected = null;
        a.inventory.remove(i);
        a.orderApps();
    }
};

fn trashPath(path: []const u8) bool {
    return nanoui.shell.trash(path);
}
