const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const metrics = @import("metrics.zig");
const groups = @import("groups.zig");
const procs = @import("procs.zig");
const app_mod = @import("app.zig");
const theme = @import("theme.zig");
const App = app_mod.App;
const Hue = theme.Hue;

pub const cpu_tint: Hue = .violet;
pub const memory_tint: Hue = .sand;
pub const gpu_tint: Hue = .violet;
pub const disk_tint: Hue = .sand;
pub const network_tint: Hue = .lime;
pub const energy_tint: Hue = .yellow;
pub const about_tint: Hue = .neutral;

pub const user_color: Hue = .violet;
pub const system_color: Hue = .sand;
pub const app_color: Hue = .sand;
pub const wired_color: Hue = .violet;
pub const compressed_color: Hue = .lime;
pub const cached_color: Hue = .neutral;
pub const read_color: Hue = .lime;
pub const write_color: Hue = .sand;

pub const radius = theme.radius.card;
pub const pad = theme.space.card;
const inset = theme.inner(radius, pad);

pub fn card(c: *ui.Context) ui.Div {
    return theme.surface(c, ui.div(c).column().wFull().p(pad).gap(theme.space.xl), radius);
}

pub fn half(c: *ui.Context) ui.Div {
    return theme.surface(c, ui.div(c).column().grow().w(0).p(pad).gap(theme.space.xl), radius);
}

pub fn pair(c: *ui.Context) ui.Div {
    return ui.div(c).row().wFull().gap(theme.space.gutter).itemsStretch();
}

pub fn head(c: *ui.Context, icon: []const u8, tint: Hue, title: []const u8) ui.Div {
    const h = ui.div(c).row().wFull().h(20).gap(theme.space.md).itemsCenter();
    ui.icon(c, icon, .{ .size = 13, .color = theme.hue(c, tint) });
    ui.text(c, title, .{ .size = 13, .weight = .semibold });
    ui.spacer(c);
    return h;
}

pub fn legend(c: *ui.Context, color: Hue, title: []const u8) void {
    ui.key(c, title);
    const d = ui.div(c).row().gap(5).itemsCenter();
    defer d.end();
    dot(c, 6, theme.hue(c, color));
    ui.text(c, title, .{ .size = 11, .color = c.theme.muted });
}

fn digitAdvance(w: ui.Weight) f32 {
    return switch (w) {
        .regular => 0.59,
        .medium => 0.6,
        .semibold => 0.61,
        .bold => 0.625,
    };
}

pub fn figure(c: *ui.Context, s: []const u8, style: ui.TextStyle) void {
    const cell = @ceil(style.size * digitAdvance(style.weight) * 2) / 2;
    const r = ui.div(c).row().itemsEnd();
    defer r.end();
    var from: usize = 0;
    for (s, 0..) |ch, i| {
        if (!std.ascii.isDigit(ch)) continue;
        if (i > from) ui.text(c, s[from..i], style);
        const d = ui.div(c).row().w(cell).justifyCenter();
        ui.text(c, s[i .. i + 1], style);
        d.end();
        from = i + 1;
    }
    if (from < s.len) ui.text(c, s[from..], style);
}

pub fn segmented(c: *ui.Context, options: []const []const u8, selected: *usize) bool {
    const p = theme.of(c);
    const track = ui.div(c).row().h(28).p(2).gap(2).roundedFull().bg(p.fill_2);
    defer track.end();
    var changed = false;
    for (options, 0..) |opt, i| {
        ui.key(c, opt);
        const on = selected.* == i;
        var d = ui.div(c).row().hFull().px(12).center().roundedFull().control();
        d = if (on) d.bg(p.win).shadow(.{ .color = .{ .a = 0.14 }, .blur = 3, .y = 1 }) else d.hover(p.fill);
        defer d.end();
        if (d.clicked() and !on) {
            selected.* = i;
            changed = true;
            c.changed = true;
        }
        ui.text(c, opt, .{ .size = 12.5, .weight = .medium, .color = if (on) p.label else p.label_2 });
    }
    return changed;
}

pub fn tag(c: *ui.Context, title: []const u8, color: ui.Color) void {
    ui.key(c, title);
    const d = ui.div(c).row().px(8).py(3).gap(5).itemsCenter().roundedFull().bg(color.alpha(0.16));
    defer d.end();
    dot(c, 5, color);
    ui.text(c, title, .{ .size = 11, .weight = .semibold });
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
    figure(c, value, .{ .size = 34, .weight = .bold });
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
    figure(c, value, .{ .size = 13, .weight = .semibold });
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
    figure(c, value, .{ .size = 12.5, .weight = .semibold });
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

pub const Series = struct { color: Hue, value: *const fn (metrics.Sample) f32 };

pub const ChartOptions = struct {
    rows: usize = 14,
    dot: f32 = 4.5,
    gap: f32 = 2.5,
    axis: bool = true,
    max: f32 = 100,
    pad: f32 = 10,
};

const unmeasured_chart_w = 160;

pub fn chart(c: *ui.Context, a: *App, key: []const u8, tint: Hue, series: []const Series, opts: ChartOptions) void {
    const th = c.theme;
    const color = theme.hue(c, tint);
    ui.key(c, key);
    const panel = ui.div(c).column().wFull().p(opts.pad).gap(6).rounded(inset).bg(color.alpha(0.09)).clip();
    defer panel.end();
    const grid = ui.div(c).column().wFull().gap(opts.gap);
    const rect = grid.interaction().rect;
    if (rect == null) c.frameIn(0);
    const width = if (rect) |r| r.w else unmeasured_chart_w;
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
                fill = theme.hue(c, series[k].color);
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
    const d = ui.div(c).row().w(size).h(size).center().rounded(theme.radius.chip).bg(theme.of(c).fill_2);
    defer d.end();
    ui.icon(c, if (g.bundle.len > 0) "app.fill" else "terminal", .{ .size = size * 0.55, .color = th.muted });
}

pub fn topList(c: *ui.Context, a: *App, title: []const u8, icon: []const u8, tint: Hue, m: Metric, sort: groups.Sort) void {
    const th = c.theme;
    const box = card(c);
    defer box.end();
    {
        const h = head(c, icon, tint, title);
        defer h.end();
        ui.key(c, "show-all");
        const link = ui.div(c).row().h(24).px(8).gap(3).itemsCenter().rounded(theme.radius.row).control().hover(theme.of(c).fill);
        defer link.end();
        if (link.clicked()) {
            a.page = .processes;
            a.show = @intFromEnum(groups.Show.all);
            a.sort = sort;
            a.reversed = false;
        }
        ui.text(c, "Show All", .{ .size = 12, .weight = .medium, .color = th.accent });
        ui.icon(c, "chevron.right", .{ .size = 9, .weight = .bold, .color = th.accent });
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
            const r = ui.div(c).row().wFull().h(30).gap(8).itemsCenter().control();
            defer r.end();
            if (r.clicked()) {
                a.page = .processes;
                a.show = @intFromEnum(groups.Show.all);
                a.sort = sort;
                a.reversed = false;
                a.selected = .{ .group = g.key };
            }
            const hot = r.hovered();
            appGlyph(c, g, 18);
            {
                const name = ui.div(c).row().grow().w(0).gap(6).itemsCenter().clip();
                defer name.end();
                ui.text(c, g.name, .{ .size = 12.5, .color = if (hot) th.accent else th.text });
                if (g.count > 1) ui.text(c, c.print("{d}", .{g.count}), .{ .size = 10.5, .color = th.muted });
            }
            figure(c, valueText(c, g, m), .{ .size = 12.5, .weight = .semibold });
        }
    }
}

const three_row_treemap_h = 120;
const labelled_tile_w = 72;

pub fn treemap(c: *ui.Context, a: *App, height: f32) void {
    const th = c.theme;
    var idx: [9]u32 = undefined;
    const n = top(a, .memory, idx[0..if (height < three_row_treemap_h) 8 else idx.len]);
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
    const t = ui.div(c).column().w(0).hFull().p(8).gap(2).rounded(theme.radius.row).bg(theme.of(c).fill).clip();
    c.node(t.index).style.grow = weight;
    defer t.end();
    const it = t.interaction();
    const rect = it.rect;
    if (rect == null) c.frameIn(0);
    var b: [32]u8 = undefined;
    kit.tooltip(c, it, c.print("{s}, {s}", .{ g.name, procs.bytes(&b, g.memory) }), .{});
    appGlyph(c, g, 16);
    ui.spacer(c);
    if (!tall or (rect orelse return).w < labelled_tile_w) return;
    ui.text(c, g.name, .{ .size = 11.5, .weight = .semibold });
    figure(c, c.print("{s}", .{procs.bytes(&b, g.memory)}), .{ .size = 10.5, .color = th.muted });
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
            figure(c, c.print("{s}", .{metrics.watts(&b, g.energy)}), .{ .size = 11.5, .color = th.muted });
        }
        bar(c, g.energy / @max(most, 0.001), theme.hue(c, energy_tint), 4);
    }
    if (n == 0) ui.text(c, "Measuring…", .{ .size = 12, .color = th.muted });
}

pub fn emptyList(c: *ui.Context, icon: []const u8, title: []const u8, hint: []const u8) void {
    const th = c.theme;
    const box = ui.div(c).column().wFull().grow().center().gap(6);
    defer box.end();
    ui.icon(c, icon, .{ .size = 26, .color = th.muted.alpha(0.6) });
    ui.text(c, title, .{ .size = 14, .weight = .semibold });
    ui.text(c, hint, .{ .size = 12, .color = th.muted });
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
        if (segmented(c, &titles, &sel)) a.range = @enumFromInt(sel);
    }
    pauseButton(c, a);
}

pub fn pauseButton(c: *ui.Context, a: *App) void {
    if (!a.live) ui.text(c, "Paused", .{ .size = 12, .weight = .semibold, .color = c.theme.muted });
    if (kit.iconButton(c, if (a.live) "pause.fill" else "play.fill", .{ .size = .sm, .variant = .secondary, .pill = true, .tooltip = if (a.live) "Pause Updates" else "Resume Updates" }).clicked) a.live = !a.live;
}
