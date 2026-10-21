const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const metrics = @import("metrics.zig");
const procs = @import("procs.zig");
const iokit = @import("iokit.zig");
const card = @import("view_card.zig");
const view = @import("view.zig");
const App = @import("app.zig").App;

extern "c" fn time(t: ?*i64) i64;

fn body(c: *ui.Context) ui.Div {
    return ui.div(c).column().wFull().grow().scrollY().px(20).pb(20).gap(14);
}

fn user(s: metrics.Sample) f32 {
    return s.cpu_user;
}
fn system(s: metrics.Sample) f32 {
    return s.cpu_system;
}
fn wired(s: metrics.Sample) f32 {
    return s.mem_wired;
}
fn compressed(s: metrics.Sample) f32 {
    return s.mem_compressed;
}
fn appMem(s: metrics.Sample) f32 {
    return s.mem_app;
}
fn gpu(s: metrics.Sample) f32 {
    return s.gpu;
}
fn read(s: metrics.Sample) f32 {
    return s.disk_read;
}
fn write(s: metrics.Sample) f32 {
    return s.disk_write;
}
fn power(s: metrics.Sample) f32 {
    return s.power;
}

pub const cpu_series = [_]card.Series{ .{ .color = card.system_color, .value = system }, .{ .color = card.user_color, .value = user } };
pub const memory_series = [_]card.Series{ .{ .color = card.wired_color, .value = wired }, .{ .color = card.compressed_color, .value = compressed }, .{ .color = card.app_color, .value = appMem } };
pub const gpu_series = [_]card.Series{.{ .color = card.gpu_tint, .value = gpu }};
pub const disk_series = [_]card.Series{ .{ .color = card.read_color, .value = read }, .{ .color = card.write_color, .value = write } };
pub const power_series = [_]card.Series{.{ .color = card.energy_tint, .value = power }};

pub fn diskMax(a: *App) f32 {
    const since = if (a.metrics.history.last()) |s| s.t - a.range.seconds() else 0;
    const h = &a.metrics.history;
    var m: f32 = 1e6;
    var i = h.len;
    while (i > 0) : (i -= 1) {
        const s = h.get(i - 1);
        if (s.t < since) break;
        m = @max(m, s.disk_read + s.disk_write);
    }
    return m * 1.1;
}

pub fn powerMax(a: *App) f32 {
    const since = if (a.metrics.history.last()) |s| s.t - a.range.seconds() else 0;
    return @max(5, a.metrics.history.peak(since, "power") * 1.1);
}

pub fn pressureColor(p: metrics.Pressure) ui.Color {
    return switch (p) {
        .normal => .hex(card.memory_tint),
        .elevated => .hex(0xff9500),
        .critical => .hex(0xff3b30),
    };
}

pub fn temp(c: *ui.Context, t: f32) []const u8 {
    return if (t > 0) c.print("{d:.0} °C", .{t}) else "–";
}

pub fn cpuPage(c: *ui.Context, a: *App) void {
    const m = &a.metrics;
    const mc = &a.machine;
    card.pageHeader(c, a, "CPU", c.print("{s} · {d} Performance + {d} Efficiency cores", .{ mc.chip.get(), mc.performance, mc.efficiency }), true);
    const page = body(c);
    defer page.end();
    {
        const box = card.card(c);
        defer box.end();
        {
            const h = card.head(c, "cpu", card.cpu_tint, "Processor Load");
            defer h.end();
            card.legend(c, card.user_color, "User");
            card.legend(c, card.system_color, "System");
        }
        {
            const r = ui.div(c).row().wFull().gap(16).itemsStart();
            defer r.end();
            {
                const l = ui.div(c).column().w(150);
                defer l.end();
                card.big(c, "Now", c.print("{d:.0}", .{m.cpu.busy()}), "%");
            }
            const since = if (m.history.last()) |s| s.t - a.range.seconds() else 0;
            card.stat(c, "User", c.print("{d:.0}%", .{m.cpu.user}), "");
            card.stat(c, "System", c.print("{d:.0}%", .{m.cpu.system}), "");
            card.stat(c, "Temperature", temp(c, m.temps.cpu), if (m.temps.cpu_max > 0) c.print("hottest {d:.0} °C", .{m.temps.cpu_max}) else "");
            card.stat(c, "Average", c.print("{d:.0}%", .{m.history.average(since, "cpu_user") + m.history.average(since, "cpu_system")}), "");
        }
        card.chart(c, a, "cpu-chart", card.cpu_tint, &cpu_series, .{ .rows = 16 });
    }
    {
        const r = card.pair(c);
        defer r.end();
        {
            const box = card.half(c);
            defer box.end();
            {
                const h = card.head(c, "square.grid.3x3", card.cpu_tint, "Cores");
                defer h.end();
                ui.text(c, c.print("{d} logical processors", .{m.cpu.count}), .{ .size = 11.5, .color = c.theme.muted });
            }
            const eff = @min(m.cpu.efficiency, m.cpu.count);
            cores(c, "Performance Cores", m.cpu.cores[eff..m.cpu.count], eff, .hex(card.cpu_tint));
            if (eff > 0) cores(c, "Efficiency Cores", m.cpu.cores[0..eff], 0, .hex(0xd4920a));
        }
        {
            const box = card.half(c);
            defer box.end();
            {
                const h = card.head(c, "waveform.path.ecg", card.about_tint, "Activity");
                h.end();
            }
            const load = m.cpu.load;
            const saturated = load[0] > @as(f64, @floatFromInt(@max(1, m.cpu.count)));
            card.kv(c, "Load, last minute", if (saturated) c.print("{d:.1} · Saturated", .{load[0]}) else c.print("{d:.1}", .{load[0]}));
            card.kv(c, "Load, 5 minutes", c.print("{d:.1}", .{load[1]}));
            card.kv(c, "Load, 15 minutes", c.print("{d:.1}", .{load[2]}));
            card.kv(c, "Processes", c.print("{d}", .{a.sampler.procs.items.len}));
            card.kv(c, "Threads", c.print("{d}", .{a.sampler.system.threads}));
            card.kv(c, "Uptime", view.uptime(c, time(null) - mc.boot));
        }
    }
    card.topList(c, a, "Using the Most CPU", "cpu", card.cpu_tint, .cpu, .cpu);
}

fn cores(c: *ui.Context, title: []const u8, loads: []const f32, first: usize, color: ui.Color) void {
    ui.key(c, title);
    const col = ui.div(c).column().wFull().gap(6);
    defer col.end();
    ui.text(c, title, .{ .size = 11.5, .weight = .semibold, .color = c.theme.muted });
    var i: usize = 0;
    while (i < loads.len) : (i += 2) {
        ui.key(c, c.print("core-{d}", .{first + i}));
        const r = ui.div(c).row().wFull().gap(16);
        defer r.end();
        for (0..2) |k| {
            const at = i + k;
            ui.key(c, c.print("c{d}", .{k}));
            const cell = ui.div(c).row().grow().w(0).gap(8).itemsCenter();
            defer cell.end();
            if (at >= loads.len) continue;
            {
                const l = ui.div(c).row().w(52);
                defer l.end();
                ui.text(c, c.print("Core {d}", .{first + at + 1}), .{ .size = 11.5 });
            }
            card.bar(c, loads[at] / 100, color, 5);
            {
                const v = ui.div(c).row().w(38).justifyEnd();
                defer v.end();
                ui.text(c, c.print("{d:.0}%", .{loads[at]}), .{ .size = 11.5, .weight = .semibold });
            }
        }
    }
}

pub fn memorySlices(m: *const metrics.Memory, th: anytype) [5]card.Slice {
    return .{
        .{ .color = .hex(card.app_color), .value = @floatFromInt(m.app) },
        .{ .color = .hex(card.wired_color), .value = @floatFromInt(m.wired) },
        .{ .color = .hex(card.compressed_color), .value = @floatFromInt(m.compressed) },
        .{ .color = .hex(card.cached_color), .value = @floatFromInt(m.cached) },
        .{ .color = th.border, .value = @floatFromInt(m.free()) },
    };
}

pub fn memoryByType(c: *ui.Context, a: *App) void {
    const m = &a.metrics.memory;
    const box = card.half(c);
    defer box.end();
    {
        const h = card.head(c, "memorychip", card.memory_tint, "Memory by Type");
        h.end();
    }
    const r = ui.div(c).row().wFull().gap(18).itemsCenter();
    defer r.end();
    const slices = memorySlices(m, c.theme);
    const used: f32 = @as(f32, @floatFromInt(m.used())) / @as(f32, @floatFromInt(@max(1, m.total)));
    card.donut(c, 104, &slices, c.print("{d:.0}%", .{used * 100}), "in use");
    const list = ui.div(c).column().grow().w(0).gap(1);
    defer list.end();
    const names = [_][]const u8{ "App", "Wired", "Compressed", "Cached", "Free" };
    const values = [_]u64{ m.app, m.wired, m.compressed, m.cached, m.free() };
    var b: [32]u8 = undefined;
    for (names, values, slices) |n, v, s| {
        ui.key(c, n);
        const row = ui.div(c).row().wFull().h(20).gap(7).itemsCenter();
        defer row.end();
        card.dot(c, 7, s.color);
        {
            const l = ui.div(c).row().grow().w(0);
            defer l.end();
            ui.text(c, n, .{ .size = 12 });
        }
        ui.text(c, c.print("{s}", .{procs.bytes(&b, v)}), .{ .size = 12, .color = c.theme.muted });
    }
}

pub fn memoryPage(c: *ui.Context, a: *App) void {
    const m = &a.metrics.memory;
    var b: [3][32]u8 = undefined;
    card.pageHeader(c, a, "Memory", c.print("{s} unified memory", .{procs.bytes(&b[0], m.total)}), true);
    const page = body(c);
    defer page.end();
    {
        const box = card.card(c);
        defer box.end();
        {
            const h = card.head(c, "memorychip", card.memory_tint, "Memory");
            defer h.end();
            card.legend(c, card.app_color, "App");
            card.legend(c, card.compressed_color, "Compressed");
            card.legend(c, card.wired_color, "Wired");
            if (m.level != .normal) card.tag(c, m.level.title(), pressureColor(m.level));
        }
        {
            const r = ui.div(c).row().wFull().gap(16).itemsStart();
            defer r.end();
            {
                const l = ui.div(c).column().w(150);
                defer l.end();
                const used = view.size(c, m.used());
                const sp = std.mem.indexOfScalar(u8, used, ' ') orelse used.len;
                card.big(c, c.print("In use of {s}", .{procs.bytes(&b[2], m.total)}), used[0..sp], if (sp < used.len) used[sp + 1 ..] else "");
            }
            card.stat(c, "App", view.size(c, m.app), "");
            card.stat(c, "Wired", view.size(c, m.wired), "");
            card.stat(c, "Compressed", view.size(c, m.compressed), "");
            card.stat(c, "Cached", c.print("{s}", .{procs.bytes(&b[0], m.cached)}), "");
        }
        const slices = memorySlices(m, c.theme);
        card.stacked(c, &slices, 7);
        card.chart(c, a, "mem-chart", card.memory_tint, &memory_series, .{ .rows = 16, .max = 1 });
    }
    {
        const r = card.pair(c);
        defer r.end();
        memoryByType(c, a);
        {
            const box = card.half(c);
            defer box.end();
            {
                const h = card.head(c, "gauge.with.dots.needle.33percent", 0xff9500, "Pressure");
                defer h.end();
                if (m.level != .normal) card.tag(c, m.level.title(), pressureColor(m.level));
            }
            {
                const ring = ui.div(c).row().wFull().justifyCenter();
                defer ring.end();
                const color = pressureColor(m.level);
                card.donut(c, 104, &.{ .{ .color = color, .value = m.pressure }, .{ .color = color.alpha(0.2), .value = 100 - m.pressure } }, c.print("{d:.0}%", .{m.pressure}), "pressure");
            }
            card.kv(c, "Page-ins", c.print("{d:.0} /s", .{m.pageins}));
            card.kv(c, "Swap-outs", c.print("{d:.0} /s", .{m.swapouts}));
        }
        {
            const box = card.half(c);
            defer box.end();
            {
                const h = card.head(c, "externaldrive", card.compressed_color, "Swap");
                h.end();
            }
            const used = view.size(c, m.swap_used);
            const sp = std.mem.indexOfScalar(u8, used, ' ') orelse used.len;
            card.big(c, "Written to disk", used[0..sp], if (sp < used.len) used[sp + 1 ..] else "");
            card.bar(c, if (m.swap_total > 0) @as(f32, @floatFromInt(m.swap_used)) / @as(f32, @floatFromInt(m.swap_total)) else 0, .hex(card.compressed_color), 6);
            card.kv(c, "Swap size", view.size(c, m.swap_total));
            card.kv(c, "Compressed", view.size(c, m.compressed));
        }
    }
    {
        const box = card.card(c);
        defer box.end();
        {
            const h = card.head(c, "square.grid.2x2", card.memory_tint, "Memory by App");
            defer h.end();
            var total: u64 = 0;
            for (a.everyone.groups.items) |g| total += g.memory;
            ui.text(c, c.print("{s} in all", .{procs.bytes(&b[0], total)}), .{ .size = 11.5, .color = c.theme.muted });
        }
        card.treemap(c, a, 130);
    }
    card.topList(c, a, "Using the Most Memory", "memorychip", card.memory_tint, .memory, .memory);
}

pub fn gpuPage(c: *ui.Context, a: *App) void {
    const g = &a.metrics.gpu;
    const mc = &a.machine;
    var b: [32]u8 = undefined;
    card.pageHeader(c, a, "GPU", c.print("{s} · {d} cores", .{ mc.chip.get(), mc.gpu_cores }), true);
    const page = body(c);
    defer page.end();
    const since = if (a.metrics.history.last()) |s| s.t - a.range.seconds() else 0;
    {
        const box = card.card(c);
        defer box.end();
        {
            const h = card.head(c, "cube", card.gpu_tint, "Graphics");
            h.end();
        }
        {
            const r = ui.div(c).row().wFull().gap(16).itemsStart();
            defer r.end();
            {
                const l = ui.div(c).column().w(150);
                defer l.end();
                card.big(c, mc.chip.get(), c.print("{d:.0}", .{g.device}), "%");
            }
            card.stat(c, "Renderer", c.print("{d:.0}%", .{g.renderer}), "");
            card.stat(c, "Tiler", c.print("{d:.0}%", .{g.tiler}), "");
            card.stat(c, "Memory", view.size(c, g.in_use), "");
            card.stat(c, "Peak", c.print("{d:.0}%", .{a.metrics.history.peak(since, "gpu")}), "");
        }
        card.chart(c, a, "gpu-chart", card.gpu_tint, &gpu_series, .{ .rows = 16 });
    }
    const r = card.pair(c);
    defer r.end();
    {
        const box = card.half(c);
        defer box.end();
        {
            const h = card.head(c, "info.circle", card.gpu_tint, "About");
            h.end();
        }
        card.kv(c, "Model", mc.chip.get());
        card.kv(c, "Cores", c.print("{d}", .{mc.gpu_cores}));
        card.kv(c, "Memory in use", view.size(c, g.in_use));
        card.kv(c, "Memory allocated", c.print("{s}", .{procs.bytes(&b, g.allocated)}));
        card.kv(c, "Unified memory", c.print("{s}", .{procs.bytes(&b, mc.memory)}));
    }
    {
        const box = card.half(c);
        defer box.end();
        {
            const h = card.head(c, "waveform.path.ecg", card.gpu_tint, "Engines");
            h.end();
        }
        engine(c, "Device", g.device);
        engine(c, "Renderer", g.renderer);
        engine(c, "Tiler", g.tiler);
    }
}

fn engine(c: *ui.Context, title: []const u8, v: f32) void {
    ui.key(c, title);
    const r = ui.div(c).row().wFull().h(22).gap(12).itemsCenter();
    defer r.end();
    {
        const l = ui.div(c).row().w(90);
        defer l.end();
        ui.text(c, title, .{ .size = 12.5, .color = c.theme.muted });
    }
    card.bar(c, v / 100, .hex(card.gpu_tint), 5);
    {
        const t = ui.div(c).row().w(44).justifyEnd();
        defer t.end();
        ui.text(c, c.print("{d:.0}%", .{v}), .{ .size = 12.5, .weight = .semibold });
    }
}

pub fn diskPage(c: *ui.Context, a: *App) void {
    const d = &a.metrics.disk;
    const sy = a.sampler.system;
    var b: [3][32]u8 = undefined;
    card.pageHeader(c, a, "Disk", "1 volume", true);
    const page = body(c);
    defer page.end();
    {
        const box = card.card(c);
        defer box.end();
        {
            const h = card.head(c, "internaldrive", card.disk_tint, "Disk Activity");
            defer h.end();
            card.legend(c, card.write_color, "Write");
            card.legend(c, card.read_color, "Read");
        }
        {
            const r = ui.div(c).row().wFull().gap(16).itemsStart();
            defer r.end();
            {
                const l = ui.div(c).column().w(170);
                defer l.end();
                const both = view.rate(c, d.read + d.write);
                const sp = std.mem.indexOfScalar(u8, both, ' ') orelse both.len;
                card.big(c, "Reading and writing", both[0..sp], if (sp < both.len) both[sp + 1 ..] else "");
            }
            card.stat(c, "Reading", view.rate(c, d.read), "");
            card.stat(c, "Writing", view.rate(c, d.write), "");
            card.stat(c, "Read", c.print("{s}", .{procs.bytes(&b[0], d.read_total)}), "since startup");
            card.stat(c, "Written", c.print("{s}", .{procs.bytes(&b[1], d.written_total)}), "since startup");
        }
        card.chart(c, a, "disk-chart", card.disk_tint, &disk_series, .{ .rows = 16, .max = diskMax(a) });
    }
    {
        const box = card.card(c);
        defer box.end();
        {
            const h = card.head(c, "internaldrive", card.disk_tint, a.machine.volume.get());
            h.end();
        }
        const free = view.size(c, sy.disk_free);
        const sp = std.mem.indexOfScalar(u8, free, ' ') orelse free.len;
        card.big(c, c.print("Free of {s}", .{procs.bytes(&b[1], sy.disk_total)}), free[0..sp], if (sp < free.len) free[sp + 1 ..] else "");
        const used = sy.disk_total -| sy.disk_free;
        card.bar(c, @as(f32, @floatFromInt(used)) / @as(f32, @floatFromInt(@max(1, sy.disk_total))), .hex(card.disk_tint), 6);
        const r = ui.div(c).row().wFull().gap(16);
        defer r.end();
        card.stat(c, "Used", view.size(c, used), "");
        card.stat(c, "Format", a.machine.format.get(), "");
        card.stat(c, "Device", a.machine.device.get(), "");
    }
    card.topList(c, a, "Reading and Writing the Most", "internaldrive", card.disk_tint, .disk, .disk);
}

pub fn energyPage(c: *ui.Context, a: *App) void {
    const m = &a.metrics;
    var b: [32]u8 = undefined;
    card.pageHeader(c, a, "Energy", "Power", true);
    const page = body(c);
    defer page.end();
    {
        const r = card.pair(c);
        defer r.end();
        {
            const box = card.half(c);
            defer box.end();
            {
                const h = card.head(c, "bolt.fill", card.energy_tint, "Energy by App");
                defer h.end();
                ui.text(c, c.print("{s} in all", .{metrics.watts(&b, a.sampler.system.power)}), .{ .size = 11.5, .color = c.theme.muted });
            }
            card.energyRows(c, a, 6);
        }
        {
            const box = card.half(c);
            defer box.end();
            {
                const h = card.head(c, "thermometer.medium", card.energy_tint, "Temperatures");
                h.end();
            }
            if (!m.temps.found) ui.text(c, "This Mac doesn't share its sensors.", .{ .size = 12, .color = c.theme.muted });
            if (m.temps.cpu > 0) thermo(c, "Processor", if (m.temps.cpu_max > 0) c.print("hottest {d:.0} °C", .{m.temps.cpu_max}) else "", m.temps.cpu, .hex(0xff9500));
            if (m.temps.storage > 0) thermo(c, "Storage", "", m.temps.storage, .hex(card.memory_tint));
        }
    }
    {
        const r = card.pair(c);
        defer r.end();
        {
            const box = card.half(c);
            defer box.end();
            {
                const h = card.head(c, "cup.and.saucer.fill", card.energy_tint, "Keeping Awake");
                h.end();
            }
            awake(c, a);
        }
        {
            const box = card.half(c);
            defer box.end();
            {
                const h = card.head(c, "powerplug.fill", card.energy_tint, "Power Source");
                h.end();
            }
            card.kv(c, "Drawing from", if (m.power.adapter) "Power Adapter" else "Battery");
            if (m.power.battery) |pct| card.kv(c, "Battery", c.print("{d}%{s}", .{ pct, if (m.power.charging) " · Charging" else "" }));
            if (m.power.minutes_left) |mins| card.kv(c, "Time left", c.print("{d}h {d}m", .{ mins / 60, mins % 60 }));
            card.kv(c, "Thermal state", m.thermal.title());
            card.kv(c, "Apps together", view.watts(c, a.sampler.system.power));
        }
    }
    {
        const box = card.card(c);
        defer box.end();
        {
            const h = card.head(c, "bolt.fill", card.energy_tint, "Energy Over Time");
            h.end();
        }
        card.chart(c, a, "power-chart", card.energy_tint, &power_series, .{ .rows = 12, .max = powerMax(a) });
    }
}

fn thermo(c: *ui.Context, title: []const u8, sub: []const u8, t: f32, color: ui.Color) void {
    ui.key(c, title);
    const r = ui.div(c).row().wFull().gap(12).itemsCenter();
    defer r.end();
    {
        const l = ui.div(c).column().w(96).gap(1);
        defer l.end();
        ui.text(c, title, .{ .size = 12.5 });
        if (sub.len > 0) ui.text(c, sub, .{ .size = 10.5, .color = c.theme.muted });
    }
    card.bar(c, t / 110, color, 5);
    {
        const v = ui.div(c).row().w(52).justifyEnd();
        defer v.end();
        ui.text(c, c.print("{d:.0} °C", .{t}), .{ .size = 12.5, .weight = .semibold });
    }
}

fn awake(c: *ui.Context, a: *App) void {
    var services: usize = 0;
    var shown: usize = 0;
    for (a.awake[0..a.awake_count]) |*as| {
        const p = a.sampler.find(as.pid) orelse {
            services += 1;
            continue;
        };
        if (p.bundle.len == 0) {
            services += 1;
            continue;
        }
        shown += 1;
        ui.key(c, c.print("awake-{d}", .{as.pid}));
        const r = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer r.end();
        {
            const g = ui.div(c).row().w(18).h(18).center().rounded(5).bg(c.theme.muted.alpha(0.18));
            defer g.end();
            ui.icon(c, "app.fill", .{ .size = 10, .color = c.theme.muted });
        }
        {
            const t = ui.div(c).column().grow().w(0).clip();
            defer t.end();
            ui.text(c, p.name, .{ .size = 12.5 });
            if (as.label().len > 0) ui.text(c, as.label(), .{ .size = 10.5, .color = c.theme.muted });
        }
        card.tag(c, if (as.display) "Display" else "System", .hex(card.energy_tint));
    }
    if (shown == 0) ui.text(c, "No app is keeping this Mac awake.", .{ .size = 12, .color = c.theme.muted });
    if (services > 0) ui.text(c, c.print("And {d} system services for a moment.", .{services}), .{ .size = 11.5, .color = c.theme.muted });
}
