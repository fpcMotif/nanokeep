const std = @import("std");
const nanoui = @import("nanoui");
const App = @import("app.zig").App;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn clock_gettime_nsec_np(clock: c_int) u64;

fn seconds() f64 {
    return @as(f64, @floatFromInt(clock_gettime_nsec_np(4))) / 1e9;
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
    a.listen();
    a.clock = seconds;
    a.cleaner.scan();
    a.inventory.load();
    a.orderApps();
    a.window = try app.newWindow(.{
        .title = "nanokeep",
        .width = 1100,
        .height = 720,
        .min_width = 860,
        .min_height = 520,
        .content = .{ .view = .init(&a, @import("view.zig").view) },
    });
    try app.run();
}
