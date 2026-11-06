const std = @import("std");
const procs = @import("procs.zig");
const apps = @import("apps.zig");
const plist = @import("plist.zig");

extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn rename(from: [*:0]const u8, to: [*:0]const u8) c_int;

const O_WRONLY = 0x1;
const O_CREAT = 0x200;
const O_TRUNC = 0x400;
const dir = "Library/Application Support/nanokeep";
pub const save_every = 300;

pub const Use = struct { at: i64 = 0, picks: u32 = 0 };

pub const Ledger = struct {
    gpa: std.mem.Allocator,
    home: []const u8,
    seen: std.StringHashMapUnmanaged(Use) = .empty,
    dirty: bool = false,
    saved_at: i64 = 0,
    runs: u64 = 0,

    pub fn deinit(l: *Ledger) void {
        var it = l.seen.keyIterator();
        while (it.next()) |k| l.gpa.free(k.*);
        l.seen.deinit(l.gpa);
    }

    pub fn observe(l: *Ledger, running: []const procs.Proc, now: i64) void {
        for (running) |p| l.record(p.bundle, now);
    }

    fn record(l: *Ledger, bundle: []const u8, at: i64) void {
        const u = l.entry(bundle) orelse return;
        if (at > u.at) {
            u.at = at;
            l.dirty = true;
            l.runs += 1;
        }
    }

    fn entry(l: *Ledger, bundle: []const u8) ?*Use {
        if (bundle.len == 0 or std.mem.indexOfAny(u8, bundle, "\t\n") != null) return null;
        if (l.seen.getPtr(bundle)) |u| return u;
        const key = l.gpa.dupe(u8, bundle) catch return null;
        const got = l.seen.getOrPut(l.gpa, key) catch {
            l.gpa.free(key);
            return null;
        };
        got.value_ptr.* = .{};
        return got.value_ptr;
    }

    pub fn pick(l: *Ledger, bundle: []const u8) void {
        const u = l.entry(bundle) orelse return;
        u.picks +|= 1;
        l.dirty = true;
    }

    pub fn lastSeen(l: *const Ledger, bundle: []const u8) i64 {
        return (l.seen.get(bundle) orelse return 0).at;
    }

    pub fn boost(l: *const Ledger, bundle: []const u8, now: i64) i32 {
        const u = l.seen.get(bundle) orelse return 0;
        const age = now - u.at;
        const day = std.time.s_per_day;
        const recent: i32 = if (u.at == 0) 0 else if (age < std.time.s_per_hour) 24 else if (age < day) 16 else if (age < 7 * day) 8 else if (age < 30 * day) 4 else 0;
        return recent + 4 * @as(i32, @intCast(@min(u.picks, 8)));
    }

    pub fn apply(l: *const Ledger, list: []apps.AppInfo) bool {
        var changed = false;
        for (list) |*info| {
            const seen = l.lastSeen(info.path);
            changed = changed or seen != info.last_opened;
            info.last_opened = seen;
        }
        return changed;
    }

    pub fn load(l: *Ledger) void {
        const path = std.fmt.allocPrintSentinel(l.gpa, "{s}/" ++ dir ++ "/usage.tsv", .{l.home}, 0) catch return;
        defer l.gpa.free(path);
        const data = plist.readFile(l.gpa, path) catch return;
        defer l.gpa.free(data);
        var lines = std.mem.splitScalar(u8, data, '\n');
        var gone = false;
        while (lines.next()) |line| {
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            const at = std.fmt.parseInt(i64, line[0..tab], 10) catch continue;
            var bundle = line[tab + 1 ..];
            var count: u32 = 0;
            if (std.mem.indexOfScalar(u8, bundle, '\t')) |end| {
                count = std.fmt.parseInt(u32, bundle[end + 1 ..], 10) catch 0;
                bundle = bundle[0..end];
            }
            if (!exists(l.gpa, bundle)) {
                gone = true;
                continue;
            }
            const u = l.entry(bundle) orelse continue;
            u.at = @max(u.at, at);
            u.picks = count;
        }
        l.dirty = gone;
    }

    fn exists(gpa: std.mem.Allocator, bundle: []const u8) bool {
        const z = gpa.dupeSentinel(u8, bundle, 0) catch return true;
        defer gpa.free(z);
        return bundle.len > 0 and access(z, 0) == 0;
    }

    pub fn save(l: *Ledger) !void {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(l.gpa);
        var it = l.seen.iterator();
        while (it.next()) |e| try text.print(l.gpa, "{d}\t{s}\t{d}\n", .{ e.value_ptr.at, e.key_ptr.*, e.value_ptr.picks });
        var parts = std.mem.splitScalar(u8, dir, '/');
        var sub: std.ArrayList(u8) = .empty;
        defer sub.deinit(l.gpa);
        try sub.appendSlice(l.gpa, l.home);
        while (parts.next()) |part| {
            try sub.print(l.gpa, "/{s}", .{part});
            try sub.append(l.gpa, 0);
            _ = mkdir(@ptrCast(sub.items.ptr), 0o755);
            sub.items.len -= 1;
        }
        const tmp = try std.fmt.allocPrintSentinel(l.gpa, "{s}/usage.tsv.tmp", .{sub.items}, 0);
        defer l.gpa.free(tmp);
        const final = try std.fmt.allocPrintSentinel(l.gpa, "{s}/usage.tsv", .{sub.items}, 0);
        defer l.gpa.free(final);
        const fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, @as(c_uint, 0o644));
        if (fd < 0) return error.SaveFailed;
        var done: usize = 0;
        while (done < text.items.len) {
            const n = write(fd, text.items[done..].ptr, text.items.len - done);
            if (n <= 0) {
                _ = close(fd);
                return error.SaveFailed;
            }
            done += @intCast(n);
        }
        if (close(fd) != 0 or rename(tmp, final) != 0) return error.SaveFailed;
        l.dirty = false;
    }
};
