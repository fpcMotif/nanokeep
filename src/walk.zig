const std = @import("std");

extern "c" fn getattrlistbulk(dirfd: c_int, alist: *const AttrList, buf: *anyopaque, size: usize, options: u64) c_int;
extern "c" fn getattrlist(path: [*:0]const u8, alist: *const AttrList, buf: *anyopaque, size: usize, options: u32) c_int;
extern "c" fn openat(fd: c_int, path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;

const AttrList = extern struct {
    bitmapcount: u16 = 5,
    reserved: u16 = 0,
    commonattr: u32 = 0,
    volattr: u32 = 0,
    dirattr: u32 = 0,
    fileattr: u32 = 0,
    forkattr: u32 = 0,
};

const ATTR_CMN_NAME = 0x00000001;
const ATTR_CMN_OBJTYPE = 0x00000008;
const ATTR_CMN_MODTIME = 0x00000400;
const ATTR_CMN_FILEID = 0x02000000;
const ATTR_CMN_RETURNED_ATTRS = 0x80000000;
const ATTR_FILE_LINKCOUNT = 0x00000001;
const ATTR_FILE_ALLOCSIZE = 0x00000004;
const FSOPT_NOFOLLOW = 0x1;
const FSOPT_PACK_INVAL_ATTRS = 0x8;

const O_RDONLY = 0;
const O_NOFOLLOW = 0x100;
const O_DIRECTORY = 0x100000;
const O_CLOEXEC = 0x1000000;
const VDIR = 2;

const bulk_list: AttrList = .{
    .commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_FILEID,
    .fileattr = ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE,
};

const single_list: AttrList = .{
    .commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME,
    .fileattr = ATTR_FILE_ALLOCSIZE,
};

const off_returned_common = 4;
const off_returned_file = 16;
const off_name = 24;
const off_objtype = 32;
const off_modtime = 36;
const off_fileid = 52;
const off_linkcount = 60;
const off_allocsize = 64;

const one_objtype = 24;
const one_modtime = 28;
const one_allocsize = 44;

fn at(comptime T: type, buf: []const u8, off: usize) T {
    return std.mem.readInt(T, buf[off..][0..@sizeOf(T)], .little);
}

pub const Size = struct {
    bytes: u64 = 0,
    files: u64 = 0,
    newest: i64 = 0,
};

const dir_flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC;
const bulk_len = 64 * 1024;

const Frame = struct { fd: c_int, start: usize, next: usize };

pub const Walk = struct {
    gpa: std.mem.Allocator,
    cancel: *const std.atomic.Value(bool),
    size: Size = .{},
    linked: std.AutoHashMapUnmanaged(u64, void) = .empty,
    buf: []align(8) u8 = &.{},
    frames: std.ArrayList(Frame) = .empty,
    names: std.ArrayList(u8) = .empty,

    pub fn deinit(w: *Walk) void {
        w.linked.deinit(w.gpa);
        w.gpa.free(w.buf);
        w.frames.deinit(w.gpa);
        w.names.deinit(w.gpa);
    }

    fn reset(w: *Walk) void {
        w.size = .{};
        w.linked.clearRetainingCapacity();
    }

    pub fn path(w: *Walk, p: [*:0]const u8) void {
        var buf: [64]u8 align(8) = undefined;
        if (getattrlist(p, &single_list, &buf, buf.len, FSOPT_NOFOLLOW | FSOPT_PACK_INVAL_ATTRS) != 0) return;
        w.size.newest = @max(w.size.newest, at(i64, &buf, one_modtime));
        if (at(u32, &buf, one_objtype) == VDIR) {
            const fd = open(p, dir_flags);
            if (fd >= 0) w.tree(fd);
            return;
        }
        if (at(u32, &buf, off_returned_file) & ATTR_FILE_ALLOCSIZE != 0) {
            w.size.bytes += @intCast(@max(0, at(i64, &buf, one_allocsize)));
            w.size.files += 1;
        }
    }

    fn tree(w: *Walk, root: c_int) void {
        if (w.buf.len == 0) w.buf = w.gpa.alignedAlloc(u8, .@"8", bulk_len) catch {
            _ = close(root);
            return;
        };
        var fd = root;
        while (fd >= 0) {
            const start = w.names.items.len;
            w.frames.append(w.gpa, .{ .fd = fd, .start = start, .next = start }) catch {
                _ = close(fd);
                break;
            };
            w.dir(fd);
            fd = w.descend();
        }
        for (w.frames.items) |f| _ = close(f.fd);
        w.frames.clearRetainingCapacity();
        w.names.clearRetainingCapacity();
    }

    fn descend(w: *Walk) c_int {
        while (w.frames.items.len > 0 and !w.cancel.load(.monotonic)) {
            const top = &w.frames.items[w.frames.items.len - 1];
            var child: c_int = -1;
            if (top.next < w.names.items.len) {
                const name: [*:0]const u8 = @ptrCast(w.names.items[top.next..].ptr);
                top.next += std.mem.len(name) + 1;
                child = openat(top.fd, name, dir_flags);
            }
            if (top.next == w.names.items.len) {
                _ = close(top.fd);
                w.names.shrinkRetainingCapacity(top.start);
                _ = w.frames.pop();
            }
            if (child >= 0) return child;
        }
        return -1;
    }

    fn dir(w: *Walk, fd: c_int) void {
        while (!w.cancel.load(.monotonic)) {
            const n = getattrlistbulk(fd, &bulk_list, w.buf.ptr, w.buf.len, FSOPT_PACK_INVAL_ATTRS);
            if (n <= 0) return;
            var off: usize = 0;
            for (0..@intCast(n)) |_| {
                const len = at(u32, w.buf, off);
                if (len == 0 or off + len > w.buf.len) return;
                w.entry(w.buf[off .. off + len]);
                off += len;
            }
        }
    }

    fn entry(w: *Walk, e: []const u8) void {
        w.size.newest = @max(w.size.newest, at(i64, e, off_modtime));
        if (at(u32, e, off_objtype) == VDIR) {
            const name_at: usize = off_name + @as(usize, @intCast(at(i32, e, off_name)));
            const name_len = at(u32, e, off_name + 4);
            if (name_len == 0 or name_at + name_len > e.len) return;
            const name = std.mem.sliceTo(e[name_at .. name_at + name_len], 0);
            w.names.ensureUnusedCapacity(w.gpa, name.len + 1) catch return;
            w.names.appendSliceAssumeCapacity(name);
            w.names.appendAssumeCapacity(0);
            return;
        }
        if (at(u32, e, off_returned_file) & ATTR_FILE_ALLOCSIZE == 0) return;
        if (at(u32, e, off_linkcount) > 1 and at(u32, e, off_returned_common) & ATTR_CMN_FILEID != 0) {
            const got = w.linked.getOrPut(w.gpa, at(u64, e, off_fileid)) catch return;
            if (got.found_existing) return;
        }
        w.size.bytes += @intCast(@max(0, at(i64, e, off_allocsize)));
        w.size.files += 1;
    }
};

pub fn measure(gpa: std.mem.Allocator, p: [*:0]const u8) Size {
    var cancel: std.atomic.Value(bool) = .init(false);
    var w: Walk = .{ .gpa = gpa, .cancel = &cancel };
    defer w.deinit();
    w.path(p);
    return w.size;
}

pub fn sizeOf(gpa: std.mem.Allocator, p: [*:0]const u8) u64 {
    return measure(gpa, p).bytes;
}

const max_workers = 16;

pub const Pool = struct {
    gpa: std.mem.Allocator,
    paths: []const [:0]const u8,
    out: []Size,
    workers: usize = 4,
    next: std.atomic.Value(usize) = .init(0),
    cancel: std.atomic.Value(bool) = .init(false),
    stop: ?*const std.atomic.Value(bool) = null,
    measured: ?*std.atomic.Value(u64) = null,

    pub fn run(pool: *Pool) void {
        const helpers = std.math.clamp(pool.workers, 1, max_workers) - 1;
        var threads: [max_workers]?std.Thread = @splat(null);
        for (threads[0..helpers]) |*t| t.* = std.Thread.spawn(.{}, work, .{pool}) catch null;
        work(pool);
        for (threads[0..helpers]) |t| if (t) |th| th.join();
    }

    fn work(pool: *Pool) void {
        const cancel = pool.stop orelse &pool.cancel;
        var arena: std.heap.ArenaAllocator = .init(pool.gpa);
        defer arena.deinit();
        var w: Walk = .{ .gpa = arena.allocator(), .cancel = cancel };
        while (!pool.cancel.load(.monotonic) and !cancel.load(.monotonic)) {
            const i = pool.next.fetchAdd(1, .monotonic);
            if (i >= pool.paths.len) return;
            w.reset();
            w.path(pool.paths[i].ptr);
            pool.out[i] = w.size;
            if (pool.measured) |m| _ = m.fetchAdd(w.size.bytes, .monotonic);
        }
    }
};
