const std = @import("std");
const iokit = @import("iokit.zig");

extern "c" fn mach_host_self() c_uint;
extern "c" fn host_processor_info(host: c_uint, flavor: c_int, count: *c_uint, info: *?[*]c_int, info_count: *c_uint) c_int;
extern "c" fn host_statistics64(host: c_uint, flavor: c_int, info: *anyopaque, count: *c_uint) c_int;
extern "c" fn vm_deallocate(task: c_uint, addr: usize, size: usize) c_int;
extern "c" var mach_task_self_: c_uint;
extern "c" var vm_kernel_page_size: usize;
extern "c" fn sysctlbyname(name: [*:0]const u8, old: ?*anyopaque, oldlen: ?*usize, new: ?*const anyopaque, newlen: usize) c_int;
extern "c" fn getloadavg(load: *[3]f64, n: c_int) c_int;

const PROCESSOR_CPU_LOAD_INFO = 2;
const HOST_VM_INFO64 = 4;

pub const max_cores = 64;
pub const history_len = 1800;

const VmStats = extern struct {
    free_count: u32,
    active_count: u32,
    inactive_count: u32,
    wire_count: u32,
    zero_fill_count: u64,
    reactivations: u64,
    pageins: u64,
    pageouts: u64,
    faults: u64,
    cow_faults: u64,
    lookups: u64,
    hits: u64,
    purges: u64,
    purgeable_count: u32,
    speculative_count: u32,
    decompressions: u64,
    compressions: u64,
    swapins: u64,
    swapouts: u64,
    compressor_page_count: u32,
    throttled_count: u32,
    external_page_count: u32,
    internal_page_count: u32,
    total_uncompressed_pages_in_compressor: u64,
};

const SwapUsage = extern struct { total: u64, avail: u64, used: u64, pagesize: u32, encrypted: bool };

pub const Pressure = enum {
    normal,
    elevated,
    critical,

    pub fn title(p: Pressure) []const u8 {
        return switch (p) {
            .normal => "Normal",
            .elevated => "Elevated",
            .critical => "Critical",
        };
    }
};

pub const Cpu = struct {
    user: f32 = 0,
    system: f32 = 0,
    cores: [max_cores]f32 = @splat(0),
    count: usize = 0,
    efficiency: usize = 0,
    load: [3]f64 = @splat(0),

    pub fn busy(c: Cpu) f32 {
        return c.user + c.system;
    }
};

pub const Memory = struct {
    total: u64 = 0,
    app: u64 = 0,
    wired: u64 = 0,
    compressed: u64 = 0,
    cached: u64 = 0,
    swap_used: u64 = 0,
    swap_total: u64 = 0,
    pressure: f32 = 0,
    level: Pressure = .normal,
    pageins: f32 = 0,
    swapouts: f32 = 0,

    pub fn used(m: Memory) u64 {
        return m.app + m.wired + m.compressed;
    }

    pub fn free(m: Memory) u64 {
        return m.total -| m.used() -| m.cached;
    }
};

pub const Disk = struct {
    read: f32 = 0,
    write: f32 = 0,
    read_total: u64 = 0,
    written_total: u64 = 0,
};

pub const Net = struct {
    in: f32 = 0,
    out: f32 = 0,
    received: u64 = 0,
    sent: u64 = 0,
};

pub const NetBytes = struct { in: u64 = 0, out: u64 = 0 };

extern "c" fn sysctl(name: [*]const c_int, len: c_uint, old: ?*anyopaque, oldlen: *usize, new: ?*const anyopaque, newlen: usize) c_int;

pub fn netBytes(gpa: std.mem.Allocator) NetBytes {
    const mib = [_]c_int{ 4, 17, 0, 0, 6, 0 };
    var len: usize = 0;
    if (sysctl(&mib, mib.len, null, &len, null, 0) != 0 or len == 0) return .{};
    const buf = gpa.alloc(u8, len + 4096) catch return .{};
    defer gpa.free(buf);
    var got = buf.len;
    if (sysctl(&mib, mib.len, buf.ptr, &got, null, 0) != 0) return .{};
    return sumInterfaces(buf[0..got]);
}

pub fn sumInterfaces(buf: []const u8) NetBytes {
    const RTM_IFINFO2 = 0x12;
    const IFF_UP = 0x1;
    const IFF_LOOPBACK = 0x8;
    var out: NetBytes = .{};
    var off: usize = 0;
    while (off + 112 <= buf.len) {
        const msglen = std.mem.readInt(u16, buf[off..][0..2], .little);
        if (msglen == 0) break;
        if (buf[off + 3] == RTM_IFINFO2 and off + msglen <= buf.len) {
            const flags = std.mem.readInt(i32, buf[off + 8 ..][0..4], .little);
            if (flags & IFF_UP != 0 and flags & IFF_LOOPBACK == 0) {
                out.in += std.mem.readInt(u64, buf[off + 96 ..][0..8], .little);
                out.out += std.mem.readInt(u64, buf[off + 104 ..][0..8], .little);
            }
        }
        off += msglen;
    }
    return out;
}

pub const Sample = struct {
    t: f64 = 0,
    cpu_user: f32 = 0,
    cpu_system: f32 = 0,
    mem_app: f32 = 0,
    mem_wired: f32 = 0,
    mem_compressed: f32 = 0,
    mem_cached: f32 = 0,
    gpu: f32 = 0,
    disk_read: f32 = 0,
    disk_write: f32 = 0,
    net_in: f32 = 0,
    net_out: f32 = 0,
    power: f32 = 0,
};

pub const History = struct {
    items: [history_len]Sample = undefined,
    head: usize = 0,
    len: usize = 0,

    pub fn push(h: *History, s: Sample) void {
        h.items[(h.head + h.len) % history_len] = s;
        if (h.len < history_len) h.len += 1 else h.head = (h.head + 1) % history_len;
    }

    pub fn get(h: *const History, i: usize) Sample {
        return h.items[(h.head + i) % history_len];
    }

    pub fn last(h: *const History) ?Sample {
        return if (h.len == 0) null else h.get(h.len - 1);
    }

    pub fn at(h: *const History, t: f64, slack: f64) ?Sample {
        if (h.len == 0) return null;
        if (t < h.get(0).t - slack) return null;
        var lo: usize = 0;
        var hi: usize = h.len;
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (h.get(mid).t <= t) lo = mid else hi = mid;
        }
        return h.get(lo);
    }

    pub fn column(h: *const History, now: f64, span: f64, cols: usize, i: usize, slack: f64) ?Sample {
        const step = span / @as(f64, @floatFromInt(@max(1, cols)));
        const t = now - step * @as(f64, @floatFromInt(cols - 1 - i));
        return h.at(t, slack);
    }

    pub fn peak(h: *const History, since: f64, comptime field: []const u8) f32 {
        var m: f32 = 0;
        var i = h.len;
        while (i > 0) : (i -= 1) {
            const s = h.get(i - 1);
            if (s.t < since) break;
            m = @max(m, @field(s, field));
        }
        return m;
    }

    pub fn average(h: *const History, since: f64, comptime field: []const u8) f32 {
        var sum: f64 = 0;
        var n: usize = 0;
        var i = h.len;
        while (i > 0) : (i -= 1) {
            const s = h.get(i - 1);
            if (s.t < since) break;
            sum += @field(s, field);
            n += 1;
        }
        return if (n == 0) 0 else @floatCast(sum / @as(f64, @floatFromInt(n)));
    }
};

pub const Metrics = struct {
    cpu: Cpu = .{},
    memory: Memory = .{},
    gpu: iokit.Gpu = .{},
    disk: Disk = .{},
    net: Net = .{},
    temps: iokit.Temps = .{},
    power: iokit.Power = .{},
    thermal: iokit.Thermal = .nominal,
    history: History = .{},
    thermometer: iokit.Thermometer = .{},
    prev_ticks: [max_cores][3]u64 = @splat(@splat(0)),
    prev_pageins: u64 = 0,
    prev_swapouts: u64 = 0,
    prev_disk: iokit.DiskBytes = .{},
    prev_net: NetBytes = .{},
    prev_t: f64 = 0,
    samples: usize = 0,

    pub fn init() Metrics {
        var m: Metrics = .{};
        m.cpu.efficiency = @intCast(sysctlInt("hw.perflevel1.logicalcpu") orelse 0);
        m.memory.total = @intCast(sysctlInt("hw.memsize") orelse 0);
        return m;
    }

    pub fn deinit(m: *Metrics) void {
        m.thermometer.deinit();
    }

    pub fn sample(m: *Metrics, now: f64, power_watts: f32) void {
        const wall = now - m.prev_t;
        const first = m.samples == 0;
        m.readCpu(first);
        m.readMemory(first, wall);
        m.gpu = iokit.gpu();
        const d = iokit.diskBytes();
        if (!first and wall > 0) {
            m.disk.read = @floatCast(@as(f64, @floatFromInt(d.read -| m.prev_disk.read)) / wall);
            m.disk.write = @floatCast(@as(f64, @floatFromInt(d.written -| m.prev_disk.written)) / wall);
        }
        m.disk.read_total = d.read;
        m.disk.written_total = d.written;
        m.prev_disk = d;
        const n = netBytes(std.heap.smp_allocator);
        if (!first and wall > 0) {
            m.net.in = @floatCast(@as(f64, @floatFromInt(n.in -| m.prev_net.in)) / wall);
            m.net.out = @floatCast(@as(f64, @floatFromInt(n.out -| m.prev_net.out)) / wall);
        }
        m.net.received = n.in;
        m.net.sent = n.out;
        m.prev_net = n;
        m.temps = m.thermometer.read();
        m.power = iokit.power();
        m.thermal = iokit.thermal();
        m.prev_t = now;
        m.samples += 1;
        if (first) return;
        const total: f32 = @floatFromInt(@max(1, m.memory.total));
        m.history.push(.{
            .t = now,
            .cpu_user = m.cpu.user,
            .cpu_system = m.cpu.system,
            .mem_app = @as(f32, @floatFromInt(m.memory.app)) / total,
            .mem_wired = @as(f32, @floatFromInt(m.memory.wired)) / total,
            .mem_compressed = @as(f32, @floatFromInt(m.memory.compressed)) / total,
            .mem_cached = @as(f32, @floatFromInt(m.memory.cached)) / total,
            .gpu = m.gpu.device,
            .disk_read = m.disk.read,
            .disk_write = m.disk.write,
            .net_in = m.net.in,
            .net_out = m.net.out,
            .power = power_watts,
        });
    }

    fn readCpu(m: *Metrics, first: bool) void {
        var cpus: c_uint = 0;
        var info: ?[*]c_int = null;
        var count: c_uint = 0;
        if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &count) != 0) return;
        const data = info orelse return;
        defer _ = vm_deallocate(mach_task_self_, @intFromPtr(data), count * @sizeOf(c_int));
        const n: usize = @min(cpus, max_cores);
        var user: u64 = 0;
        var sys: u64 = 0;
        var all: u64 = 0;
        for (0..n) |i| {
            const t = data[i * 4 ..][0..4];
            const now: [3]u64 = .{
                @as(u64, @as(u32, @bitCast(t[0]))) + @as(u32, @bitCast(t[3])),
                @as(u32, @bitCast(t[1])),
                @as(u32, @bitCast(t[2])),
            };
            const before = m.prev_ticks[i];
            const du = now[0] -| before[0];
            const ds = now[1] -| before[1];
            const di = now[2] -| before[2];
            const sum = du + ds + di;
            if (!first and sum > 0) m.cpu.cores[i] = @floatCast(@as(f64, @floatFromInt(du + ds)) / @as(f64, @floatFromInt(sum)) * 100);
            user += du;
            sys += ds;
            all += sum;
            m.prev_ticks[i] = now;
        }
        m.cpu.count = n;
        if (!first and all > 0) {
            m.cpu.user = @floatCast(@as(f64, @floatFromInt(user)) / @as(f64, @floatFromInt(all)) * 100);
            m.cpu.system = @floatCast(@as(f64, @floatFromInt(sys)) / @as(f64, @floatFromInt(all)) * 100);
        }
        _ = getloadavg(&m.cpu.load, 3);
    }

    fn readMemory(m: *Metrics, first: bool, wall: f64) void {
        var vm: VmStats = undefined;
        var vcount: c_uint = @sizeOf(VmStats) / @sizeOf(c_int);
        if (host_statistics64(mach_host_self(), HOST_VM_INFO64, &vm, &vcount) == 0) {
            const page: u64 = vm_kernel_page_size;
            m.memory.app = (@as(u64, vm.internal_page_count) -| vm.purgeable_count) * page;
            m.memory.wired = @as(u64, vm.wire_count) * page;
            m.memory.compressed = @as(u64, vm.compressor_page_count) * page;
            m.memory.cached = (@as(u64, vm.external_page_count) + vm.purgeable_count) * page;
            if (!first and wall > 0) {
                m.memory.pageins = @floatCast(@as(f64, @floatFromInt(vm.pageins -| m.prev_pageins)) / wall);
                m.memory.swapouts = @floatCast(@as(f64, @floatFromInt(vm.swapouts -| m.prev_swapouts)) / wall);
            }
            m.prev_pageins = vm.pageins;
            m.prev_swapouts = vm.swapouts;
        }
        var swap: SwapUsage = undefined;
        var len: usize = @sizeOf(SwapUsage);
        if (sysctlbyname("vm.swapusage", &swap, &len, null, 0) == 0) {
            m.memory.swap_used = swap.used;
            m.memory.swap_total = swap.total;
        }
        if (sysctlInt("kern.memorystatus_level")) |free| m.memory.pressure = @floatFromInt(100 - std.math.clamp(free, 0, 100));
        m.memory.level = switch (sysctlInt("kern.memorystatus_vm_pressure_level") orelse 1) {
            4 => .critical,
            2 => .elevated,
            else => .normal,
        };
    }
};

pub fn sysctlInt(name: [*:0]const u8) ?i64 {
    var buf: [8]u8 = @splat(0);
    var len: usize = buf.len;
    if (sysctlbyname(name, &buf, &len, null, 0) != 0) return null;
    return switch (len) {
        4 => std.mem.readInt(i32, buf[0..4], .little),
        8 => std.mem.readInt(i64, &buf, .little),
        else => null,
    };
}

pub fn sysctlText(name: [*:0]const u8, buf: []u8) []const u8 {
    var len: usize = buf.len;
    if (sysctlbyname(name, buf.ptr, &len, null, 0) != 0) return "";
    return std.mem.sliceTo(buf[0..len], 0);
}

pub fn rate(buf: []u8, bytes_per_s: f32) []const u8 {
    const units = [_][]const u8{ "B/s", "KB/s", "MB/s", "GB/s" };
    var v: f64 = @max(0, bytes_per_s);
    var u: usize = 0;
    while (v >= 1000 and u + 1 < units.len) : (u += 1) v /= 1000;
    if (v >= 100 or u == 0) return std.fmt.bufPrint(buf, "{d:.0} {s}", .{ v, units[u] }) catch "?";
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ v, units[u] }) catch "?";
}

pub fn watts(buf: []u8, w: f32) []const u8 {
    if (w < 1) return std.fmt.bufPrint(buf, "{d:.0} mW", .{w * 1000}) catch "?";
    if (w >= 100) return std.fmt.bufPrint(buf, "{d:.0} W", .{w}) catch "?";
    return std.fmt.bufPrint(buf, "{d:.1} W", .{w}) catch "?";
}

pub fn uptime(buf: []u8, seconds: i64) []const u8 {
    const s: u64 = @intCast(@max(0, seconds));
    const d = s / 86400;
    const h = (s / 3600) % 24;
    const m = (s / 60) % 60;
    if (d > 0) return std.fmt.bufPrint(buf, "{d}d {d}h", .{ d, h }) catch "?";
    if (h > 0) return std.fmt.bufPrint(buf, "{d}h {d}m", .{ h, m }) catch "?";
    return std.fmt.bufPrint(buf, "{d}m", .{m}) catch "?";
}
