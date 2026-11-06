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

pub const Ledger = struct {
    gpa: std.mem.Allocator,
    home: []const u8,
    seen: std.StringHashMapUnmanaged(i64) = .empty,
    dirty: bool = false,
    saved_at: i64 = 0,

    pub fn deinit(l: *Ledger) void {
        var it = l.seen.keyIterator();
        while (it.next()) |k| l.gpa.free(k.*);
        l.seen.deinit(l.gpa);
    }

    pub fn observe(l: *Ledger, running: []const procs.Proc, now: i64) void {
        for (running) |p| if (p.bundle.len > 0 and std.mem.indexOfAny(u8, p.bundle, "\t\n") == null) l.record(p.bundle, now);
    }

    fn record(l: *Ledger, bundle: []const u8, at: i64) void {
        if (l.seen.getPtr(bundle)) |t| {
            if (at > t.*) {
                t.* = at;
                l.dirty = true;
            }
            return;
        }
        const key = l.gpa.dupe(u8, bundle) catch return;
        l.seen.put(l.gpa, key, at) catch return l.gpa.free(key);
        l.dirty = true;
    }

    pub fn lastSeen(l: *const Ledger, bundle: []const u8) i64 {
        return l.seen.get(bundle) orelse 0;
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
            if (!exists(l.gpa, line[tab + 1 ..])) {
                gone = true;
                continue;
            }
            l.record(line[tab + 1 ..], at);
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
        while (it.next()) |e| try text.print(l.gpa, "{d}\t{s}\n", .{ e.value_ptr.*, e.key_ptr.* });
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
