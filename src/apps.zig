const std = @import("std");
const nanoui = @import("nanoui");
const walk = @import("walk.zig");
const plist = @import("plist.zig");
const objc = nanoui.objc;

extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;

const Dir = @import("dir.zig").Dir;
const DT_DIR = @import("dir.zig").DT_DIR;

const CPU_ARM64: u32 = 0x0100000c;
const CPU_X86_64: u32 = 0x01000007;
const MH_MAGIC_64: u32 = 0xfeedfacf;
const FAT_MAGIC: u32 = 0xcafebabe;
const FAT_MAGIC_64: u32 = 0xcafebabf;
const fat_arch_size = 20;
const fat_arch_64_size = 32;
const fat_header_size = 8;
const max_fat_archs = 16;
const header_read = 512;
const O_RDONLY = 0;
const F_OK = 0;
const folder_depth = 1;

pub const Kind = enum {
    unknown,
    apple,
    intel,
    universal,

    pub fn title(k: Kind) []const u8 {
        return switch (k) {
            .unknown => "–",
            .apple => "Apple silicon",
            .intel => "Intel",
            .universal => "Universal",
        };
    }
};

pub fn kindOf(h: []const u8) Kind {
    if (h.len < fat_header_size) return .unknown;
    if (std.mem.readInt(u32, h[0..4], .little) == MH_MAGIC_64) {
        const cpu = std.mem.readInt(u32, h[4..8], .little);
        return archKind(cpu == CPU_ARM64, cpu == CPU_X86_64);
    }
    const be = std.mem.readInt(u32, h[0..4], .big);
    if (be != FAT_MAGIC and be != FAT_MAGIC_64) return .unknown;
    const n = std.mem.readInt(u32, h[4..8], .big);
    const step: usize = if (be == FAT_MAGIC_64) fat_arch_64_size else fat_arch_size;
    var arm = false;
    var x86 = false;
    for (0..@min(n, max_fat_archs)) |i| {
        const off = fat_header_size + i * step;
        if (off + 4 > h.len) break;
        const cpu = std.mem.readInt(u32, h[off..][0..4], .big);
        arm = arm or cpu == CPU_ARM64;
        x86 = x86 or cpu == CPU_X86_64;
    }
    return archKind(arm, x86);
}

fn archKind(arm: bool, x86: bool) Kind {
    if (arm and x86) return .universal;
    if (arm) return .apple;
    if (x86) return .intel;
    return .unknown;
}

pub const AppInfo = struct {
    path: [:0]u8,
    name: []u8,
    version: []u8,
    kind: Kind = .unknown,
    app_store: bool = false,
    last_opened: i64 = 0,
    size: walk.Size = .{},
    measured: bool = false,

    fn free(a: AppInfo, gpa: std.mem.Allocator) void {
        gpa.free(a.path);
        gpa.free(a.name);
        gpa.free(a.version);
    }
};

pub const Notify = struct { ctx: *anyopaque, func: *const fn (*anyopaque) void };

const Measure = struct {
    inv: *Inventory,
    generation: u64,
    paths: [][:0]const u8,
    out: []walk.Size,
    pool: walk.Pool,
    thread: ?std.Thread = null,

    fn work(m: *Measure) void {
        m.pool.run();
        objc.dispatchMain(m, finished);
    }

    fn finished(ctx: ?*anyopaque) callconv(.c) void {
        const m: *Measure = @ptrCast(@alignCast(ctx));
        m.inv.measured(m);
    }
};

const Listing = struct {
    inv: *Inventory,
    apps: std.ArrayList(AppInfo) = .empty,
    thread: ?std.Thread = null,

    fn work(l: *Listing) void {
        l.list();
        objc.dispatchMain(l, finished);
    }

    fn finished(ctx: ?*anyopaque) callconv(.c) void {
        const l: *Listing = @ptrCast(@alignCast(ctx));
        l.inv.listed(l);
    }

    fn free(l: *Listing, gpa: std.mem.Allocator) void {
        for (l.apps.items) |a| a.free(gpa);
        l.apps.deinit(gpa);
        gpa.destroy(l);
    }

    fn list(l: *Listing) void {
        for (l.inv.dirs) |dir| l.listDir(dir, folder_depth) catch {};
        std.mem.sort(AppInfo, l.apps.items, {}, struct {
            fn lt(_: void, a: AppInfo, b: AppInfo) bool {
                return std.ascii.orderIgnoreCase(a.name, b.name) == .lt;
            }
        }.lt);
    }

    fn listDir(l: *Listing, dir: []const u8, depth: u8) !void {
        const gpa = l.inv.gpa;
        const dir_z = try gpa.dupeSentinel(u8, dir, 0);
        defer gpa.free(dir_z);
        var d = Dir.open(dir_z) orelse return;
        defer d.close();
        while (d.next()) |ent| {
            if (ent.kind != DT_DIR) continue;
            const name = ent.name;
            if (name.len == 0 or name[0] == '.') continue;
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name });
            defer gpa.free(path);
            if (std.mem.endsWith(u8, name, ".app")) {
                try l.add(path);
            } else if (depth > 0) try l.listDir(path, depth - 1);
        }
    }

    fn add(l: *Listing, path: []const u8) !void {
        const gpa = l.inv.gpa;
        var info: AppInfo = .{ .path = try gpa.dupeSentinel(u8, path, 0), .name = undefined, .version = undefined };
        errdefer gpa.free(info.path);
        const plist_path = try std.fmt.allocPrintSentinel(gpa, "{s}/Contents/Info.plist", .{path}, 0);
        defer gpa.free(plist_path);
        const data = plist.readFile(gpa, plist_path) catch try gpa.alloc(u8, 0);
        defer gpa.free(data);
        info.name = try firstString(gpa, data, &.{ "CFBundleDisplayName", "CFBundleName" }) orelse try gpa.dupe(u8, appName(path));
        errdefer gpa.free(info.name);
        info.version = try firstString(gpa, data, &.{ "CFBundleShortVersionString", "CFBundleVersion" }) orelse try gpa.alloc(u8, 0);
        errdefer gpa.free(info.version);
        if (try plist.string(gpa, data, "CFBundleExecutable")) |exe| {
            defer gpa.free(exe);
            const exe_path = try std.fmt.allocPrintSentinel(gpa, "{s}/Contents/MacOS/{s}", .{ path, exe }, 0);
            defer gpa.free(exe_path);
            info.kind = readKind(exe_path);
        }
        const receipt = try std.fmt.allocPrintSentinel(gpa, "{s}/Contents/_MASReceipt/receipt", .{path}, 0);
        defer gpa.free(receipt);
        info.app_store = access(receipt, F_OK) == 0;
        try l.apps.append(gpa, info);
    }
};

pub const Inventory = struct {
    gpa: std.mem.Allocator,
    dirs: []const []const u8,
    apps: std.ArrayList(AppInfo) = .empty,
    loaded: bool = false,
    listing: ?*Listing = null,
    measuring: ?*Measure = null,
    generation: u64 = 0,
    sync: bool = false,
    on_change: ?Notify = null,

    pub fn deinit(inv: *Inventory) void {
        if (inv.listing) |l| {
            if (l.thread) |t| t.join();
            l.free(inv.gpa);
            inv.listing = null;
        }
        if (inv.measuring) |m| {
            m.pool.cancel.store(true, .monotonic);
            if (m.thread) |t| t.join();
            inv.freeMeasure(m);
        }
        inv.clear();
        inv.apps.deinit(inv.gpa);
    }

    fn clear(inv: *Inventory) void {
        for (inv.apps.items) |a| a.free(inv.gpa);
        inv.apps.clearRetainingCapacity();
    }

    pub fn total(inv: *const Inventory) u64 {
        var n: u64 = 0;
        for (inv.apps.items) |a| n += a.size.bytes;
        return n;
    }

    pub fn load(inv: *Inventory) void {
        if (inv.measuring != null or inv.listing != null) return;
        const l = inv.gpa.create(Listing) catch return;
        l.* = .{ .inv = inv };
        inv.listing = l;
        if (inv.sync) {
            l.list();
            return inv.listed(l);
        }
        l.thread = std.Thread.spawn(.{}, Listing.work, .{l}) catch {
            l.list();
            return inv.listed(l);
        };
    }

    fn listed(inv: *Inventory, l: *Listing) void {
        if (l.thread) |t| t.join();
        inv.clear();
        inv.apps.deinit(inv.gpa);
        inv.apps = l.apps;
        inv.gpa.destroy(l);
        inv.listing = null;
        inv.generation += 1;
        inv.loaded = true;
        inv.startMeasure();
        inv.tell();
    }

    fn startMeasure(inv: *Inventory) void {
        const n = inv.apps.items.len;
        const paths = inv.gpa.alloc([:0]const u8, n) catch return;
        const out = inv.gpa.alloc(walk.Size, n) catch return inv.gpa.free(paths);
        @memset(out, .{});
        for (inv.apps.items, 0..) |a, i| paths[i] = a.path;
        const m = inv.gpa.create(Measure) catch {
            inv.gpa.free(paths);
            return inv.gpa.free(out);
        };
        m.* = .{ .inv = inv, .generation = inv.generation, .paths = paths, .out = out, .pool = .{ .gpa = inv.gpa, .paths = paths, .out = out } };
        inv.measuring = m;
        if (inv.sync) {
            m.pool.run();
            return inv.measured(m);
        }
        m.thread = std.Thread.spawn(.{}, Measure.work, .{m}) catch {
            m.pool.run();
            return inv.measured(m);
        };
    }

    fn measured(inv: *Inventory, m: *Measure) void {
        if (m.thread) |t| t.join();
        if (m.generation == inv.generation) for (inv.apps.items, m.out) |*a, s| {
            a.size = s;
            a.measured = true;
        };
        inv.freeMeasure(m);
        inv.tell();
    }

    fn freeMeasure(inv: *Inventory, m: *Measure) void {
        inv.gpa.free(m.paths);
        inv.gpa.free(m.out);
        inv.gpa.destroy(m);
        inv.measuring = null;
    }

    pub fn remove(inv: *Inventory, index: usize) void {
        const a = inv.apps.orderedRemove(index);
        a.free(inv.gpa);
        inv.tell();
    }

    fn tell(inv: *Inventory) void {
        if (inv.on_change) |n| n.func(n.ctx);
    }
};

pub fn appName(bundle: []const u8) []const u8 {
    const base = std.fs.path.basename(bundle);
    const ext = ".app";
    return if (std.mem.endsWith(u8, base, ext)) base[0 .. base.len - ext.len] else base;
}

fn firstString(gpa: std.mem.Allocator, data: []const u8, keys: []const []const u8) !?[]u8 {
    for (keys) |key| if (try plist.string(gpa, data, key)) |s| {
        if (s.len > 0) return s;
        gpa.free(s);
    };
    return null;
}

fn readKind(exe: [:0]const u8) Kind {
    const fd = open(exe, O_RDONLY);
    if (fd < 0) return .unknown;
    defer _ = close(fd);
    var buf: [header_read]u8 = undefined;
    const n = read(fd, &buf, buf.len);
    if (n <= 0) return .unknown;
    return kindOf(buf[0..@intCast(n)]);
}
