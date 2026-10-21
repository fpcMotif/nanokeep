const std = @import("std");
const nanoui = @import("nanoui");
const metrics = @import("metrics.zig");
const iokit = @import("iokit.zig");
const run = @import("run.zig");
const objc = nanoui.objc;

extern "c" fn sysctlbyname(name: [*:0]const u8, old: ?*anyopaque, oldlen: ?*usize, new: ?*const anyopaque, newlen: usize) c_int;
extern "c" fn CGGetActiveDisplayList(max: u32, ids: [*]u32, count: *u32) i32;
extern "c" fn CGMainDisplayID() u32;
extern "c" fn CGDisplayCopyDisplayMode(id: u32) ?*anyopaque;
extern "c" fn CGDisplayModeGetPixelWidth(mode: *anyopaque) usize;
extern "c" fn CGDisplayModeGetPixelHeight(mode: *anyopaque) usize;
extern "c" fn CGDisplayModeGetWidth(mode: *anyopaque) usize;
extern "c" fn CGDisplayModeRelease(mode: *anyopaque) void;
extern "c" fn statfs(path: [*:0]const u8, buf: *StatFs) c_int;

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

pub const Display = struct { width: usize, height: usize, scale: usize, main: bool };

pub const Notify = struct { ctx: *anyopaque, func: *const fn (*anyopaque) void };

fn Text(comptime n: usize) type {
    return struct {
        buf: [n]u8 = @splat(0),
        len: usize = 0,

        pub fn get(t: *const @This()) []const u8 {
            return t.buf[0..t.len];
        }

        pub fn set(t: *@This(), s: []const u8) void {
            t.len = @min(s.len, n);
            @memcpy(t.buf[0..t.len], s[0..t.len]);
        }
    };
}

pub const Machine = struct {
    name: Text(64) = .{},
    model: Text(32) = .{},
    chip: Text(64) = .{},
    os: Text(16) = .{},
    build: Text(16) = .{},
    kernel: Text(16) = .{},
    host: Text(64) = .{},
    serial: Text(32) = .{},
    volume: Text(64) = .{},
    format: Text(16) = .{},
    device: Text(32) = .{},
    memory: u64 = 0,
    cores: usize = 0,
    performance: usize = 0,
    efficiency: usize = 0,
    gpu_cores: u32 = 0,
    arm: bool = true,
    boot: i64 = 0,
    displays: [8]Display = undefined,
    display_count: usize = 0,
    on_change: ?Notify = null,
    thread: ?std.Thread = null,

    pub fn read(m: *Machine) void {
        var b: [128]u8 = undefined;
        m.model.set(metrics.sysctlText("hw.model", &b));
        m.chip.set(metrics.sysctlText("machdep.cpu.brand_string", &b));
        m.os.set(metrics.sysctlText("kern.osproductversion", &b));
        m.build.set(metrics.sysctlText("kern.osversion", &b));
        m.kernel.set(metrics.sysctlText("kern.osrelease", &b));
        m.host.set(metrics.sysctlText("kern.hostname", &b));
        if (std.mem.endsWith(u8, m.host.get(), ".local")) m.host.len -= ".local".len;
        m.serial.set(iokit.serial(&b));
        m.memory = @intCast(metrics.sysctlInt("hw.memsize") orelse 0);
        m.cores = @intCast(metrics.sysctlInt("hw.ncpu") orelse 0);
        m.performance = @intCast(metrics.sysctlInt("hw.perflevel0.logicalcpu") orelse 0);
        m.efficiency = @intCast(metrics.sysctlInt("hw.perflevel1.logicalcpu") orelse 0);
        m.arm = (metrics.sysctlInt("hw.optional.arm64") orelse 0) == 1;
        m.gpu_cores = iokit.gpu().cores;
        var tv: extern struct { sec: i64, usec: i32 } = undefined;
        var len: usize = @sizeOf(@TypeOf(tv));
        if (sysctlbyname("kern.boottime", &tv, &len, null, 0) == 0) m.boot = tv.sec;
        m.name.set(familyOf(m.model.get()));
        m.readDisplays();
        m.readVolume();
    }

    fn readVolume(m: *Machine) void {
        var fs: StatFs = undefined;
        if (statfs("/", &fs) == 0) {
            const kind = std.mem.sliceTo(&fs.fstypename, 0);
            var up: [16]u8 = undefined;
            m.format.set(std.ascii.upperString(up[0..@min(kind.len, up.len)], kind[0..@min(kind.len, up.len)]));
            const from = std.mem.sliceTo(&fs.mntfromname, 0);
            m.device.set(if (std.mem.startsWith(u8, from, "/dev/")) from[5..] else from);
        }
        const fm = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
        const name = objc.msg(?objc.Object, fm, "displayNameAtPath:", .{objc.nsString("/")});
        m.volume.set(objc.fromNSString(name));
        if (m.volume.len == 0) m.volume.set("Macintosh HD");
    }

    pub fn readDisplays(m: *Machine) void {
        var ids: [8]u32 = undefined;
        var n: u32 = 0;
        if (CGGetActiveDisplayList(ids.len, &ids, &n) != 0) return;
        const main = CGMainDisplayID();
        m.display_count = 0;
        for (ids[0..n]) |id| {
            const mode = CGDisplayCopyDisplayMode(id) orelse continue;
            defer CGDisplayModeRelease(mode);
            const pw = CGDisplayModeGetPixelWidth(mode);
            const w = @max(1, CGDisplayModeGetWidth(mode));
            m.displays[m.display_count] = .{ .width = pw, .height = CGDisplayModeGetPixelHeight(mode), .scale = @max(1, pw / w), .main = id == main };
            m.display_count += 1;
        }
    }

    pub fn lookUpName(m: *Machine) void {
        if (m.thread != null) return;
        m.thread = std.Thread.spawn(.{}, askProfiler, .{m}) catch null;
    }

    pub fn deinit(m: *Machine) void {
        if (m.thread) |t| t.join();
        m.thread = null;
    }

    fn askProfiler(m: *Machine) void {
        const out = run.capture(std.heap.smp_allocator, &.{ "/usr/sbin/system_profiler", "SPHardwareDataType", "-json" }) catch return;
        defer out.deinit(std.heap.smp_allocator);
        const name = jsonField(out.out, "machine_name") orelse return;
        const owned = std.heap.smp_allocator.dupe(u8, name) catch return;
        const Done = struct {
            m: *Machine,
            name: []u8,
            fn apply(ctx: ?*anyopaque) callconv(.c) void {
                const d: *@This() = @ptrCast(@alignCast(ctx));
                d.m.name.set(d.name);
                if (d.m.on_change) |n| n.func(n.ctx);
                std.heap.smp_allocator.free(d.name);
                std.heap.smp_allocator.destroy(d);
            }
        };
        const d = std.heap.smp_allocator.create(Done) catch return std.heap.smp_allocator.free(owned);
        d.* = .{ .m = m, .name = owned };
        objc.dispatchMain(d, Done.apply);
    }
};

pub fn jsonField(json: []const u8, key: []const u8) ?[]const u8 {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, json, at, key)) |i| {
        at = i + key.len;
        if (i == 0 or json[i - 1] != '"' or at >= json.len or json[at] != '"') continue;
        var j = at + 1;
        while (j < json.len and (json[j] == ' ' or json[j] == ':' or json[j] == '\t')) j += 1;
        if (j >= json.len or json[j] != '"') return null;
        const end = std.mem.indexOfScalarPos(u8, json, j + 1, '"') orelse return null;
        return json[j + 1 .. end];
    }
    return null;
}

pub fn familyOf(model: []const u8) []const u8 {
    const families = [_][2][]const u8{
        .{ "MacBookPro", "MacBook Pro" },
        .{ "MacBookAir", "MacBook Air" },
        .{ "MacBook", "MacBook" },
        .{ "Macmini", "Mac mini" },
        .{ "MacPro", "Mac Pro" },
        .{ "iMac", "iMac" },
    };
    for (families) |f| if (std.mem.startsWith(u8, model, f[0])) return f[1];
    return "Mac";
}
