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

pub const Walk = struct {
    gpa: std.mem.Allocator,
    cancel: *const std.atomic.Value(bool),
    size: Size = .{},
    linked: std.AutoHashMapUnmanaged(u64, void) = .empty,

    pub fn deinit(w: *Walk) void {
        w.linked.deinit(w.gpa);
    }

    pub fn path(w: *Walk, p: [*:0]const u8) void {
        var buf: [64]u8 align(8) = undefined;
        if (getattrlist(p, &single_list, &buf, buf.len, FSOPT_NOFOLLOW | FSOPT_PACK_INVAL_ATTRS) != 0) return;
        w.size.newest = @max(w.size.newest, at(i64, &buf, one_modtime));
        if (at(u32, &buf, one_objtype) == VDIR) {
            const fd = open(p, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            if (fd < 0) return;
            defer _ = close(fd);
            w.dir(fd);
            return;
        }
        if (at(u32, &buf, off_returned_file) & ATTR_FILE_ALLOCSIZE != 0) {
            w.size.bytes += @intCast(@max(0, at(i64, &buf, one_allocsize)));
            w.size.files += 1;
        }
    }

    fn dir(w: *Walk, fd: c_int) void {
        var buf: [64 * 1024]u8 align(8) = undefined;
        while (!w.cancel.load(.monotonic)) {
            const n = getattrlistbulk(fd, &bulk_list, &buf, buf.len, FSOPT_PACK_INVAL_ATTRS);
            if (n <= 0) return;
            var off: usize = 0;
            for (0..@intCast(n)) |_| {
                const len = at(u32, &buf, off);
                if (len == 0 or off + len > buf.len) return;
                w.entry(fd, buf[off .. off + len]);
                off += len;
            }
        }
    }

    fn entry(w: *Walk, fd: c_int, e: []const u8) void {
        w.size.newest = @max(w.size.newest, at(i64, e, off_modtime));
        if (at(u32, e, off_objtype) == VDIR) {
            const name_at: usize = off_name + @as(usize, @intCast(at(i32, e, off_name)));
            const name_len = at(u32, e, off_name + 4);
            if (name_len == 0 or name_at + name_len > e.len) return;
            const name: [*:0]const u8 = @ptrCast(e[name_at..].ptr);
            const child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            if (child < 0) return;
            defer _ = close(child);
            w.dir(child);
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

pub const Pool = struct {
    gpa: std.mem.Allocator,
    paths: []const [:0]const u8,
    out: []Size,
    next: std.atomic.Value(usize) = .init(0),
    cancel: std.atomic.Value(bool) = .init(false),
    stop: ?*const std.atomic.Value(bool) = null,
    measured: ?*std.atomic.Value(u64) = null,

    pub fn run(pool: *Pool) void {
        const cpus = std.Thread.getCpuCount() catch 4;
        const n = std.math.clamp(cpus, 1, 16);
        var threads: [16]?std.Thread = @splat(null);
        for (threads[0..n]) |*t| t.* = std.Thread.spawn(.{}, work, .{pool}) catch null;
        work(pool);
        for (threads[0..n]) |t| if (t) |th| th.join();
    }

    fn work(pool: *Pool) void {
        const cancel = pool.stop orelse &pool.cancel;
        while (!pool.cancel.load(.monotonic) and !cancel.load(.monotonic)) {
            const i = pool.next.fetchAdd(1, .monotonic);
            if (i >= pool.paths.len) return;
            var w: Walk = .{ .gpa = pool.gpa, .cancel = cancel };
            defer w.deinit();
            w.path(pool.paths[i].ptr);
            pool.out[i] = w.size;
            if (pool.measured) |m| _ = m.fetchAdd(w.size.bytes, .monotonic);
        }
    }
};
