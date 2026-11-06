const std = @import("std");
const nanoui = @import("nanoui");
const App = @import("app.zig").App;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn clock_gettime_nsec_np(clock: c_int) u64;

pub fn seconds() f64 {
    return @as(f64, @floatFromInt(clock_gettime_nsec_np(4))) / 1e9;
}

pub fn start(a: *App, app: *nanoui.App) !*nanoui.Window {
    a.listen();
    a.clock = seconds;
    a.machine.read();
    a.machine.lookUpName();
    a.usage.load();
    nanoui.objc.dispatchMain(a, loadApps);
    nanoui.objc.dispatchMain(a, heartbeat);
    const w = try app.newWindow(.{
        .title = "nanokeep",
        .width = 1100,
        .height = 720,
        .min_width = 860,
        .min_height = 520,
        .content = .{ .view = .init(a, @import("view.zig").view) },
    });
    a.window = w;
    return w;
}

fn loadApps(ctx: ?*anyopaque) callconv(.c) void {
    const a: *App = @ptrCast(@alignCast(ctx));
    a.inventory.load();
}

fn heartbeat(ctx: ?*anyopaque) callconv(.c) void {
    const a: *App = @ptrCast(@alignCast(ctx));
    a.heartbeat(seconds());
    nanoui.objc.dispatchAfter(@as(u64, @intFromFloat(@import("app.zig").hidden_interval)) * std.time.ns_per_s, a, heartbeat);
}

pub fn main(init: std.process.Init) !void {
    const home: [:0]const u8 = if (getenv("HOME")) |h| std.mem.span(h) else "/";
    const tmpdir: []const u8 = if (getenv("TMPDIR")) |t| std.mem.span(t) else "";
    const user_apps = try std.fmt.allocPrint(init.gpa, "{s}/Applications", .{home});
    defer init.gpa.free(user_apps);
    const app_dirs = [_][]const u8{ "/Applications", user_apps };
    const app = try nanoui.App.create(init, .{ .name = "nanokeep" });
    defer app.destroy();
    var a: App = .init(init.gpa, home, tmpdir, &app_dirs);
    defer a.deinit();
    _ = try start(&a, app);
    try app.run();
}
