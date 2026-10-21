const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;

const CFRef = *anyopaque;
const CFIndex = isize;

extern "c" fn CFRelease(ref: CFRef) void;
extern "c" fn CFGetTypeID(ref: CFRef) usize;
extern "c" fn CFNumberGetTypeID() usize;
extern "c" fn CFStringGetTypeID() usize;
extern "c" fn CFDataGetTypeID() usize;
extern "c" fn CFDictionaryGetTypeID() usize;
extern "c" fn CFArrayGetTypeID() usize;
extern "c" fn CFBooleanGetTypeID() usize;
extern "c" fn CFBooleanGetValue(b: CFRef) bool;
extern "c" fn CFNumberGetValue(n: CFRef, kind: CFIndex, out: *anyopaque) bool;
extern "c" fn CFNumberCreate(alloc: ?CFRef, kind: CFIndex, value: *const anyopaque) ?CFRef;
extern "c" fn CFStringCreateWithBytes(alloc: ?CFRef, bytes: [*]const u8, len: CFIndex, encoding: u32, external: bool) ?CFRef;
extern "c" fn CFStringGetCString(s: CFRef, buf: [*]u8, len: CFIndex, encoding: u32) bool;
extern "c" fn CFDataGetBytePtr(d: CFRef) [*]const u8;
extern "c" fn CFDataGetLength(d: CFRef) CFIndex;
extern "c" fn CFDictionaryGetValue(d: CFRef, key: CFRef) ?CFRef;
extern "c" fn CFDictionaryGetCount(d: CFRef) CFIndex;
extern "c" fn CFDictionaryGetKeysAndValues(d: CFRef, keys: [*]?CFRef, values: [*]?CFRef) void;
extern "c" fn CFDictionaryCreate(alloc: ?CFRef, keys: [*]const ?*const anyopaque, values: [*]const ?*const anyopaque, n: CFIndex, key_cb: *const anyopaque, value_cb: *const anyopaque) ?CFRef;
extern "c" fn CFArrayGetCount(a: CFRef) CFIndex;
extern "c" fn CFArrayGetValueAtIndex(a: CFRef, i: CFIndex) ?CFRef;
extern "c" const kCFTypeDictionaryKeyCallBacks: opaque {};
extern "c" const kCFTypeDictionaryValueCallBacks: opaque {};

extern "c" fn IOServiceMatching(name: [*:0]const u8) ?CFRef;
extern "c" fn IOServiceGetMatchingServices(port: c_uint, matching: CFRef, it: *c_uint) c_int;
extern "c" fn IOServiceGetMatchingService(port: c_uint, matching: CFRef) c_uint;
extern "c" fn IOIteratorNext(it: c_uint) c_uint;
extern "c" fn IOObjectRelease(obj: c_uint) c_int;
extern "c" fn IORegistryEntryCreateCFProperty(entry: c_uint, key: CFRef, alloc: ?CFRef, options: u32) ?CFRef;

extern "c" fn IOPSCopyPowerSourcesInfo() ?CFRef;
extern "c" fn IOPSGetProvidingPowerSourceType(blob: CFRef) ?CFRef;
extern "c" fn IOPSCopyPowerSourcesList(blob: CFRef) ?CFRef;
extern "c" fn IOPSGetPowerSourceDescription(blob: CFRef, ps: CFRef) ?CFRef;
extern "c" fn IOPMCopyAssertionsByProcess(out: *?CFRef) c_int;

extern "c" fn IOHIDEventSystemClientCreate(alloc: ?CFRef) ?CFRef;
extern "c" fn IOHIDEventSystemClientSetMatching(client: CFRef, matching: CFRef) c_int;
extern "c" fn IOHIDEventSystemClientCopyServices(client: CFRef) ?CFRef;
extern "c" fn IOHIDServiceClientCopyProperty(service: CFRef, key: CFRef) ?CFRef;
extern "c" fn IOHIDServiceClientCopyEvent(service: CFRef, kind: i64, options: i32, timestamp: i64) ?CFRef;
extern "c" fn IOHIDEventGetFloatValue(event: CFRef, field: i32) f64;

const utf8: u32 = 0x08000100;
const number_i64: CFIndex = 4;
const number_f64: CFIndex = 13;
const number_i32: CFIndex = 3;
const hid_temperature: i64 = 15;

fn str(s: []const u8) CFRef {
    return CFStringCreateWithBytes(null, s.ptr, @intCast(s.len), utf8, false).?;
}

fn isA(ref: CFRef, id: usize) bool {
    return CFGetTypeID(ref) == id;
}

fn get(d: CFRef, key: []const u8) ?CFRef {
    if (!isA(d, CFDictionaryGetTypeID())) return null;
    const k = str(key);
    defer CFRelease(k);
    return CFDictionaryGetValue(d, k);
}

fn int(ref: ?CFRef) ?i64 {
    const r = ref orelse return null;
    if (isA(r, CFBooleanGetTypeID())) return @intFromBool(CFBooleanGetValue(r));
    if (!isA(r, CFNumberGetTypeID())) return null;
    var v: i64 = 0;
    _ = CFNumberGetValue(r, number_i64, &v);
    return v;
}

fn text(ref: ?CFRef, buf: []u8) []const u8 {
    const r = ref orelse return "";
    if (isA(r, CFStringGetTypeID())) {
        if (!CFStringGetCString(r, buf.ptr, @intCast(buf.len), utf8)) return "";
        return std.mem.sliceTo(buf, 0);
    }
    if (isA(r, CFDataGetTypeID())) {
        const n: usize = @intCast(CFDataGetLength(r));
        const src = CFDataGetBytePtr(r)[0..n];
        const s = std.mem.sliceTo(src, 0);
        const len = @min(s.len, buf.len);
        @memcpy(buf[0..len], s[0..len]);
        return buf[0..len];
    }
    return "";
}

fn property(entry: c_uint, key: []const u8) ?CFRef {
    const k = str(key);
    defer CFRelease(k);
    return IORegistryEntryCreateCFProperty(entry, k, null, 0);
}

fn each(class: [*:0]const u8, ctx: anytype, comptime f: fn (@TypeOf(ctx), c_uint) void) void {
    const matching = IOServiceMatching(class) orelse return;
    var it: c_uint = 0;
    if (IOServiceGetMatchingServices(0, matching, &it) != 0) return;
    defer _ = IOObjectRelease(it);
    while (true) {
        const entry = IOIteratorNext(it);
        if (entry == 0) break;
        defer _ = IOObjectRelease(entry);
        f(ctx, entry);
    }
}

pub const Gpu = struct {
    device: f32 = 0,
    renderer: f32 = 0,
    tiler: f32 = 0,
    in_use: u64 = 0,
    allocated: u64 = 0,
    cores: u32 = 0,
    found: bool = false,
};

pub fn gpu() Gpu {
    var g: Gpu = .{};
    each("IOAccelerator", &g, struct {
        fn f(out: *Gpu, entry: c_uint) void {
            if (property(entry, "gpu-core-count")) |n| {
                defer CFRelease(n);
                out.cores = @intCast(@max(0, int(n) orelse 0));
            }
            const stats = property(entry, "PerformanceStatistics") orelse return;
            defer CFRelease(stats);
            out.found = true;
            out.device = @floatFromInt(int(get(stats, "Device Utilization %")) orelse 0);
            out.renderer = @floatFromInt(int(get(stats, "Renderer Utilization %")) orelse 0);
            out.tiler = @floatFromInt(int(get(stats, "Tiler Utilization %")) orelse 0);
            out.in_use = @intCast(@max(0, int(get(stats, "In use system memory")) orelse 0));
            out.allocated = @intCast(@max(0, int(get(stats, "Alloc system memory")) orelse 0));
        }
    }.f);
    return g;
}

pub const DiskBytes = struct { read: u64 = 0, written: u64 = 0 };

pub fn diskBytes() DiskBytes {
    var d: DiskBytes = .{};
    each("IOBlockStorageDriver", &d, struct {
        fn f(out: *DiskBytes, entry: c_uint) void {
            const stats = property(entry, "Statistics") orelse return;
            defer CFRelease(stats);
            out.read += @intCast(@max(0, int(get(stats, "Bytes (Read)")) orelse 0));
            out.written += @intCast(@max(0, int(get(stats, "Bytes (Write)")) orelse 0));
        }
    }.f);
    return d;
}

pub fn serial(buf: []u8) []const u8 {
    const matching = IOServiceMatching("IOPlatformExpertDevice") orelse return "";
    const entry = IOServiceGetMatchingService(0, matching);
    if (entry == 0) return "";
    defer _ = IOObjectRelease(entry);
    const v = property(entry, "IOPlatformSerialNumber") orelse return "";
    defer CFRelease(v);
    return text(v, buf);
}

pub const Temps = struct {
    cpu: f32 = 0,
    cpu_max: f32 = 0,
    storage: f32 = 0,
    found: bool = false,
};

pub const Thermometer = struct {
    client: ?CFRef = null,
    tried: bool = false,

    pub fn deinit(t: *Thermometer) void {
        if (t.client) |c| CFRelease(c);
        t.client = null;
    }

    fn open(t: *Thermometer) ?CFRef {
        if (t.tried) return t.client;
        t.tried = true;
        const client = IOHIDEventSystemClientCreate(null) orelse return null;
        const page: i32 = 0xff00;
        const usage: i32 = 5;
        const kp = str("PrimaryUsagePage");
        defer CFRelease(kp);
        const ku = str("PrimaryUsage");
        defer CFRelease(ku);
        const vp = CFNumberCreate(null, number_i32, &page).?;
        defer CFRelease(vp);
        const vu = CFNumberCreate(null, number_i32, &usage).?;
        defer CFRelease(vu);
        const keys = [_]?*const anyopaque{ kp, ku };
        const values = [_]?*const anyopaque{ vp, vu };
        const matching = CFDictionaryCreate(null, &keys, &values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) orelse return null;
        defer CFRelease(matching);
        _ = IOHIDEventSystemClientSetMatching(client, matching);
        t.client = client;
        return client;
    }

    pub fn read(t: *Thermometer) Temps {
        var out: Temps = .{};
        const client = t.open() orelse return out;
        const services = IOHIDEventSystemClientCopyServices(client) orelse return out;
        defer CFRelease(services);
        const key = str("Product");
        defer CFRelease(key);
        var cpu_sum: f64 = 0;
        var cpu_n: usize = 0;
        var nand_sum: f64 = 0;
        var nand_n: usize = 0;
        const n = CFArrayGetCount(services);
        var i: CFIndex = 0;
        while (i < n) : (i += 1) {
            const svc = CFArrayGetValueAtIndex(services, i) orelse continue;
            const name_ref = IOHIDServiceClientCopyProperty(svc, key) orelse continue;
            defer CFRelease(name_ref);
            var nb: [64]u8 = undefined;
            const name = text(name_ref, &nb);
            const cpu = std.mem.startsWith(u8, name, "PMU tdie") or std.mem.startsWith(u8, name, "pACC") or std.mem.startsWith(u8, name, "eACC");
            const nand = std.mem.indexOf(u8, name, "NAND") != null;
            if (!cpu and !nand) continue;
            const ev = IOHIDServiceClientCopyEvent(svc, hid_temperature, 0, 0) orelse continue;
            defer CFRelease(ev);
            const v = IOHIDEventGetFloatValue(ev, @intCast(hid_temperature << 16));
            if (v <= 0 or v > 150) continue;
            if (cpu) {
                cpu_sum += v;
                cpu_n += 1;
                out.cpu_max = @max(out.cpu_max, @as(f32, @floatCast(v)));
            } else {
                nand_sum += v;
                nand_n += 1;
            }
        }
        if (cpu_n > 0) out.cpu = @floatCast(cpu_sum / @as(f64, @floatFromInt(cpu_n)));
        if (nand_n > 0) out.storage = @floatCast(nand_sum / @as(f64, @floatFromInt(nand_n)));
        out.found = cpu_n > 0 or nand_n > 0;
        return out;
    }
};

pub const Power = struct {
    adapter: bool = true,
    battery: ?u8 = null,
    charging: bool = false,
    minutes_left: ?u32 = null,
};

pub fn power() Power {
    var p: Power = .{};
    const blob = IOPSCopyPowerSourcesInfo() orelse return p;
    defer CFRelease(blob);
    var tb: [32]u8 = undefined;
    if (IOPSGetProvidingPowerSourceType(blob)) |kind| p.adapter = !std.mem.eql(u8, text(kind, &tb), "Battery Power");
    const list = IOPSCopyPowerSourcesList(blob) orelse return p;
    defer CFRelease(list);
    if (CFArrayGetCount(list) == 0) return p;
    const desc = IOPSGetPowerSourceDescription(blob, CFArrayGetValueAtIndex(list, 0) orelse return p) orelse return p;
    const cap = int(get(desc, "Current Capacity")) orelse return p;
    const max = int(get(desc, "Max Capacity")) orelse 100;
    p.battery = @intCast(std.math.clamp(@divTrunc(cap * 100, @max(1, max)), 0, 100));
    p.charging = (int(get(desc, "Is Charging")) orelse 0) != 0;
    if (int(get(desc, "Time to Empty"))) |m| if (m > 0) {
        p.minutes_left = @intCast(m);
    };
    return p;
}

pub const Thermal = enum(u8) {
    nominal,
    fair,
    serious,
    critical,

    pub fn title(t: Thermal) []const u8 {
        return switch (t) {
            .nominal => "Nominal",
            .fair => "Fair",
            .serious => "Serious",
            .critical => "Critical",
        };
    }
};

pub fn thermal() Thermal {
    const info = objc.msg(objc.Object, objc.class("NSProcessInfo"), "processInfo", .{});
    const v = objc.msg(objc.NSInteger, info, "thermalState", .{});
    return @enumFromInt(@as(u8, @intCast(std.math.clamp(v, 0, 3))));
}

pub const Assertion = struct {
    pid: i32,
    name: [48]u8 = @splat(0),
    display: bool = false,

    pub fn label(a: *const Assertion) []const u8 {
        return std.mem.sliceTo(&a.name, 0);
    }
};

pub fn assertions(out: []Assertion) usize {
    var dict: ?CFRef = null;
    if (IOPMCopyAssertionsByProcess(&dict) != 0) return 0;
    const d = dict orelse return 0;
    defer CFRelease(d);
    const n: usize = @intCast(CFDictionaryGetCount(d));
    var keys: [256]?CFRef = undefined;
    var values: [256]?CFRef = undefined;
    if (n > keys.len) return 0;
    CFDictionaryGetKeysAndValues(d, &keys, &values);
    var count: usize = 0;
    for (keys[0..n], values[0..n]) |k, v| {
        if (count == out.len) break;
        const pid = int(k) orelse continue;
        const list = v orelse continue;
        if (!isA(list, CFArrayGetTypeID())) continue;
        var a: Assertion = .{ .pid = @intCast(pid) };
        var any = false;
        var i: CFIndex = 0;
        while (i < CFArrayGetCount(list)) : (i += 1) {
            const item = CFArrayGetValueAtIndex(list, i) orelse continue;
            var tb: [64]u8 = undefined;
            const kind = text(get(item, "AssertType"), &tb);
            if (!keepsAwake(kind)) continue;
            const display = displayKind(kind);
            if (any and a.display and !display) continue;
            any = true;
            a.display = display;
            var nb: [48]u8 = undefined;
            const name = text(get(item, "AssertName"), &nb);
            @memset(&a.name, 0);
            @memcpy(a.name[0..@min(name.len, a.name.len - 1)], name[0..@min(name.len, a.name.len - 1)]);
        }
        if (!any) continue;
        out[count] = a;
        count += 1;
    }
    return count;
}

pub fn keepsAwake(kind: []const u8) bool {
    const kinds = [_][]const u8{ "PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion", "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion" };
    for (kinds) |k| if (std.mem.eql(u8, k, kind)) return true;
    return false;
}

pub fn displayKind(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "PreventUserIdleDisplaySleep") or std.mem.eql(u8, kind, "NoDisplaySleepAssertion");
}
