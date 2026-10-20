const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const procs = @import("procs.zig");
const groups = @import("groups.zig");
const table = @import("view_table.zig");
const view = @import("view.zig");
const App = @import("app.zig").App;

const Col = struct { title: []const u8, sort: groups.Sort, w: ?f32 };

const cols = [_]Col{
    .{ .title = "Name", .sort = .name, .w = null },
    .{ .title = "% CPU", .sort = .cpu, .w = 64 },
    .{ .title = "Memory", .sort = .memory, .w = 84 },
    .{ .title = "Threads", .sort = .threads, .w = 64 },
    .{ .title = "Disk", .sort = .disk, .w = 84 },
    .{ .title = "CPU Time", .sort = .time, .w = 84 },
    .{ .title = "PID", .sort = .pid, .w = 60 },
    .{ .title = "User", .sort = .user, .w = 96 },
};

pub fn page(c: *ui.Context, a: *App) void {
    const th = c.theme;
    {
        const h = view.header(c, "Processes", c.print("{d} shown in {d} groups · {d} in all", .{ a.table.shown, a.table.groups.items.len, a.sampler.procs.items.len }));
        defer h.end();
        _ = ui.textField(c, &a.query, .{ .placeholder = "Search", .width = .{ .px = 160 }, .size = 12 });
        _ = ui.segmented(c, &.{ "All", "Apps", "Mine", "System" }, &a.show);
        const chosen = a.selected != null;
        if (ui.button(c, "Quit", .{ .size = 12, .disabled = !chosen }).clicked) {
            a.force = false;
            a.confirm_quit = true;
        }
        if (ui.button(c, "Force Quit", .{ .variant = .danger, .size = 12, .disabled = !chosen }).clicked) {
            a.force = true;
            a.confirm_quit = true;
        }
    }
    {
        const head = ui.div(c).row().wFull().px(14).itemsCenter();
        defer head.end();
        _ = c.leaf(.{ .width = .{ .px = 22 } }, .none, null);
        for (cols) |col| if (table.head(c, col.title, col.w, col.w != null and col.sort != .user, a.sort == col.sort, a.reversed)) a.sortBy(col.sort);
    }
    table.line(c);
    var rows = ui.list(c, .{ .count = a.table.rows.items.len, .row_height = table.row_h, .padding = .{ .left = 8, .right = 8 } });
    while (rows.next()) |i| row(c, a, a.table.rows.items[i], i);
    rows.end();
    table.line(c);
    {
        const foot = ui.div(c).row().wFull().h(28).px(20).gap(14).itemsCenter();
        defer foot.end();
        ui.text(c, c.print("{d} of {d} processes", .{ a.table.shown, a.sampler.procs.items.len }), .{ .size = 11, .color = th.muted });
        ui.spacer(c);
        table.dot(c, 7, .hex(0x0a84ff));
        ui.text(c, c.print("CPU {d:.1}%", .{a.sampler.system.cpu}), .{ .size = 11, .mono = true });
        table.dot(c, 7, .hex(0x30d158));
        ui.text(c, c.print("Memory {s}", .{view.size(c, a.sampler.system.mem_used)}), .{ .size = 11, .mono = true });
    }
}

fn row(c: *ui.Context, a: *App, r: groups.Row, i: usize) void {
    const th = c.theme;
    const g = &a.table.groups.items[r.group];
    const p: ?*const procs.Proc = if (r.member) |m| &a.sampler.procs.items[m] else null;
    ui.key(c, if (p) |pp| c.print("pid-{d}", .{pp.pid}) else c.print("group-{d}", .{g.key}));
    const sel = if (a.selected) |s| (s.group == g.key and ((s.pid == null and p == null) or (p != null and s.pid != null and s.pid.? == p.?.pid))) else false;
    const bg = if (sel) th.accent.alpha(0.2) else if (i % 2 == 1) th.surface_hover.alpha(0.45) else th.background.alpha(0);
    const d = ui.div(c).row().wFull().h(table.row_h).px(6).itemsCenter().rounded(6).bg(bg).control();
    defer d.end();
    const it = d.interaction();
    const open = a.expanded_groups.contains(g.key);
    if (p == null) {
        if (table.chevron(c, open, g.count > 1)) {
            a.toggleGroup(g.key);
            c.changed = true;
        }
    } else _ = c.leaf(.{ .width = .{ .px = 18 } }, .none, null);
    if (it.clicked and !c.changed) {
        a.selected = if (sel) null else .{ .group = g.key, .pid = if (p) |pp| pp.pid else null };
        c.changed = true;
    }
    if (it.double_clicked and p == null and g.count > 1) a.toggleGroup(g.key);
    const mine = (if (p) |pp| pp.uid else a.sampler.uid) == a.sampler.uid;
    {
        const n = table.cell(c, null, false).gap(6);
        defer n.end();
        if (p != null) _ = c.leaf(.{ .width = .{ .px = 14 } }, .none, null);
        ui.text(c, if (p) |pp| pp.name else g.name, .{ .size = 12.5, .color = if (mine) th.text else th.muted });
        if (p == null and g.count > 1) {
            const badge = ui.div(c).row().px(5).h(15).center().rounded(4).bg(th.surface_hover);
            defer badge.end();
            ui.text(c, c.print("{d}", .{g.count}), .{ .size = 10, .mono = true, .color = th.muted });
        }
    }
    var b: [32]u8 = undefined;
    const known = if (p) |pp| pp.known else g.known;
    const cpu = if (p) |pp| pp.cpu else g.cpu;
    const mem = if (p) |pp| pp.memory else g.memory;
    const threads = if (p) |pp| pp.threads else g.threads;
    const disk = if (p) |pp| pp.disk_rate else g.disk;
    const t = if (p) |pp| pp.cpu_time_ns else g.time_ns;
    const pid = if (p) |pp| pp.pid else g.pid;
    const dash = "–";
    table.value(c, if (known) c.print("{d:.1}", .{cpu}) else dash, cols[1].w, null);
    table.value(c, if (known) view.size(c, mem) else dash, cols[2].w, if (mem > 1_000_000_000) ui.Color.hex(0xff9f0a) else null);
    table.value(c, if (known) c.print("{d}", .{threads}) else dash, cols[3].w, null);
    table.value(c, if (known and disk >= 1) c.print("{s}/s", .{procs.bytes(&b, @intFromFloat(disk))}) else if (known) "0" else dash, cols[4].w, th.muted);
    table.value(c, if (known) c.print("{s}", .{procs.duration(&b, t)}) else dash, cols[5].w, null);
    table.value(c, c.print("{d}", .{pid}), cols[6].w, th.muted);
    {
        const u = table.cell(c, cols[7].w, false);
        defer u.end();
        ui.text(c, if (p) |pp| pp.user else g.user, .{ .size = 12, .color = th.muted });
    }
}

pub fn dialog(c: *ui.Context, a: *App) void {
    var pids: std.ArrayList(i32) = .empty;
    defer pids.deinit(a.gpa);
    a.quitTargets(&pids);
    const name = a.selectionName();
    const many = pids.items.len > 1;
    const title = if (a.force)
        (if (many) c.print("Force quit {s} ({d} processes)?", .{ name, pids.items.len }) else c.print("Force quit {s}?", .{name}))
    else if (many) c.print("Quit {s} ({d} processes)?", .{ name, pids.items.len }) else c.print("Quit {s}?", .{name});
    const desc = if (a.force) "It stops at once. Unsaved changes are lost." else "It is asked to quit, as Quit in its menu does.";
    if (kit.dialog(c, "quit", &a.confirm_quit, .{ .title = title, .description = desc, .ok = if (a.force) "Force Quit" else "Quit", .ok_variant = if (a.force) .danger else .primary })) |d| {
        if (d.end() == .ok) a.quitSelected();
    }
}
