const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const metrics = @import("metrics.zig");
const groups = @import("groups.zig");
const procs = @import("procs.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;

pub const cpu_tint = 0x0a84ff;
pub const memory_tint = 0x34c759;
pub const gpu_tint = 0xff2d55;
pub const disk_tint = 0xff9500;
pub const network_tint = 0x30b0c7;
pub const energy_tint = 0xe5a00d;
pub const about_tint = 0x8e8e93;

pub const user_color = 0x0a84ff;
pub const system_color = 0xff3b30;
pub const app_color = 0x34c759;
pub const wired_color = 0xff9500;
pub const compressed_color = 0x32ade6;
pub const cached_color = 0x98989d;
pub const read_color = 0x32ade6;
pub const write_color = 0xff9500;

pub fn card(c: *ui.Context) ui.Div {
    return ui.div(c).column().wFull().p(16).gap(12).rounded(14).bg(c.theme.surface);
}

pub fn half(c: *ui.Context) ui.Div {
    return ui.div(c).column().grow().w(0).p(16).gap(12).rounded(14).bg(c.theme.surface);
}

pub fn pair(c: *ui.Context) ui.Div {
    return ui.div(c).row().wFull().gap(14).itemsStretch();
}

pub fn head(c: *ui.Context, icon: []const u8, tint: u24, title: []const u8) ui.Div {
    const color = ui.Color.hex(tint);
    const h = ui.div(c).row().wFull().gap(8).itemsCenter();
    {
        const badge = ui.div(c).row().w(24).h(24).center().rounded(7).bg(color.alpha(0.14));
        defer badge.end();
        ui.icon(c, icon, .{ .size = 12, .color = color });
    }
    ui.text(c, title, .{ .size = 14, .weight = .semibold, .color = color });
    ui.spacer(c);
    return h;
}

pub fn legend(c: *ui.Context, color: u24, title: []const u8) void {
    ui.key(c, title);
    const d = ui.div(c).row().gap(5).itemsCenter();
    defer d.end();
    dot(c, 6, .hex(color));
    ui.text(c, title, .{ .size = 11, .color = c.theme.muted });
}

pub fn tag(c: *ui.Context, title: []const u8, color: ui.Color) void {
    ui.key(c, title);
    const d = ui.div(c).row().px(8).py(3).gap(5).itemsCenter().roundedFull().bg(color.alpha(0.16));
    defer d.end();
    dot(c, 5, color);
    ui.text(c, title, .{ .size = 11, .weight = .semibold, .color = color });
}

pub fn dot(c: *ui.Context, size: f32, color: ui.Color) void {
    _ = c.leaf(.{ .width = .{ .px = size }, .height = .{ .px = size }, .radius = size / 2, .background = color }, .none, null);
}

pub fn big(c: *ui.Context, label: []const u8, value: []const u8, unit: []const u8) void {
    const col = ui.div(c).column().gap(2);
    defer col.end();
    if (label.len > 0) ui.text(c, label, .{ .size = 12, .color = c.theme.muted });
    const r = ui.div(c).row().gap(4).itemsEnd();
    defer r.end();
    ui.text(c, value, .{ .size = 34, .weight = .bold });
    if (unit.len > 0) {
        const u = ui.div(c).column().pb(5);
        defer u.end();
        ui.text(c, unit, .{ .size = 15, .weight = .semibold, .color = c.theme.muted });
    }
}

pub fn stat(c: *ui.Context, label: []const u8, value: []const u8, sub: []const u8) void {
    ui.key(c, label);
    const col = ui.div(c).column().grow().w(0).gap(3).clip();
    defer col.end();
    ui.text(c, label, .{ .size = 11.5, .color = c.theme.muted });
    ui.text(c, value, .{ .size = 13, .weight = .semibold });
    if (sub.len > 0) ui.text(c, sub, .{ .size = 10.5, .color = c.theme.muted });
}

pub fn kv(c: *ui.Context, label: []const u8, value: []const u8) void {
    ui.key(c, label);
    const r = ui.div(c).row().wFull().h(22).gap(8).itemsCenter();
    defer r.end();
    {
        const l = ui.div(c).row().grow().w(0).clip();
        defer l.end();
        ui.text(c, label, .{ .size = 12.5, .color = c.theme.muted });
    }
    ui.text(c, value, .{ .size = 12.5, .weight = .semibold });
}

pub fn bar(c: *ui.Context, frac: f32, color: ui.Color, height: f32) void {
    const f = std.math.clamp(frac, 0, 1);
    const track = ui.div(c).row().wFull().h(height).roundedFull().bg(color.alpha(0.18)).clip();
    defer track.end();
    if (f > 0) _ = c.leaf(.{ .width = .{ .px = 0 }, .grow = f, .height = .fill, .radius = height / 2, .background = color }, .none, null);
    if (f < 1) _ = c.leaf(.{ .width = .{ .px = 0 }, .grow = 1 - f, .height = .fill }, .none, null);
}

pub const Slice = struct { color: ui.Color, value: f32 };

pub fn stacked(c: *ui.Context, slices: []const Slice, height: f32) void {
    const track = ui.div(c).row().wFull().h(height).gap(2).roundedFull().clip();
    defer track.end();
    for (slices, 0..) |s, i| if (s.value > 0) {
        ui.key(c, c.print("seg-{d}", .{i}));
        _ = c.leaf(.{ .width = .{ .px = 0 }, .grow = s.value, .height = .fill, .radius = 2, .background = s.color }, .none, null);
    };
}

pub fn donut(c: *ui.Context, size: f32, slices: []const Slice, center: []const u8, sub: []const u8) void {
    const th = c.theme;
    const box = ui.div(c).w(size).h(size).center();
    defer box.end();
    var total: f32 = 0;
    for (slices) |s| total += s.value;
    const dot_size = @max(3, size * 0.055);
    const rings = 3;
    for (0..rings) |ring| {
        const r = size / 2 - dot_size / 2 - @as(f32, @floatFromInt(ring)) * dot_size * 1.35;
        const n: usize = @intFromFloat(@max(12, 2 * std.math.pi * r / (dot_size * 1.45)));
        for (0..n) |i| {
            const at = (@as(f32, @floatFromInt(i)) + 0.5) / @as(f32, @floatFromInt(n));
            const a = at * 2 * std.math.pi;
            var color = th.border;
            var acc: f32 = 0;
            for (slices) |s| {
                acc += s.value / @max(total, 0.0001);
                if (at <= acc) {
                    color = s.color;
                    break;
                }
            }
            _ = c.leaf(.{ .absolute = true, .offset = .{ .x = size / 2 + r * @sin(a) - dot_size / 2, .y = size / 2 - r * @cos(a) - dot_size / 2 }, .width = .{ .px = dot_size }, .height = .{ .px = dot_size }, .radius = dot_size / 2, .background = color }, .none, null);
        }
    }
    const t = ui.div(c).column().itemsCenter();
    defer t.end();
    ui.text(c, center, .{ .size = size * 0.17, .weight = .bold });
    if (sub.len > 0) ui.text(c, sub, .{ .size = size * 0.085, .color = th.muted });
}

pub const Series = struct { color: u24, value: *const fn (metrics.Sample) f32 };

pub const ChartOptions = struct {
    rows: usize = 14,
    dot: f32 = 4.5,
    gap: f32 = 2.5,
    axis: bool = true,
    max: f32 = 100,
    pad: f32 = 10,
};

pub fn chart(c: *ui.Context, a: *App, key: []const u8, tint: u24, series: []const Series, opts: ChartOptions) void {
    const th = c.theme;
    const color = ui.Color.hex(tint);
    ui.key(c, key);
    const panel = ui.div(c).column().wFull().p(opts.pad).gap(6).rounded(10).bg(color.alpha(0.09));
    defer panel.end();
    const grid = ui.div(c).column().wFull().gap(opts.gap);
    const rect = grid.interaction().rect;
    const width = if (rect) |r| r.w else 400;
    const cols: usize = @intFromFloat(@max(8, @floor((width + opts.gap) / (opts.dot + opts.gap))));
    const h = &a.metrics.history;
    const now = if (h.last()) |s| s.t else 0;
    const span = a.range.seconds();
    var heights: [512][4]u8 = undefined;
    const shown: usize = @min(cols, heights.len);
    const rows_f: f32 = @floatFromInt(opts.rows);
    for (0..shown) |i| {
        var acc: f32 = 0;
        const s = h.column(now, span, shown, i, app_mod.interval * 1.5);
        for (0..4) |k| {
            if (s != null and k < series.len) acc += series[k].value(s.?) / @max(opts.max, 0.0001);
            heights[i][k] = if (s == null) 0 else @intFromFloat(@min(rows_f, @round(@min(acc, 1) * rows_f)));
        }
        if (s != null and series.len > 0 and heights[i][series.len - 1] == 0 and acc > 0.002) heights[i][series.len - 1] = 1;
    }
    const empty = color.alpha(0.2);
    for (0..opts.rows) |r| {
        ui.key(c, c.print("r{d}", .{r}));
        const row = ui.div(c).row().wFull().justifyBetween();
        defer row.end();
        const level: u8 = @intCast(opts.rows - 1 - r);
        for (0..shown) |i| {
            var fill = empty;
            for (0..series.len) |k| if (level < heights[i][k]) {
                fill = .hex(series[k].color);
                break;
            };
            dot(c, opts.dot, fill);
        }
    }
    grid.end();
    if (!opts.axis) return;
    const axis = ui.div(c).row().wFull().justifyBetween();
    defer axis.end();
    const marks = [_][]const u8{ "-60m", "-45m", "-30m", "-15m", "now" };
    const minutes = span / 60;
    for (marks, 0..) |m, i| {
        ui.key(c, m);
        const label = if (i == marks.len - 1) "now" else if (minutes >= 4) c.print("-{d:.0}m", .{minutes * @as(f64, @floatFromInt(4 - i)) / 4}) else c.print("-{d:.0}s", .{span * @as(f64, @floatFromInt(4 - i)) / 4});
        ui.text(c, label, .{ .size = 10, .color = th.muted });
    }
}

pub const Metric = enum { cpu, memory, disk, energy };

fn metricOf(g: *const groups.Group, m: Metric) f64 {
    return switch (m) {
        .cpu => g.cpu,
        .memory => @floatFromInt(g.memory),
        .disk => g.disk,
        .energy => g.energy,
    };
}

pub fn top(a: *App, m: Metric, out: []u32) usize {
    const list = a.everyone.groups.items;
    var n: usize = 0;
    for (list, 0..) |*g, i| {
        const v = metricOf(g, m);
        if (v <= 0) continue;
        var at = if (n < out.len) n else n - 1;
        if (n == out.len and metricOf(&list[out[at]], m) >= v) continue;
        while (at > 0 and metricOf(&list[out[at - 1]], m) < v) : (at -= 1) out[at] = out[at - 1];
        out[at] = @intCast(i);
        if (n < out.len) n += 1;
    }
    return n;
}

pub fn valueText(c: *ui.Context, g: *const groups.Group, m: Metric) []const u8 {
    var b: [32]u8 = undefined;
    return switch (m) {
        .cpu => c.print("{d:.1}%", .{g.cpu}),
        .memory => c.print("{s}", .{procs.bytes(&b, g.memory)}),
        .disk => c.print("{s}", .{metrics.rate(&b, g.disk)}),
        .energy => c.print("{s}", .{metrics.watts(&b, g.energy)}),
    };
}

pub fn appGlyph(c: *ui.Context, g: *const groups.Group, size: f32) void {
    const th = c.theme;
    const d = ui.div(c).row().w(size).h(size).center().rounded(size * 0.26).bg(th.muted.alpha(0.18));
    defer d.end();
    ui.icon(c, if (g.bundle.len > 0) "app.fill" else "terminal", .{ .size = size * 0.55, .color = th.muted });
}

pub fn topList(c: *ui.Context, a: *App, title: []const u8, icon: []const u8, tint: u24, m: Metric, sort: groups.Sort) void {
    const th = c.theme;
    const box = card(c);
    defer box.end();
    {
        const h = head(c, icon, tint, title);
        defer h.end();
        ui.key(c, "show-all");
        const link = ui.div(c).row().gap(3).itemsCenter().control();
        defer link.end();
        if (link.clicked()) {
            a.page = .processes;
            a.show = @intFromEnum(groups.Show.all);
            a.sort = sort;
            a.reversed = false;
        }
        ui.text(c, "Show All", .{ .size = 12, .weight = .semibold, .color = .hex(tint) });
        ui.icon(c, "chevron.right", .{ .size = 9, .weight = .bold, .color = .hex(tint) });
    }
    var idx: [10]u32 = undefined;
    const n = top(a, m, &idx);
    const grid = ui.div(c).row().wFull().gap(24);
    defer grid.end();
    for (0..2) |col| {
        ui.key(c, c.print("col-{d}", .{col}));
        const column = ui.div(c).column().grow().w(0).gap(2);
        defer column.end();
        var i = col;
        while (i < n) : (i += 2) {
            const g = &a.everyone.groups.items[idx[i]];
            ui.key(c, c.print("top-{d}", .{g.key}));
            const r = ui.div(c).row().wFull().h(30).gap(8).itemsCenter();
            defer r.end();
            appGlyph(c, g, 18);
            {
                const name = ui.div(c).row().grow().w(0).gap(6).itemsCenter().clip();
                defer name.end();
                ui.text(c, g.name, .{ .size = 12.5 });
                if (g.count > 1) ui.text(c, c.print("{d}", .{g.count}), .{ .size = 10.5, .color = th.muted });
            }
            ui.text(c, valueText(c, g, m), .{ .size = 12.5, .weight = .semibold });
        }
    }
}

pub fn treemap(c: *ui.Context, a: *App, height: f32) void {
    const th = c.theme;
    var idx: [9]u32 = undefined;
    const n = top(a, .memory, &idx);
    const list = a.everyone.groups.items;
    const lead: usize = @min(n, 4);
    const r = ui.div(c).row().wFull().h(height).gap(6);
    defer r.end();
    for (idx[0..lead]) |gi| tile(c, &list[gi], @floatFromInt(list[gi].memory), true);
    if (n <= lead) return;
    var rest: f32 = 0;
    for (idx[lead..n]) |gi| rest += @floatFromInt(list[gi].memory);
    const col = ui.div(c).column().w(0).hFull().gap(6);
    c.node(col.index).style.grow = rest;
    defer col.end();
    var k: usize = lead;
    while (k < n) {
        ui.key(c, c.print("pair-{d}", .{k}));
        const row = ui.div(c).row().wFull().h(0).gap(6);
        var sum: f32 = 0;
        const end = @min(n, k + 2);
        for (idx[k..end]) |gi| sum += @floatFromInt(list[gi].memory);
        c.node(row.index).style.grow = sum;
        for (idx[k..end]) |gi| tile(c, &list[gi], @floatFromInt(list[gi].memory), false);
        row.end();
        k = end;
    }
    _ = th;
}

fn tile(c: *ui.Context, g: *const groups.Group, weight: f32, tall: bool) void {
    const th = c.theme;
    ui.key(c, c.print("tile-{d}", .{g.key}));
    const t = ui.div(c).column().w(0).hFull().p(8).gap(2).rounded(9).bg(th.background).clip();
    c.node(t.index).style.grow = weight;
    defer t.end();
    appGlyph(c, g, 16);
    ui.spacer(c);
    if (!tall) return;
    ui.text(c, g.name, .{ .size = 11.5, .weight = .semibold });
    var b: [32]u8 = undefined;
    ui.text(c, c.print("{s}", .{procs.bytes(&b, g.memory)}), .{ .size = 10.5, .color = th.muted });
}

pub fn energyRows(c: *ui.Context, a: *App, count: usize) void {
    const th = c.theme;
    var idx: [10]u32 = undefined;
    const n = top(a, .energy, idx[0..@min(count, idx.len)]);
    const list = a.everyone.groups.items;
    const most = if (n > 0) list[idx[0]].energy else 1;
    for (idx[0..n]) |gi| {
        const g = &list[gi];
        ui.key(c, c.print("en-{d}", .{g.key}));
        const r = ui.div(c).row().wFull().gap(10).itemsCenter();
        defer r.end();
        appGlyph(c, g, 18);
        const col = ui.div(c).column().grow().w(0).gap(4);
        defer col.end();
        {
            const line = ui.div(c).row().wFull().itemsCenter();
            defer line.end();
            {
                const name = ui.div(c).row().grow().w(0).clip();
                defer name.end();
                ui.text(c, g.name, .{ .size = 12 });
            }
            var b: [32]u8 = undefined;
            ui.text(c, c.print("{s}", .{metrics.watts(&b, g.energy)}), .{ .size = 11.5, .color = th.muted });
        }
        bar(c, g.energy / @max(most, 0.001), .hex(energy_tint), 4);
    }
    if (n == 0) ui.text(c, "Measuring…", .{ .size = 12, .color = th.muted });
}

pub fn pageHeader(c: *ui.Context, a: *App, title: []const u8, sub: []const u8, ranged: bool) void {
    const view = @import("view.zig");
    const h = view.header(c, title, sub);
    defer h.end();
    if (ranged) {
        const ranges = std.enums.values(app_mod.Range);
        var titles: [ranges.len][]const u8 = undefined;
        for (ranges, 0..) |r, i| titles[i] = r.title();
        var sel: usize = @intFromEnum(a.range);
        if (ui.segmented(c, &titles, &sel)) a.range = @enumFromInt(sel);
    }
    pauseButton(c, a);
}

pub fn pauseButton(c: *ui.Context, a: *App) void {
    if (kit.iconButton(c, if (a.live) "pause.fill" else "play.fill", .{ .size = .sm, .variant = .secondary, .pill = true, .tooltip = if (a.live) "Pause Updates" else "Resume Updates" }).clicked) a.live = !a.live;
}
