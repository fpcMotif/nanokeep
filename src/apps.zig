const std = @import("std");
const nanoui = @import("nanoui");
const walk = @import("walk.zig");
const objc = nanoui.objc;

extern "c" fn opendir(path: [*:0]const u8) ?*anyopaque;
extern "c" fn readdir(dir: *anyopaque) ?*const Dirent;
extern "c" fn closedir(dir: *anyopaque) c_int;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn MDItemCreate(alloc: ?*anyopaque, path: objc.Object) ?*anyopaque;
extern "c" fn MDItemCopyAttribute(item: *anyopaque, name: *anyopaque) ?*anyopaque;
extern "c" var kMDItemLastUsedDate: *anyopaque;
extern "c" fn CFDateGetAbsoluteTime(date: *anyopaque) f64;
extern "c" fn CFRelease(obj: *anyopaque) void;

const Dirent = extern struct { ino: u64, seekoff: u64, reclen: u16, namlen: u16, kind: u8, name: [1024]u8 };
const DT_DIR = 4;
const cf_epoch: f64 = 978307200;

const CPU_ARM64: u32 = 0x0100000c;
const CPU_X86_64: u32 = 0x01000007;

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
    if (h.len < 8) return .unknown;
    const le = std.mem.readInt(u32, h[0..4], .little);
    if (le == 0xfeedfacf) return archKind(std.mem.readInt(u32, h[4..8], .little) == CPU_ARM64, std.mem.readInt(u32, h[4..8], .little) == CPU_X86_64);
    const be = std.mem.readInt(u32, h[0..4], .big);
    if (be != 0xcafebabe and be != 0xcafebabf) return .unknown;
    const n = std.mem.readInt(u32, h[4..8], .big);
    const step: usize = if (be == 0xcafebabf) 32 else 20;
    var arm = false;
    var x86 = false;
    for (0..@min(n, 16)) |i| {
        const off = 8 + i * step;
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

pub const Inventory = struct {
    gpa: std.mem.Allocator,
    dirs: []const []const u8,
    apps: std.ArrayList(AppInfo) = .empty,
    loaded: bool = false,
    measuring: ?*Measure = null,
    generation: u64 = 0,
    sync: bool = false,
    on_change: ?Notify = null,

    pub fn deinit(inv: *Inventory) void {
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
        if (inv.measuring != null) return;
        inv.clear();
        inv.generation += 1;
        for (inv.dirs) |dir| inv.listDir(dir, 1) catch {};
        std.mem.sort(AppInfo, inv.apps.items, {}, struct {
            fn lt(_: void, a: AppInfo, b: AppInfo) bool {
                return std.ascii.orderIgnoreCase(a.name, b.name) == .lt;
            }
        }.lt);
        inv.loaded = true;
        inv.startMeasure();
        inv.tell();
    }

    fn listDir(inv: *Inventory, dir: []const u8, depth: u8) !void {
        const dir_z = try inv.gpa.dupeSentinel(u8, dir, 0);
        defer inv.gpa.free(dir_z);
        const d = opendir(dir_z) orelse return;
        defer _ = closedir(d);
        while (readdir(d)) |ent| {
            if (ent.kind != DT_DIR) continue;
            const name = ent.name[0..ent.namlen];
            if (name.len == 0 or name[0] == '.') continue;
            const path = try std.fmt.allocPrint(inv.gpa, "{s}/{s}", .{ dir, name });
            defer inv.gpa.free(path);
            if (std.mem.endsWith(u8, name, ".app")) {
                try inv.add(path);
            } else if (depth > 0) try inv.listDir(path, depth - 1);
        }
    }

    fn add(inv: *Inventory, path: []const u8) !void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const base = std.fs.path.basename(path);
        var info: AppInfo = .{ .path = try inv.gpa.dupeSentinel(u8, path, 0), .name = undefined, .version = undefined };
        errdefer inv.gpa.free(info.path);
        const bundle = objc.msg(?objc.Object, objc.class("NSBundle"), "bundleWithPath:", .{objc.nsString(path)});
        const display = plistString(bundle, "CFBundleDisplayName") orelse plistString(bundle, "CFBundleName") orelse base[0 .. base.len - 4];
        info.name = try inv.gpa.dupe(u8, if (display.len > 0) display else base[0 .. base.len - 4]);
        errdefer inv.gpa.free(info.name);
        const version = plistString(bundle, "CFBundleShortVersionString") orelse plistString(bundle, "CFBundleVersion") orelse "";
        info.version = try inv.gpa.dupe(u8, version);
        if (bundle) |b| {
            const exe = objc.fromNSString(objc.msg(?objc.Object, b, "executablePath", .{}));
            if (exe.len > 0) info.kind = readKind(inv.gpa, exe);
        }
        const receipt = try std.fmt.allocPrintSentinel(inv.gpa, "{s}/Contents/_MASReceipt/receipt", .{path}, 0);
        defer inv.gpa.free(receipt);
        info.app_store = access(receipt, 0) == 0;
        info.last_opened = lastUsed(path);
        try inv.apps.append(inv.gpa, info);
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
        m.* = .{ .inv = inv, .generation = inv.generation, .paths = paths, .out = out, .pool = .{ .gpa = std.heap.smp_allocator, .paths = paths, .out = out } };
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

fn plistString(bundle: ?objc.Object, key: []const u8) ?[]const u8 {
    const b = bundle orelse return null;
    const v = objc.msg(?objc.Object, b, "objectForInfoDictionaryKey:", .{objc.nsString(key)}) orelse return null;
    const is_string = objc.msg(objc.BOOL, v, "isKindOfClass:", .{objc.class("NSString")});
    if (!is_string) return null;
    const s = objc.fromNSString(v);
    return if (s.len > 0) s else null;
}

fn readKind(gpa: std.mem.Allocator, exe: []const u8) Kind {
    const z = gpa.dupeSentinel(u8, exe, 0) catch return .unknown;
    defer gpa.free(z);
    const fd = open(z, 0);
    if (fd < 0) return .unknown;
    defer _ = close(fd);
    var buf: [512]u8 = undefined;
    const n = read(fd, &buf, buf.len);
    if (n <= 0) return .unknown;
    return kindOf(buf[0..@intCast(n)]);
}

fn lastUsed(path: []const u8) i64 {
    const item = MDItemCreate(null, objc.nsString(path)) orelse return 0;
    defer CFRelease(item);
    const date = MDItemCopyAttribute(item, kMDItemLastUsedDate) orelse return 0;
    defer CFRelease(date);
    const since_2001 = CFDateGetAbsoluteTime(date);
    if (since_2001 <= 0) return 0;
    return @intFromFloat(since_2001 + cf_epoch);
}
