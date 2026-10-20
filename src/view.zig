const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const procs = @import("procs.zig");
const app_mod = @import("app.zig");
const table = @import("view_table.zig");
const App = app_mod.App;

pub fn size(c: *ui.Context, n: u64) []const u8 {
    var b: [32]u8 = undefined;
    return c.print("{s}", .{procs.bytes(&b, n)});
}

pub fn ago(c: *ui.Context, now: i64, then: i64) []const u8 {
    var b: [32]u8 = undefined;
    return c.print("{s}", .{procs.ago(&b, now, then)});
}

pub fn view(a: *App, c: *ui.Context) void {
    c.frameIn(a.tick(if (a.clock) |f| f() else c.time));
    keys(c, a);
    const th = c.theme;
    {
        const root = ui.div(c).row().sizeFull().bg(th.background);
        defer root.end();
        sidebar(c, a);
        _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .fill, .background = th.border }, .none, null);
        const main = ui.div(c).column().grow().w(0).hFull().clip();
        defer main.end();
        switch (a.page) {
            .overview => overview(c, a),
            .processes => @import("view_procs.zig").page(c, a),
            .apps => @import("view_apps.zig").page(c, a),
            .cleanup => @import("view_clean.zig").page(c, a),
        }
    }
    @import("view_procs.zig").dialog(c, a);
    @import("view_apps.zig").dialog(c, a);
    @import("view_clean.zig").dialog(c, a);
    a.toaster.view(c);
}

fn keys(c: *ui.Context, a: *App) void {
    const pages = std.enums.values(app_mod.Page);
    for (pages, 0..) |p, i| if (c.shortcut(.{ .key = @as(u21, '1') + @as(u21, @intCast(i)), .cmd = true })) {
        a.page = p;
    };
    if (c.shortcut(.{ .key = 'r', .cmd = true })) a.cleaner.scan();
}

fn sidebar(c: *ui.Context, a: *App) void {
    const th = c.theme;
    const side = ui.div(c).column().w(200).hFull().p(12).gap(3).bg(th.surface);
    defer side.end();
    ui.text(c, "nanokeep", .{ .size = 17, .weight = .bold });
    ui.text(c, "Keep your Mac tidy", .{ .size = 11.5, .color = th.muted });
    _ = c.leaf(.{ .height = .{ .px = 10 } }, .none, null);
    navItem(c, a, .overview, "square.grid.2x2", 0x8e8e93, "Overview", "");
    navItem(c, a, .processes, "list.bullet.rectangle", 0x8e8e93, "Processes", c.print("{d}", .{a.sampler.procs.items.len}));
    sectionLabel(c, "System");
    navItem(c, a, .apps, "square.grid.3x3.fill", 0x5e5ce6, "Apps", if (a.inventory.loaded) c.print("{d}", .{a.inventory.apps.items.len}) else "");
    navItem(c, a, .cleanup, "sparkles", 0xff9f0a, "Cleanup", if (a.cleaner.scanned) size(c, a.cleaner.total()) else "");
}

fn sectionLabel(c: *ui.Context, s: []const u8) void {
    const d = ui.div(c).row().wFull().px(8).pt(12).pb(4);
    defer d.end();
    ui.text(c, s, .{ .size = 11, .weight = .semibold, .color = c.theme.muted });
}

fn navItem(c: *ui.Context, a: *App, page: app_mod.Page, icon: []const u8, tint: u24, title: []const u8, figure: []const u8) void {
    const th = c.theme;
    const on = a.page == page;
    ui.key(c, title);
    var d = ui.div(c).row().wFull().h(30).px(8).gap(8).itemsCenter().rounded(7).control();
    d = if (on) d.bg(th.accent) else d.hover(th.surface_hover);
    defer d.end();
    if (d.clicked()) {
        a.page = page;
        c.changed = true;
    }
    {
        const badge = ui.div(c).row().w(20).h(20).center().rounded(5).bg(ui.Color.hex(tint));
        defer badge.end();
        ui.icon(c, icon, .{ .size = 11, .color = .white });
    }
    ui.text(c, title, .{ .size = 13, .color = if (on) th.accent_text else th.text });
    ui.spacer(c);
    if (figure.len > 0) ui.text(c, figure, .{ .size = 11, .mono = true, .color = if (on) th.accent_text else th.muted });
}

pub fn header(c: *ui.Context, title: []const u8, sub: []const u8) ui.Div {
    const h = ui.div(c).row().wFull().h(60).px(20).gap(10).itemsCenter();
    {
        const t = ui.div(c).column().gap(2).grow().w(0).clip();
        defer t.end();
        ui.text(c, title, .{ .size = 17, .weight = .bold });
        if (sub.len > 0) ui.text(c, sub, .{ .size = 11.5, .color = c.theme.muted });
    }
    return h;
}

fn gauge(c: *ui.Context, title: []const u8, value: f32, big: []const u8, small: []const u8, color: ui.Color) void {
    const th = c.theme;
    const card = ui.div(c).column().grow().w(0).p(16).gap(10).rounded(12).bg(th.surface).border(th.border);
    defer card.end();
    ui.text(c, title, .{ .size = 12, .weight = .semibold, .color = color });
    {
        const r = ui.div(c).row().gap(14).itemsCenter();
        defer r.end();
        kit.ring(c, value, .{ .size = 54, .color = color });
        const t = ui.div(c).column().gap(2);
        defer t.end();
        ui.text(c, big, .{ .size = 22, .weight = .bold, .mono = true });
        ui.text(c, small, .{ .size = 11.5, .color = th.muted });
    }
}

fn overview(c: *ui.Context, a: *App) void {
    const th = c.theme;
    const sy = a.sampler.system;
    var b: [32]u8 = undefined;
    const h = header(c, "Overview", "This Mac, sampled every two seconds");
    h.end();
    const body = ui.div(c).column().wFull().grow().scrollY().px(20).pb(20).gap(14);
    defer body.end();
    {
        const r = ui.div(c).row().wFull().gap(14);
        defer r.end();
        gauge(c, "CPU", sy.cpu / 100, c.print("{d:.0}%", .{sy.cpu}), "busy, all cores", .hex(0x0a84ff));
        const mem = if (sy.mem_total > 0) @as(f32, @floatFromInt(sy.mem_used)) / @as(f32, @floatFromInt(sy.mem_total)) else 0;
        gauge(c, "Memory", mem, size(c, sy.mem_used), c.print("in use of {s}", .{procs.bytes(&b, sy.mem_total)}), .hex(0x30d158));
        const used = if (sy.disk_total > 0) 1 - @as(f32, @floatFromInt(sy.disk_free)) / @as(f32, @floatFromInt(sy.disk_total)) else 0;
        gauge(c, "Disk", used, size(c, sy.disk_free), c.print("free of {s}", .{procs.bytes(&b, sy.disk_total)}), .hex(0xff9f0a));
    }
    {
        const card = ui.div(c).row().wFull().p(16).gap(12).itemsCenter().rounded(12).bg(th.surface).border(th.border);
        defer card.end();
        ui.icon(c, "sparkles", .{ .size = 20, .color = .hex(0xff9f0a) });
        {
            const t = ui.div(c).column().gap(2).grow().w(0).clip();
            defer t.end();
            const title = switch (a.cleaner.phase) {
                .scanning => "Looking through caches, logs and temporary files…",
                .cleaning => "Cleaning…",
                .idle => if (a.cleaner.scanned) c.print("{s} found to clean", .{procs.bytes(&b, a.cleaner.total())}) else "Cleanup hasn't looked yet",
            };
            ui.text(c, title, .{ .size = 14, .weight = .semibold });
            ui.text(c, "Caches, logs, package caches, developer data, temporary files, installers and the Trash", .{ .size = 12, .color = th.muted });
        }
        if (ui.button(c, if (a.cleaner.scanned) "Review" else "Scan", .{ .variant = .primary, .size = 12 }).clicked) {
            if (!a.cleaner.scanned) a.cleaner.scan();
            a.page = .cleanup;
        }
    }
    ui.text(c, "Busiest apps and processes", .{ .size = 13, .weight = .semibold, .color = th.muted });
    const list = ui.div(c).column().wFull().p(6).rounded(12).bg(th.surface).border(th.border).clip();
    defer list.end();
    var top: [6]?usize = @splat(null);
    for (a.table.groups.items, 0..) |g, i| {
        var slot: ?usize = null;
        for (&top, 0..) |t, k| {
            if (t == null or a.table.groups.items[t.?].cpu < g.cpu) {
                slot = k;
                break;
            }
        }
        if (slot) |k| {
            var m: usize = top.len - 1;
            while (m > k) : (m -= 1) top[m] = top[m - 1];
            top[k] = i;
        }
    }
    for (top) |t| if (t) |i| {
        const g = a.table.groups.items[i];
        ui.key(c, c.print("top-{d}", .{g.key}));
        const r = ui.div(c).row().wFull().h(table.row_h).px(6).itemsCenter();
        defer r.end();
        {
            const n = table.cell(c, null, false);
            defer n.end();
            ui.text(c, g.name, .{ .size = 12.5 });
            if (g.count > 1) ui.text(c, c.print("  {d}", .{g.count}), .{ .size = 11, .color = th.muted });
        }
        table.value(c, c.print("{d:.1}%", .{g.cpu}), 80, null);
        table.value(c, size(c, g.memory), 90, null);
    };
}
