const std = @import("std");

extern "c" fn getpid() c_int;
extern "c" fn proc_pid_rusage(pid: c_int, flavor: c_int, buffer: *RusageV4) c_int;
// Private libsystem_kernel call; the bench needs a peak per scenario, not per lifetime.
extern "c" fn proc_reset_footprint_interval(pid: c_int) c_int;

const RUSAGE_INFO_V4 = 4;

const RusageV4 = extern struct {
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
};

pub const Footprint = struct { now: u64, peak: u64, interval_peak: u64 };

pub fn footprint() Footprint {
    var r: RusageV4 = undefined;
    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V4, &r) != 0) return .{ .now = 0, .peak = 0, .interval_peak = 0 };
    return .{ .now = r.phys_footprint, .peak = r.lifetime_max_phys_footprint, .interval_peak = r.interval_max_phys_footprint };
}

pub fn resetPeak() void {
    _ = proc_reset_footprint_interval(getpid());
}

extern "c" fn mach_absolute_time() u64;
extern "c" fn mach_timebase_info(info: *[2]u32) c_int;

pub fn sinceStart() f64 {
    var r: RusageV4 = undefined;
    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V4, &r) != 0) return std.math.inf(f64);
    var base: [2]u32 = undefined;
    _ = mach_timebase_info(&base);
    const ticks: f64 = @floatFromInt(mach_absolute_time() - r.proc_start_abstime);
    return ticks * @as(f64, @floatFromInt(base[0])) / @as(f64, @floatFromInt(base[1])) / 1e6;
}

pub const Stats = struct {
    p50: f64,
    p95: f64,

    pub fn of(samples: []f64) Stats {
        std.mem.sort(f64, samples, {}, std.sort.asc(f64));
        return .{ .p50 = rank(samples, 50), .p95 = rank(samples, 95) };
    }

    fn rank(sorted: []const f64, p: usize) f64 {
        const r = (p * sorted.len + 99) / 100;
        return sorted[@max(r, 1) - 1];
    }
};

pub fn parseLeaks(out: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "total leaked byte") == null) continue;
        const colon = std.mem.indexOf(u8, line, ": ") orelse continue;
        const rest = line[colon + 2 ..];
        const end = std.mem.indexOf(u8, rest, " leak") orelse continue;
        return std.fmt.parseInt(u64, rest[0..end], 10) catch continue;
    }
    return null;
}

pub const Budget = struct { name: []const u8, budget: f64, target: f64 };

pub const Metric = struct { name: []const u8, value: f64 };

pub const Verdict = struct {
    metric: Metric,
    budget: ?Budget,

    pub fn ok(v: Verdict) bool {
        const b = v.budget orelse return false;
        return v.metric.value <= b.budget;
    }
};

pub fn judge(metric: Metric, budgets: []const Budget) Verdict {
    for (budgets) |b| if (std.mem.eql(u8, b.name, metric.name)) return .{ .metric = metric, .budget = b };
    return .{ .metric = metric, .budget = null };
}
