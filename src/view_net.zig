const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const metrics = @import("metrics.zig");
const procs = @import("procs.zig");
const card = @import("view_card.zig");
const view = @import("view.zig");
const App = @import("app.zig").App;

extern "c" fn getifaddrs(out: *?*IfAddrs) c_int;
extern "c" fn freeifaddrs(list: *IfAddrs) void;
extern "c" fn inet_ntop(af: c_int, src: *const anyopaque, dst: [*]u8, size: u32) ?[*:0]const u8;

const IfAddrs = extern struct {
    next: ?*IfAddrs,
    name: [*:0]const u8,
    flags: c_uint,
    addr: ?*const SockAddr,
    netmask: ?*const anyopaque,
    dstaddr: ?*const anyopaque,
    data: ?*anyopaque,
};

const SockAddr = extern struct { len: u8, family: u8, port: u16, addr: [4]u8 };

const AF_INET = 2;
const IFF_UP = 0x1;
const IFF_LOOPBACK = 0x8;

fn down(s: metrics.Sample) f32 {
    return s.net_in;
}
fn up(s: metrics.Sample) f32 {
    return s.net_out;
}

pub const download_color = 0x30b0c7;
pub const upload_color = 0xaf52de;

pub const series = [_]card.Series{ .{ .color = download_color, .value = down }, .{ .color = upload_color, .value = up } };

pub fn netMax(a: *App) f32 {
    const h = &a.metrics.history;
    const since = if (h.last()) |s| s.t - a.range.seconds() else 0;
    var m: f32 = 100e3;
    var i = h.len;
    while (i > 0) : (i -= 1) {
        const s = h.get(i - 1);
        if (s.t < since) break;
        m = @max(m, s.net_in + s.net_out);
    }
    return m * 1.1;
}

pub fn page(c: *ui.Context, a: *App) void {
    const n = &a.metrics.net;
    card.pageHeader(c, a, "Network", "All interfaces", true);
    const body = ui.div(c).column().wFull().grow().scrollY().px(20).pb(20).gap(14);
    defer body.end();
    {
        const box = card.card(c);
        defer box.end();
        {
            const h = card.head(c, "network", card.network_tint, "Network Activity");
            defer h.end();
            card.legend(c, upload_color, "Upload");
            card.legend(c, download_color, "Download");
        }
        {
            const r = ui.div(c).row().wFull().gap(16).itemsStart();
            defer r.end();
            {
                const l = ui.div(c).column().w(170);
                defer l.end();
                const rate = view.rate(c, n.in);
                const sp = std.mem.indexOfScalar(u8, rate, ' ') orelse rate.len;
                card.big(c, "Downloading", rate[0..sp], if (sp < rate.len) rate[sp + 1 ..] else "");
            }
            card.stat(c, "Uploading", view.rate(c, n.out), "");
            card.stat(c, "Received", view.size(c, n.received), "since startup");
            card.stat(c, "Sent", view.size(c, n.sent), "since startup");
        }
        card.chart(c, a, "net-chart", card.network_tint, &series, .{ .rows = 16, .max = netMax(a) });
    }
    const box = card.card(c);
    defer box.end();
    {
        const h = card.head(c, "point.3.connected.trianglepath.dotted", card.network_tint, "Interfaces");
        h.end();
    }
    var list: ?*IfAddrs = null;
    if (getifaddrs(&list) != 0) return;
    defer if (list) |l| freeifaddrs(l);
    var it = list;
    var shown: usize = 0;
    while (it) |ifa| : (it = ifa.next) {
        const addr = ifa.addr orelse continue;
        if (addr.family != AF_INET or ifa.flags & IFF_UP == 0 or ifa.flags & IFF_LOOPBACK != 0) continue;
        var ip: [64]u8 = undefined;
        const text = inet_ntop(AF_INET, &addr.addr, &ip, ip.len) orelse continue;
        shown += 1;
        card.kv(c, std.mem.span(ifa.name), std.mem.span(text));
    }
    if (shown == 0) ui.text(c, "No interface is connected.", .{ .size = 12, .color = c.theme.muted });
}
