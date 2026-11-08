const std = @import("std");

extern "c" fn proc_listallpids(buf: ?*anyopaque, size: c_int) c_int;
extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buf: *anyopaque, size: c_int) c_int;
extern "c" fn proc_pidpath(pid: c_int, buf: [*]u8, size: u32) c_int;
extern "c" fn proc_pid_rusage(pid: c_int, flavor: c_int, buf: *anyopaque) c_int;
extern "c" fn mach_timebase_info(info: *[2]u32) c_int;
extern "c" fn mach_host_self() c_uint;
extern "c" fn host_processor_info(host: c_uint, flavor: c_int, count: *c_uint, info: *?[*]c_int, info_count: *c_uint) c_int;
extern "c" fn host_statistics64(host: c_uint, flavor: c_int, info: *anyopaque, count: *c_uint) c_int;
extern "c" fn vm_deallocate(task: c_uint, addr: usize, size: usize) c_int;
extern "c" var mach_task_self_: c_uint;
extern "c" var vm_kernel_page_size: usize;
extern "c" fn sysctlbyname(name: [*:0]const u8, old: ?*anyopaque, oldlen: ?*usize, new: ?*const anyopaque, newlen: usize) c_int;
extern "c" fn statfs(path: [*:0]const u8, buf: *StatFs) c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn getuid() c_uint;
extern "c" fn getpid() c_int;
extern "c" fn getpwuid(uid: c_uint) ?*extern struct { name: ?[*:0]const u8 };

const PROC_PIDTASKINFO = 4;
const PROC_PIDTBSDSHORTINFO = 13;
const RUSAGE_INFO_V6 = 6;
const PROCESSOR_CPU_LOAD_INFO = 2;
const HOST_VM_INFO64 = 4;
const CPU_STATE_USER = 0;
const CPU_STATE_SYSTEM = 1;
const CPU_STATE_IDLE = 2;
const CPU_STATE_NICE = 3;
const CPU_STATE_MAX = 4;
const MAXPATHLEN = 1024;
const max_pids = 16384;
const percent = 100;

const ShortInfo = extern struct { pid: u32, ppid: u32, pgid: u32, status: u32, comm: [16]u8, flags: u32, uid: u32, gid: u32, ruid: u32, rgid: u32, svuid: u32, svgid: u32, rfu: u32 };

const Rusage = extern struct {
    uuid: [16]u8,
    user_time: u64,
    system_time: u64,
    pkg_idle_wkups: u64,
    interrupt_wkups: u64,
    pageins: u64,
    wired_size: u64,
    resident_size: u64,
    phys_footprint: u64,
    proc_start_abstime: u64,
    proc_exit_abstime: u64,
    child_user_time: u64,
    child_system_time: u64,
    child_pkg_idle_wkups: u64,
    child_interrupt_wkups: u64,
    child_pageins: u64,
    child_elapsed_abstime: u64,
    diskio_bytesread: u64,
    diskio_byteswritten: u64,
    cpu_time_qos: [7]u64,
    billed_system_time: u64,
    serviced_system_time: u64,
    logical_writes: u64,
    lifetime_max_phys_footprint: u64,
    instructions: u64,
    cycles: u64,
    billed_energy: u64,
    serviced_energy: u64,
    interval_max_phys_footprint: u64,
    runnable_time: u64,
    flags: u64,
    user_ptime: u64,
    system_ptime: u64,
    pinstructions: u64,
    pcycles: u64,
    energy_nj: u64,
    penergy_nj: u64,
    secure_time_in_system: u64,
    secure_ptime_in_system: u64,
    neural_footprint: u64,
    lifetime_max_neural_footprint: u64,
    interval_max_neural_footprint: u64,
    reserved: [9]u64,
};

const TaskInfo = extern struct {
    virtual_size: u64,
    resident_size: u64,
    total_user: u64,
    total_system: u64,
    threads_user: u64,
    threads_system: u64,
    policy: i32,
    faults: i32,
    pageins: i32,
    cow_faults: i32,
    messages_sent: i32,
    messages_received: i32,
    syscalls_mach: i32,
    syscalls_unix: i32,
    csw: i32,
    threadnum: i32,
    numrunning: i32,
    priority: i32,
};

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

const StatFs = extern struct {
    bsize: u32,
    iosize: i32,
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    fsid: [2]i32,
    owner: u32,
    fstype: u32,
    flags: u32,
    fssubtype: u32,
    fstypename: [16]u8,
    mntonname: [1024]u8,
    mntfromname: [1024]u8,
    flags_ext: u32,
    reserved: [7]u32,
};

pub const Proc = struct {
    pid: i32,
    uid: u32,
    name: []const u8 = "",
    bundle: []const u8 = "",
    user: []const u8 = "",
    cpu: f32 = 0,
    memory: u64 = 0,
    threads: u32 = 0,
    cpu_time_ns: u64 = 0,
    disk_rate: f32 = 0,
    energy: f32 = 0,
    known: bool = false,
};

pub const System = struct {
    cpu: f32 = 0,
    mem_used: u64 = 0,
    mem_total: u64 = 0,
    disk_free: u64 = 0,
    disk_total: u64 = 0,
    power: f32 = 0,
    threads: u64 = 0,
};

pub const Signal = enum(c_int) { quit = @intFromEnum(std.c.SIG.TERM), force = @intFromEnum(std.c.SIG.KILL) };

pub const QuitError = error{ NotYours, Itself, Failed };

const Prev = struct { time_ns: u64, disk: u64, energy: u64 };

const Known = struct {
    start: u64,
    uuid: [16]u8,
    ppid: u32,
    uid: u32,
    comm: [16]u8,
    path: []u8,
    name: []const u8,
    bundle: []const u8,
    user: []const u8,
    prev: ?Prev = null,
    seen: usize,
};

pub const Sampler = struct {
    gpa: std.mem.Allocator,
    procs: std.ArrayList(Proc) = .empty,
    system: System = .{},
    users: std.AutoHashMapUnmanaged(u32, []u8) = .empty,
    cache: std.AutoHashMapUnmanaged(i32, Known) = .empty,
    gone: std.ArrayList(i32) = .empty,
    prev_wall: f64 = 0,
    prev_busy: u64 = 0,
    prev_all: u64 = 0,
    samples: usize = 0,
    lookups: usize = 0,
    num: u64 = 0,
    den: u64 = 1,
    pids: []c_int = &.{},
    uid: u32 = 0,
    self_pid: i32 = 0,
    home: [:0]const u8 = "/",

    pub fn init(gpa: std.mem.Allocator, home: [:0]const u8) Sampler {
        var tb: [2]u32 = .{ 1, 1 };
        _ = mach_timebase_info(&tb);
        var total: u64 = 0;
        var len: usize = @sizeOf(u64);
        _ = sysctlbyname("hw.memsize", &total, &len, null, 0);
        return .{ .gpa = gpa, .num = tb[0], .den = @max(1, tb[1]), .uid = getuid(), .self_pid = getpid(), .home = home, .system = .{ .mem_total = total } };
    }

    pub fn deinit(s: *Sampler) void {
        s.procs.deinit(s.gpa);
        var known = s.cache.valueIterator();
        while (known.next()) |k| s.gpa.free(k.path);
        s.cache.deinit(s.gpa);
        s.gone.deinit(s.gpa);
        var it = s.users.valueIterator();
        while (it.next()) |u| s.gpa.free(u.*);
        s.users.deinit(s.gpa);
        if (s.pids.len > 0) s.gpa.free(s.pids);
    }

    pub fn userName(s: *Sampler, uid: u32) []const u8 {
        if (s.users.get(uid)) |u| return u;
        const login: []const u8 = if (getpwuid(uid)) |pw| (if (pw.name) |n| std.mem.span(n) else "") else "";
        const owned = (if (login.len > 0) s.gpa.dupe(u8, login) else std.fmt.allocPrint(s.gpa, "{d}", .{uid})) catch return "?";
        s.users.put(s.gpa, uid, owned) catch {
            s.gpa.free(owned);
            return "?";
        };
        return owned;
    }

    pub fn sample(s: *Sampler, now: f64) void {
        if (s.pids.len == 0) s.pids = s.gpa.alloc(c_int, max_pids) catch return;
        const got = proc_listallpids(s.pids.ptr, @intCast(s.pids.len * @sizeOf(c_int)));
        const n: usize = @min(s.pids.len, @as(usize, @intCast(@max(0, got))));
        s.procs.clearRetainingCapacity();
        s.procs.ensureTotalCapacity(s.gpa, n) catch return;
        s.cache.ensureUnusedCapacity(s.gpa, @intCast(n)) catch return;
        s.gone.ensureTotalCapacity(s.gpa, s.cache.count()) catch return;
        const wall = now - s.prev_wall;
        const gen = s.samples + 1;
        s.system.power = 0;
        s.system.threads = 0;
        var ru: Rusage = undefined;
        var ti: TaskInfo = undefined;
        for (s.pids[0..n]) |pid| {
            if (pid <= 0) continue;
            const readable = proc_pid_rusage(pid, RUSAGE_INFO_V6, &ru) == 0;
            const k = s.lookUp(pid, if (readable) ru.proc_start_abstime else 0, if (readable) ru.uuid else @splat(0)) orelse continue;
            k.seen = gen;
            var p: Proc = .{ .pid = pid, .uid = k.uid, .name = k.name, .bundle = k.bundle, .user = k.user };
            if (readable) {
                const t = (ru.user_time + ru.system_time) * s.num / s.den;
                const disk = ru.diskio_bytesread + ru.diskio_byteswritten;
                p.memory = ru.phys_footprint;
                p.cpu_time_ns = t;
                p.known = true;
                if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, @sizeOf(TaskInfo)) == @sizeOf(TaskInfo)) p.threads = @intCast(@max(0, ti.threadnum));
                if (s.samples > 0 and wall > 0) if (k.prev) |before| {
                    const wall_ns = wall * std.time.ns_per_s;
                    p.cpu = @floatCast(@as(f64, @floatFromInt(t -| before.time_ns)) / wall_ns * percent);
                    p.disk_rate = @floatCast(@as(f64, @floatFromInt(disk -| before.disk)) / wall);
                    p.energy = @floatCast(@as(f64, @floatFromInt(ru.energy_nj -| before.energy)) / wall_ns);
                    s.system.power += p.energy;
                };
                k.prev = .{ .time_ns = t, .disk = disk, .energy = ru.energy_nj };
            }
            s.system.threads += p.threads;
            s.procs.appendAssumeCapacity(p);
        }
        s.forget(gen);
        s.prev_wall = now;
        s.readSystem();
        s.samples += 1;
    }

    fn lookUp(s: *Sampler, pid: i32, start: u64, uuid: [16]u8) ?*Known {
        var info: ShortInfo = undefined;
        const cached = s.cache.getPtr(pid);
        if (cached) |k| if (start != 0 and k.start == start and std.mem.eql(u8, &k.uuid, &uuid)) return k;
        if (proc_pidinfo(pid, PROC_PIDTBSDSHORTINFO, 0, &info, @sizeOf(ShortInfo)) != @sizeOf(ShortInfo)) return null;
        if (cached) |k| if (start == 0 and k.start == 0 and k.uid == info.uid and k.ppid == info.ppid and std.mem.eql(u8, &k.comm, &info.comm)) return k;
        var path: [MAXPATHLEN]u8 = undefined;
        const plen = proc_pidpath(pid, &path, path.len);
        s.lookups += 1;
        const full = if (plen > 0) path[0..@intCast(plen)] else std.mem.sliceTo(&info.comm, 0);
        const owned = s.gpa.dupe(u8, full) catch return null;
        if (cached) |k| s.gpa.free(k.path);
        const k = s.cache.getOrPutAssumeCapacity(pid).value_ptr;
        k.* = .{
            .start = start,
            .uuid = uuid,
            .ppid = info.ppid,
            .uid = info.uid,
            .comm = info.comm,
            .path = owned,
            .name = displayName(owned),
            .bundle = outerBundle(owned),
            .user = s.userName(info.uid),
            .seen = 0,
        };
        return k;
    }

    fn forget(s: *Sampler, gen: usize) void {
        s.gone.clearRetainingCapacity();
        var it = s.cache.iterator();
        while (it.next()) |e| if (e.value_ptr.seen != gen) s.gone.appendAssumeCapacity(e.key_ptr.*);
        for (s.gone.items) |pid| if (s.cache.fetchRemove(pid)) |e| s.gpa.free(e.value.path);
    }

    fn readSystem(s: *Sampler) void {
        var cpus: c_uint = 0;
        var info: ?[*]c_int = null;
        var count: c_uint = 0;
        if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &count) == 0) if (info) |data| {
            defer _ = vm_deallocate(mach_task_self_, @intFromPtr(data), count * @sizeOf(c_int));
            var busy: u64 = 0;
            var all: u64 = 0;
            for (0..cpus) |i| {
                const c = data[i * CPU_STATE_MAX ..][0..CPU_STATE_MAX];
                const user = @as(u64, @as(u32, @bitCast(c[CPU_STATE_USER]))) + @as(u32, @bitCast(c[CPU_STATE_NICE]));
                const sys = @as(u64, @as(u32, @bitCast(c[CPU_STATE_SYSTEM])));
                busy += user + sys;
                all += user + sys + @as(u32, @bitCast(c[CPU_STATE_IDLE]));
            }
            if (s.samples > 0 and all > s.prev_all) s.system.cpu = @floatCast(@as(f64, @floatFromInt(busy -| s.prev_busy)) / @as(f64, @floatFromInt(all - s.prev_all)) * percent);
            s.prev_busy = busy;
            s.prev_all = all;
        };
        var vm: VmStats = undefined;
        var vcount: c_uint = @sizeOf(VmStats) / @sizeOf(c_int);
        if (host_statistics64(mach_host_self(), HOST_VM_INFO64, &vm, &vcount) == 0) {
            const page: u64 = vm_kernel_page_size;
            const app = (@as(u64, vm.internal_page_count) -| vm.purgeable_count) * page;
            s.system.mem_used = app + @as(u64, vm.wire_count) * page + @as(u64, vm.compressor_page_count) * page;
        }
        var fs: StatFs = undefined;
        if (statfs(s.home.ptr, &fs) == 0) {
            s.system.disk_free = fs.bavail * fs.bsize;
            s.system.disk_total = fs.blocks * fs.bsize;
        }
    }

    pub fn find(s: *const Sampler, pid: i32) ?*const Proc {
        for (s.procs.items) |*p| if (p.pid == pid) return p;
        return null;
    }

    pub fn running(s: *const Sampler, bundle: []const u8) bool {
        for (s.procs.items) |p| if (std.mem.eql(u8, p.bundle, bundle)) return true;
        return false;
    }

    pub fn quit(s: *const Sampler, pid: i32, sig: Signal, send: *const fn (c_int, c_int) callconv(.c) c_int) QuitError!void {
        if (pid == s.self_pid) return error.Itself;
        const p = s.find(pid) orelse return error.Failed;
        if (p.uid != s.uid) return error.NotYours;
        if (send(pid, @intFromEnum(sig)) != 0) return error.Failed;
    }
};

pub fn sendKill(pid: c_int, sig: c_int) callconv(.c) c_int {
    return kill(pid, sig);
}

pub fn displayName(path: []const u8) []const u8 {
    if (std.mem.lastIndexOf(u8, path, ".app/")) |end| {
        const start = if (std.mem.lastIndexOfScalar(u8, path[0..end], '/')) |i| i + 1 else 0;
        return path[start..end];
    }
    return std.fs.path.basename(path);
}

pub fn outerBundle(path: []const u8) []const u8 {
    const end = std.mem.indexOf(u8, path, ".app/") orelse return "";
    return path[0 .. end + 4];
}

pub fn bytes(buf: []u8, n: u64) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var v: f64 = @floatFromInt(n);
    var u: usize = 0;
    while (v >= 1000 and u + 1 < units.len) : (u += 1) v /= 1000;
    if (u == 0) return std.fmt.bufPrint(buf, "{d} B", .{n}) catch "?";
    if (v >= 100) return std.fmt.bufPrint(buf, "{d:.0} {s}", .{ v, units[u] }) catch "?";
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ v, units[u] }) catch "?";
}

pub fn duration(buf: []u8, ns: u64) []const u8 {
    const cs_per_s = 100;
    const total_cs = ns / (std.time.ns_per_s / cs_per_s);
    const cs = total_cs % cs_per_s;
    const secs = total_cs / cs_per_s;
    const h = secs / std.time.s_per_hour;
    const m = (secs % std.time.s_per_hour) / std.time.s_per_min;
    const sec = secs % std.time.s_per_min;
    if (h > 0) return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ h, m, sec }) catch "?";
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}.{d:0>2}", .{ m, sec, cs }) catch "?";
}

pub fn ago(buf: []u8, now: i64, then: i64) []const u8 {
    if (then <= 0) return "–";
    const min = std.time.s_per_min;
    const hour = std.time.s_per_hour;
    const day = std.time.s_per_day;
    const week = std.time.s_per_week;
    const month = 30 * day;
    const year = 365 * day;
    const d = now - then;
    if (d < min) return "Just now";
    if (d < hour) return std.fmt.bufPrint(buf, "{d} min ago", .{@divTrunc(d, min)}) catch "?";
    if (d < day) return std.fmt.bufPrint(buf, "{d} hours ago", .{@divTrunc(d, hour)}) catch "?";
    if (d < 2 * day) return "Yesterday";
    if (d < 2 * week) return std.fmt.bufPrint(buf, "{d} days ago", .{@divTrunc(d, day)}) catch "?";
    if (d < 2 * month) return std.fmt.bufPrint(buf, "{d} weeks ago", .{@divTrunc(d, week)}) catch "?";
    if (d < year) return std.fmt.bufPrint(buf, "{d} months ago", .{@divTrunc(d, month)}) catch "?";
    const y = @divTrunc(d, year);
    return if (y == 1) "1 year ago" else std.fmt.bufPrint(buf, "{d} years ago", .{y}) catch "?";
}
