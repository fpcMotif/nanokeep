const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const metrics = @import("metrics.zig");
const procs = @import("procs.zig");
const card = @import("view_card.zig");
const view = @import("view.zig");
const App = @import("app.zig").App;

extern "c" fn time(t: ?*i64) i64;
extern "c" fn localtime_r(t: *const i64, out: *Tm) ?*Tm;
extern "c" fn strftime(buf: [*]u8, max: usize, fmt: [*:0]const u8, tm: *const Tm) usize;

const Tm = extern struct { sec: c_int, min: c_int, hour: c_int, mday: c_int, mon: c_int, year: c_int, wday: c_int, yday: c_int, isdst: c_int, gmtoff: c_long, zone: ?[*:0]const u8 };

pub fn symbolFor(name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, name, "MacBook")) return "laptopcomputer";
    if (std.mem.startsWith(u8, name, "Mac mini")) return "macmini";
    if (std.mem.startsWith(u8, name, "Mac Studio")) return "macstudio";
    if (std.mem.startsWith(u8, name, "Mac Pro")) return "macpro.gen3";
    if (std.mem.startsWith(u8, name, "iMac")) return "desktopcomputer";
    return "desktopcomputer";
}

pub fn page(c: *ui.Context, a: *App) void {
    const mc = &a.machine;
    const th = c.theme;
    const up = view.uptime(c, time(null) - mc.boot);
    {
        const h = @import("view.zig").header(c, "About This Mac", mc.name.get());
        defer h.end();
        card.pauseButton(c, a);
    }
    const body = ui.div(c).column().wFull().grow().scrollY().px(20).pb(20).gap(14);
    defer body.end();
    {
        const hero = ui.div(c).row().wFull().px(28).py(26).gap(26).itemsCenter().rounded(14).bg(th.surface);
        defer hero.end();
        {
            const pic = ui.div(c).row().w(96).h(72).center();
            defer pic.end();
            ui.icon(c, symbolFor(mc.name.get()), .{ .size = 64, .color = th.muted });
        }
        const t = ui.div(c).column().gap(6);
        defer t.end();
        ui.text(c, mc.name.get(), .{ .size = 24, .weight = .bold });
        ui.text(c, c.print("{s} · {s}", .{ mc.chip.get(), view.size(c, mc.memory) }), .{ .size = 13, .color = th.muted });
        const tags = ui.div(c).row().gap(8).pt(4);
        defer tags.end();
        card.tag(c, c.print("macOS {s} ({s})", .{ mc.os.get(), mc.build.get() }), .hex(card.cpu_tint));
        card.tag(c, c.print("Up {s}", .{up}), .hex(card.memory_tint));
    }
    {
        const r = card.pair(c);
        defer r.end();
        {
            const box = card.half(c);
            defer box.end();
            {
                const h = card.head(c, "cpu", card.cpu_tint, "Hardware");
                h.end();
            }
            card.kv(c, "Model", mc.name.get());
            card.kv(c, "Model identifier", mc.model.get());
            card.kv(c, "Chip", mc.chip.get());
            card.kv(c, "CPU cores", if (mc.performance > 0) c.print("{d} ({d} Performance, {d} Efficiency)", .{ mc.cores, mc.performance, mc.efficiency }) else c.print("{d}", .{mc.cores}));
            card.kv(c, "GPU cores", c.print("{d}", .{mc.gpu_cores}));
            card.kv(c, "Memory", view.size(c, mc.memory));
            card.kv(c, "Architecture", if (mc.arm) "Apple silicon" else "Intel");
            serial(c, a);
        }
        {
            const box = card.half(c);
            defer box.end();
            {
                const h = card.head(c, "apple.logo", card.about_tint, "Software");
                h.end();
            }
            card.kv(c, "System", c.print("macOS {s}", .{mc.os.get()}));
            card.kv(c, "Build", mc.build.get());
            card.kv(c, "Kernel", c.print("Darwin {s}", .{mc.kernel.get()}));
            card.kv(c, "Computer name", mc.host.get());
            card.kv(c, "Started", started(c, mc.boot));
            card.kv(c, "Uptime", up);
            card.kv(c, "Processes", c.print("{d}", .{a.sampler.procs.items.len}));
        }
    }
    const r = card.pair(c);
    defer r.end();
    {
        const box = card.half(c);
        defer box.end();
        {
            const h = card.head(c, "display", card.network_tint, "Displays");
            h.end();
        }
        for (mc.displays[0..mc.display_count], 0..) |d, i| {
            ui.key(c, c.print("display-{d}", .{i}));
            card.kv(c, if (d.main) "Main display" else c.print("Display {d}", .{i + 1}), c.print("{d} × {d} @{d}x", .{ d.width, d.height, d.scale }));
        }
    }
    {
        const box = card.half(c);
        defer box.end();
        {
            const h = card.head(c, "internaldrive", card.disk_tint, "Storage");
            h.end();
        }
        const sy = a.sampler.system;
        card.kv(c, mc.volume.get(), c.print("{s} free of {s}", .{ view.size(c, sy.disk_free), view.size(c, sy.disk_total) }));
    }
}

fn serial(c: *ui.Context, a: *App) void {
    ui.key(c, "serial");
    const r = ui.div(c).row().wFull().h(22).gap(8).itemsCenter();
    defer r.end();
    {
        const l = ui.div(c).row().grow().w(0);
        defer l.end();
        ui.text(c, "Serial number", .{ .size = 12.5, .color = c.theme.muted });
    }
    if (a.show_serial) {
        ui.text(c, a.machine.serial.get(), .{ .size = 12.5, .weight = .semibold, .mono = true });
        return;
    }
    const link = ui.div(c).row().control();
    defer link.end();
    if (link.clicked()) a.show_serial = true;
    ui.text(c, "Show", .{ .size = 12.5, .weight = .semibold, .color = c.theme.accent });
}

fn started(c: *ui.Context, boot: i64) []const u8 {
    var tm: Tm = undefined;
    if (localtime_r(&boot, &tm) == null) return "–";
    var buf: [64]u8 = undefined;
    const n = strftime(&buf, buf.len, "%a, %b %e, %Y, %H:%M", &tm);
    return c.print("{s}", .{buf[0..n]});
}
