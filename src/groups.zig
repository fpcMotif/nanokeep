const std = @import("std");
const procs = @import("procs.zig");
const Proc = procs.Proc;

pub const Show = enum { all, apps, mine, system };

pub const Sort = enum { name, cpu, memory, threads, disk, time, pid, user };

pub const Group = struct {
    key: u64,
    name: []const u8,
    bundle: []const u8,
    user: []const u8,
    pid: i32,
    first: u32,
    count: u32 = 0,
    cpu: f32 = 0,
    memory: u64 = 0,
    threads: u32 = 0,
    disk: f32 = 0,
    time_ns: u64 = 0,
    known: bool = false,
};

pub const Row = struct { group: u32, member: ?u32 = null };

pub const Options = struct {
    show: Show = .mine,
    sort: Sort = .memory,
    reversed: bool = false,
    query: []const u8 = "",
    uid: u32 = 0,
};

pub fn keyOf(p: *const Proc) u64 {
    return std.hash.Wyhash.hash(0, if (p.bundle.len > 0) p.bundle else p.name);
}

fn shown(p: *const Proc, o: Options) bool {
    switch (o.show) {
        .all => {},
        .apps => if (p.bundle.len == 0) return false,
        .mine => if (p.uid != o.uid) return false,
        .system => if (p.uid == o.uid) return false,
    }
    if (o.query.len == 0) return true;
    return std.ascii.findIgnoreCase(p.name, o.query) != null or std.ascii.findIgnoreCase(p.bundle, o.query) != null;
}

pub const Table = struct {
    gpa: std.mem.Allocator,
    groups: std.ArrayList(Group) = .empty,
    members: std.ArrayList(u32) = .empty,
    rows: std.ArrayList(Row) = .empty,
    shown: usize = 0,

    pub fn deinit(t: *Table) void {
        t.groups.deinit(t.gpa);
        t.members.deinit(t.gpa);
        t.rows.deinit(t.gpa);
    }

    pub fn build(t: *Table, items: []const Proc, o: Options, expanded: *const std.AutoHashMapUnmanaged(u64, void)) !void {
        t.groups.clearRetainingCapacity();
        t.members.clearRetainingCapacity();
        t.rows.clearRetainingCapacity();
        t.shown = 0;
        var picked: std.ArrayList(u32) = .empty;
        defer picked.deinit(t.gpa);
        for (items, 0..) |*p, i| if (shown(p, o)) try picked.append(t.gpa, @intCast(i));
        t.shown = picked.items.len;
        const Ctx = struct {
            items: []const Proc,
            o: Options,
            fn lt(c: @This(), a: u32, b: u32) bool {
                const ka = keyOf(&c.items[a]);
                const kb = keyOf(&c.items[b]);
                if (ka != kb) return ka < kb;
                return before(c.items[a].cpu, c.items[a].memory, c.items[b].cpu, c.items[b].memory, c.o);
            }
        };
        std.mem.sort(u32, picked.items, Ctx{ .items = items, .o = o }, Ctx.lt);
        for (picked.items) |i| {
            const p = &items[i];
            const k = keyOf(p);
            if (t.groups.items.len == 0 or t.groups.items[t.groups.items.len - 1].key != k) {
                try t.groups.append(t.gpa, .{
                    .key = k,
                    .name = if (p.bundle.len > 0) appName(p.bundle) else p.name,
                    .bundle = p.bundle,
                    .user = p.user,
                    .pid = p.pid,
                    .first = @intCast(t.members.items.len),
                });
            }
            const g = &t.groups.items[t.groups.items.len - 1];
            try t.members.append(t.gpa, i);
            g.count += 1;
            g.cpu += p.cpu;
            g.memory += p.memory;
            g.threads += p.threads;
            g.disk += p.disk_rate;
            g.time_ns += p.cpu_time_ns;
            g.known = g.known or p.known;
            if (p.pid < g.pid) g.pid = p.pid;
        }
        std.mem.sort(Group, t.groups.items, o, groupLess);
        for (t.groups.items, 0..) |g, gi| {
            try t.rows.append(t.gpa, .{ .group = @intCast(gi) });
            if (g.count < 2 or !expanded.contains(g.key)) continue;
            for (t.members.items[g.first .. g.first + g.count]) |m| try t.rows.append(t.gpa, .{ .group = @intCast(gi), .member = m });
        }
    }

    pub fn group(t: *const Table, key: u64) ?*const Group {
        for (t.groups.items) |*g| if (g.key == key) return g;
        return null;
    }

    pub fn pidsOf(t: *const Table, g: *const Group, items: []const Proc, out: *std.ArrayList(i32)) !void {
        for (t.members.items[g.first .. g.first + g.count]) |m| try out.append(t.gpa, items[m].pid);
    }
};

fn before(cpu_a: f32, mem_a: u64, cpu_b: f32, mem_b: u64, o: Options) bool {
    if (o.sort == .cpu and cpu_a != cpu_b) return cpu_a > cpu_b;
    return mem_a > mem_b;
}

fn groupLess(o: Options, a: Group, b: Group) bool {
    const ord: std.math.Order = switch (o.sort) {
        .name => std.ascii.orderIgnoreCase(a.name, b.name),
        .user => std.ascii.orderIgnoreCase(a.user, b.user),
        .cpu => std.math.order(a.cpu, b.cpu),
        .memory => std.math.order(a.memory, b.memory),
        .threads => std.math.order(a.threads, b.threads),
        .disk => std.math.order(a.disk, b.disk),
        .time => std.math.order(a.time_ns, b.time_ns),
        .pid => std.math.order(a.pid, b.pid),
    };
    if (ord == .eq) return std.ascii.orderIgnoreCase(a.name, b.name) == .lt;
    const text = o.sort == .name or o.sort == .user or o.sort == .pid;
    const descending = if (text) o.reversed else !o.reversed;
    return if (descending) ord == .gt else ord == .lt;
}

pub fn appName(bundle: []const u8) []const u8 {
    const base = std.fs.path.basename(bundle);
    return if (std.mem.endsWith(u8, base, ".app")) base[0 .. base.len - 4] else base;
}
