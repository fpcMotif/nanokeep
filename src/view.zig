const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const procs = @import("procs.zig");
const metrics = @import("metrics.zig");
const app_mod = @import("app.zig");
const card = @import("view_card.zig");
const hw = @import("view_hw.zig");
const App = app_mod.App;

const theme = @import("theme.zig");

extern "c" fn time(t: ?*i64) i64;

pub fn size(c: *ui.Context, n: u64) []const u8 {
    var b: [32]u8 = undefined;
    return c.print("{s}", .{procs.bytes(&b, n)});
}

pub fn rate(c: *ui.Context, bytes_per_s: f32) []const u8 {
    var b: [32]u8 = undefined;
    return c.print("{s}", .{metrics.rate(&b, bytes_per_s)});
}

pub fn watts(c: *ui.Context, w: f32) []const u8 {
    var b: [32]u8 = undefined;
    return c.print("{s}", .{metrics.watts(&b, w)});
}

pub fn uptime(c: *ui.Context, seconds: i64) []const u8 {
    var b: [32]u8 = undefined;
    return c.print("{s}", .{metrics.uptime(&b, seconds)});
}

pub fn ago(c: *ui.Context, now: i64, then: i64) []const u8 {
    var b: [32]u8 = undefined;
    return c.print("{s}", .{procs.ago(&b, now, then)});
}

const narrow_window_w = 1000;

pub fn narrow(c: *ui.Context) bool {
    return c.size.w < narrow_window_w;
}

const TileRows = struct {
    per_row: usize,
    count: usize = 0,
    row: ?ui.Div = null,

    fn next(g: *TileRows, c: *ui.Context) void {
        if (g.count % g.per_row == 0) {
            g.end();
            ui.key(c, c.print("tile-row-{d}", .{g.count}));
            g.row = card.pair(c);
        }
        g.count += 1;
    }

    fn end(g: *TileRows) void {
        if (g.row) |r| r.end();
        g.row = null;
    }
};

pub fn view(a: *App, c: *ui.Context) void {
    theme.apply(c);
    c.frameIn(a.tick(if (a.clock) |f| f() else c.time));
    keys(c, a);
    const th = c.theme;
    {
        const root = ui.div(c).row().sizeFull().bg(th.background).clip();
        defer root.end();
        sidebar(c, a);
        const main = ui.div(c).column().grow().w(0).hFull().clip();
        defer main.end();
        switch (a.page) {
            .overview => overview(c, a),
            .processes => @import("view_procs.zig").page(c, a),
            .cpu => hw.cpuPage(c, a),
            .memory => hw.memoryPage(c, a),
            .gpu => hw.gpuPage(c, a),
            .disk => hw.diskPage(c, a),
            .network => @import("view_net.zig").page(c, a),
            .energy => hw.energyPage(c, a),
            .apps => @import("view_apps.zig").page(c, a),
            .cleanup => @import("view_clean.zig").page(c, a),
            .about => @import("view_about.zig").page(c, a),
        }
    }
    @import("view_procs.zig").dialog(c, a);
    @import("view_apps.zig").dialog(c, a);
    @import("view_clean.zig").dialog(c, a);
    a.toaster.view(c);
}

fn keys(c: *ui.Context, a: *App) void {
    const pages = std.enums.values(app_mod.Page);
    for (pages[0..@min(pages.len, 9)], 0..) |p, i| if (c.shortcut(.{ .key = @as(u21, '1') + @as(u21, @intCast(i)), .cmd = true })) {
        a.page = p;
    };
    const chosen = a.selected != null or a.app_selected != null;
    const asking = a.confirm_quit or a.confirm_uninstall or a.confirm_clean;
    if (!asking and c.shortcut(.{ .key = 'r', .cmd = true })) a.cleaner.scan();
    if (chosen and !asking and c.focus == 0 and c.shortcut(.{ .key = ui.Shortcut.escape })) {
        a.selected = null;
        a.app_selected = null;
    }
}

fn sidebar(c: *ui.Context, a: *App) void {
    const th = c.theme;
    const m = &a.metrics;
    var b: [32]u8 = undefined;
    const frame = ui.div(c).column().w(228).hFull().pl(theme.space.md).py(theme.space.md);
    defer frame.end();
    const side = ui.div(c).column().wFull().grow().p(side_pad).gap(1).rounded(theme.radius.panel).border(theme.of(c).sep).borderW(0.5).glass(.{ .tint = theme.of(c).glass_tint });
    defer side.end();
    navItem(c, a, .overview, "square.grid.2x2", "Overview", "");
    navItem(c, a, .processes, "list.bullet", "Processes", c.print("{d}", .{a.sampler.procs.items.len}));
    sectionLabel(c, "Hardware");
    navItem(c, a, .cpu, "cpu", "CPU", c.print("{d:.0}%", .{m.cpu.busy()}));
    const mem = @as(f32, @floatFromInt(m.memory.used())) / @as(f32, @floatFromInt(@max(1, m.memory.total)));
    navItem(c, a, .memory, "memorychip", "Memory", c.print("{d:.0}%", .{mem * 100}));
    navItem(c, a, .gpu, "cube", "GPU", c.print("{d:.0}%", .{m.gpu.device}));
    navItem(c, a, .disk, "internaldrive", "Disk", c.print("{s}", .{metrics.rate(&b, m.disk.read + m.disk.write)}));
    navItem(c, a, .network, "network", "Network", c.print("{s}", .{metrics.rate(&b, m.net.in + m.net.out)}));
    navItem(c, a, .energy, "bolt.fill", "Energy", "");
    sectionLabel(c, "System");
    navItem(c, a, .apps, "square.grid.3x3.fill", "Apps", if (a.inventory.loaded) c.print("{d}", .{a.inventory.apps.items.len}) else "");
    navItem(c, a, .cleanup, "sparkles", "Cleanup", if (a.cleaner.scanned) size(c, a.cleaner.total()) else "");
    navItem(c, a, .about, "laptopcomputer", "About This Mac", "");
    ui.spacer(c);
    const foot = ui.div(c).column().wFull().px(8).gap(2);
    defer foot.end();
    ui.text(c, a.machine.name.get(), .{ .size = 12, .weight = .semibold });
    ui.text(c, c.print("{s} · Up {s}", .{ a.machine.chip.get(), uptime(c, time(null) - a.machine.boot) }), .{ .size = 11, .color = th.muted });
}

const side_pad = theme.space.md;
const nav_radius = theme.inner(theme.radius.panel, side_pad - 2);

fn sectionLabel(c: *ui.Context, s: []const u8) void {
    const d = ui.div(c).row().wFull().px(10).pt(14).pb(4);
    defer d.end();
    ui.text(c, s, .{ .size = 11, .weight = .semibold, .color = theme.of(c).label_3 });
}

fn navItem(c: *ui.Context, a: *App, page: app_mod.Page, icon: []const u8, title: []const u8, figure: []const u8) void {
    const p = theme.of(c);
    const on = a.page == page;
    ui.key(c, title);
    var d = ui.div(c).row().wFull().h(28).pl(10).pr(8).gap(theme.space.md).itemsCenter().rounded(nav_radius).control();
    d = if (on) d.bg(p.accent_soft) else d.hover(p.fill);
    defer d.end();
    if (d.clicked()) {
        a.page = page;
        c.changed = true;
    }
    {
        const slot = ui.div(c).row().w(18).h(18).center();
        defer slot.end();
        ui.icon(c, icon, .{ .size = 13, .color = if (on) p.accent else p.label_2 });
    }
    ui.text(c, title, .{ .size = 13, .weight = .medium, .color = p.label });
    ui.spacer(c);
    if (figure.len > 0) ui.text(c, figure, .{ .size = 11, .mono = true, .color = if (on) p.accent else p.label_2 });
}

pub fn header(c: *ui.Context, title: []const u8, sub: []const u8) ui.Div {
    const h = ui.div(c).row().wFull().h(60).px(theme.space.page).gap(theme.space.lg).itemsCenter();
    {
        const t = ui.div(c).column().gap(2).grow().w(0).clip();
        defer t.end();
        ui.text(c, title, .{ .size = 17, .weight = .bold });
        if (sub.len > 0) ui.text(c, sub, .{ .size = 11.5, .color = c.theme.muted });
    }
    return h;
}

const Stat = struct { label: []const u8, value: []const u8 };

const Tile = struct {
    page: app_mod.Page,
    icon: []const u8,
    tint: theme.Hue,
    title: []const u8,
    label: []const u8,
    value: []const u8,
    unit: []const u8,
    stats: [3]Stat,
    series: []const card.Series,
    max: f32 = 100,
    tag: ?[]const u8 = null,
    tag_color: ui.Color = .white,
};

fn tile(c: *ui.Context, a: *App, t: Tile) void {
    const th = c.theme;
    ui.key(c, t.title);
    const box = theme.surface(c, ui.div(c).column().grow().w(0).p(card.pad).gap(theme.space.lg), card.radius).control().hover(th.surface.mix(theme.hue(c, t.tint), 0.045));
    defer box.end();
    if (box.clicked()) a.page = t.page;
    {
        const h = card.head(c, t.icon, t.tint, t.title);
        defer h.end();
        if (t.tag) |s| card.tag(c, s, t.tag_color);
        ui.icon(c, "chevron.right", .{ .size = 10, .weight = .bold, .color = th.muted });
    }
    card.big(c, t.label, t.value, t.unit);
    {
        const r = ui.div(c).row().wFull().gap(10);
        defer r.end();
        for (t.stats) |s| card.stat(c, s.label, s.value, "");
    }
    card.chart(c, a, c.print("mini-{s}", .{t.title}), t.tint, t.series, .{ .rows = 6, .dot = 4, .gap = 2.5, .axis = false, .max = t.max, .pad = 8 });
}

fn split(text: []const u8) [2][]const u8 {
    const sp = std.mem.indexOfScalar(u8, text, ' ') orelse return .{ text, "" };
    return .{ text[0..sp], text[sp + 1 ..] };
}

fn overview(c: *ui.Context, a: *App) void {
    const m = &a.metrics;
    const sy = a.sampler.system;
    var b: [8][32]u8 = undefined;
    card.pageHeader(c, a, "Overview", a.machine.name.get(), true);
    const body = ui.div(c).column().wFull().grow().scrollY().px(20).pb(20).gap(14);
    defer body.end();
    var tiles: TileRows = .{ .per_row = if (narrow(c)) 2 else 3 };
    {
        tiles.next(c);
        tile(c, a, .{
            .page = .cpu,
            .icon = "cpu",
            .tint = card.cpu_tint,
            .title = "CPU",
            .label = "Now",
            .value = c.print("{d:.0}", .{m.cpu.busy()}),
            .unit = "%",
            .stats = .{ .{ .label = "User", .value = c.print("{d:.0}%", .{m.cpu.user}) }, .{ .label = "System", .value = c.print("{d:.0}%", .{m.cpu.system}) }, .{ .label = "Temperature", .value = hw.temp(c, m.temps.cpu) } },
            .series = &hw.cpu_series,
        });
        const used = split(size(c, m.memory.used()));
        tiles.next(c);
        tile(c, a, .{
            .page = .memory,
            .icon = "memorychip",
            .tint = card.memory_tint,
            .title = "Memory",
            .label = c.print("In use of {s}", .{procs.bytes(&b[1], m.memory.total)}),
            .value = used[0],
            .unit = used[1],
            .stats = .{ .{ .label = "App", .value = size(c, m.memory.app) }, .{ .label = "Wired", .value = size(c, m.memory.wired) }, .{ .label = "Compressed", .value = size(c, m.memory.compressed) } },
            .series = &hw.memory_series,
            .max = 1,
            .tag = if (m.memory.level != .normal) m.memory.level.title() else null,
            .tag_color = hw.pressureColor(c, m.memory.level),
        });
        const start = since(a);
        tiles.next(c);
        tile(c, a, .{
            .page = .gpu,
            .icon = "cube",
            .tint = card.gpu_tint,
            .title = "GPU",
            .label = a.machine.chip.get(),
            .value = c.print("{d:.1}", .{m.gpu.device}),
            .unit = "%",
            .stats = .{ .{ .label = "Memory", .value = size(c, m.gpu.in_use) }, .{ .label = "Average", .value = c.print("{d:.0}%", .{m.history.average(start, "gpu")}) }, .{ .label = "Peak", .value = c.print("{d:.0}%", .{m.history.peak(start, "gpu")}) } },
            .series = &hw.gpu_series,
        });
    }
    {
        const free = split(size(c, sy.disk_free));
        tiles.next(c);
        tile(c, a, .{
            .page = .disk,
            .icon = "internaldrive",
            .tint = card.disk_tint,
            .title = "Disk",
            .label = c.print("Free of {s}", .{procs.bytes(&b[1], sy.disk_total)}),
            .value = free[0],
            .unit = free[1],
            .stats = .{ .{ .label = "Reading", .value = rate(c, m.disk.read) }, .{ .label = "Writing", .value = rate(c, m.disk.write) }, .{ .label = "Written", .value = size(c, m.disk.written_total) } },
            .series = &hw.disk_series,
            .max = hw.diskMax(a),
        });
        const down = split(rate(c, m.net.in));
        tiles.next(c);
        tile(c, a, .{
            .page = .network,
            .icon = "network",
            .tint = card.network_tint,
            .title = "Network",
            .label = "Downloading",
            .value = down[0],
            .unit = down[1],
            .stats = .{ .{ .label = "Uploading", .value = rate(c, m.net.out) }, .{ .label = "Received", .value = size(c, m.net.received) }, .{ .label = "Sent", .value = c.print("{s}", .{procs.bytes(&b[0], m.net.sent)}) } },
            .series = &@import("view_net.zig").series,
            .max = @import("view_net.zig").netMax(a),
        });
        const drawing = split(watts(c, sy.power));
        tiles.next(c);
        tile(c, a, .{
            .page = .energy,
            .icon = "bolt.fill",
            .tint = card.energy_tint,
            .title = "Power",
            .label = "Apps drawing",
            .value = drawing[0],
            .unit = drawing[1],
            .stats = .{ .{ .label = "Average", .value = c.print("{s}", .{metrics.watts(&b[2], m.history.average(since(a), "power"))}) }, .{ .label = "Processor", .value = hw.temp(c, m.temps.cpu) }, .{ .label = "Thermal", .value = m.thermal.title() } },
            .series = &hw.power_series,
            .max = hw.powerMax(a),
        });
    }
    tiles.end();
    {
        var r = card.pair(c);
        defer r.end();
        hw.memoryByType(c, a);
        {
            const box = card.half(c);
            defer box.end();
            {
                const h = card.head(c, "square.grid.2x2", card.memory_tint, "Memory by App");
                defer h.end();
                var total: u64 = 0;
                for (a.everyone.groups.items) |g| total += g.memory;
                ui.text(c, c.print("{s} in all", .{procs.bytes(&b[0], total)}), .{ .size = 11.5, .color = c.theme.muted });
            }
            card.treemap(c, a, 104);
        }
        if (narrow(c)) {
            r.end();
            ui.key(c, "energy-row");
            r = card.pair(c);
        }
        {
            const box = card.half(c);
            defer box.end();
            {
                const h = card.head(c, "bolt.fill", card.energy_tint, "Energy by App");
                defer h.end();
                ui.text(c, c.print("{s} in all", .{metrics.watts(&b[0], sy.power)}), .{ .size = 11.5, .color = c.theme.muted });
            }
            card.energyRows(c, a, 4);
        }
    }
    cleanupCard(c, a);
}

fn since(a: *App) f64 {
    return if (a.metrics.history.last()) |s| s.t - a.range.seconds() else 0;
}

fn cleanupCard(c: *ui.Context, a: *App) void {
    const th = c.theme;
    var b: [32]u8 = undefined;
    const box = theme.surface(c, ui.div(c).row().wFull().p(card.pad).gap(theme.space.xl).itemsCenter(), card.radius);
    defer box.end();
    {
        const badge = ui.div(c).row().w(36).h(36).center().rounded(theme.radius.control).bg(theme.of(c).accent_soft);
        defer badge.end();
        ui.icon(c, "sparkles", .{ .size = 17, .color = th.accent });
    }
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
