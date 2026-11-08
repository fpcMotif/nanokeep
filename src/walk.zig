const std = @import("std");

extern "c" fn getattrlistbulk(dirfd: c_int, alist: *const AttrList, buf: *anyopaque, size: usize, options: u64) c_int;
extern "c" fn getattrlist(path: [*:0]const u8, alist: *const AttrList, buf: *anyopaque, size: usize, options: u32) c_int;
extern "c" fn getattrlistat(fd: c_int, path: [*:0]const u8, alist: *const AttrList, buf: *anyopaque, size: usize, options: u64) c_int;
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
const one_len = 64;

const mtime_len = @sizeOf(i64);

fn at(comptime T: type, buf: []const u8, off: usize) T {
    return std.mem.readInt(T, buf[off..][0..@sizeOf(T)], .little);
}

fn nanos(buf: []const u8, off: usize) i64 {
    const tv_nsec_at = @sizeOf(i64);
    return at(i64, buf, off) *% std.time.ns_per_s +% at(i64, buf, off + tv_nsec_at);
}

pub const Size = struct {
    bytes: u64 = 0,
    files: u64 = 0,
    newest: i64 = 0,
};

const dir_flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC;
const bulk_len = 64 * 1024;

pub const max_nodes = 1 << 16;
const none = std.math.maxInt(u32);

pub const Node = struct {
    mtime: i64,
    bytes: u64 = 0,
    files: u64 = 0,
    newest: i64 = 0,
    span: u32 = 1,
    name_at: u32,
    name_len: u32,
    shared: bool = false,
};

pub const Tree = struct {
    nodes: []Node,
    names: []u8,

    pub fn deinit(t: *Tree, gpa: std.mem.Allocator) void {
        gpa.free(t.nodes);
        gpa.free(t.names);
    }

    fn name(t: *const Tree, i: u32) []const u8 {
        const n = t.nodes[i];
        return t.names[n.name_at..][0..n.name_len];
    }

    fn end(t: *const Tree, i: u32) u32 {
        return i + t.nodes[i].span;
    }
};

pub const Measured = struct { size: Size, tree: ?Tree, listed: u32 };

pub const Cache = struct {
    trees: std.StringHashMapUnmanaged(Tree) = .empty,
    nodes: usize = 0,

    pub fn deinit(c: *Cache, gpa: std.mem.Allocator) void {
        var it = c.trees.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(gpa);
        }
        c.trees.deinit(gpa);
        c.* = .{};
    }

    pub fn get(c: *const Cache, p: []const u8) ?*const Tree {
        return c.trees.getPtr(p);
    }

    pub fn put(c: *Cache, gpa: std.mem.Allocator, p: []const u8, tree: Tree) void {
        var t = tree;
        if (c.nodes + t.nodes.len > max_nodes or c.trees.contains(p)) return t.deinit(gpa);
        const key = gpa.dupe(u8, p) catch return t.deinit(gpa);
        c.trees.put(gpa, key, t) catch {
            gpa.free(key);
            return t.deinit(gpa);
        };
        c.nodes += t.nodes.len;
    }
};

const Frame = struct {
    fd: c_int,
    anchor: c_int,
    base: usize,
    mark: usize,
    start: usize,
    end: usize,
    next: usize,
    node: u32,
    old: u32,
    old_next: u32,
    cursor: u32,
    reused: bool,

    fn more(f: *const Frame, t: ?*const Tree) bool {
        return if (f.reused) f.old_next < t.?.end(f.old) else f.next < f.end;
    }
};

const Child = struct { mtime: i64, old: u32, name: []const u8, mark: usize };

const PATH_MAX = 1024;
const max_rel = PATH_MAX - 256 - 8;

fn lasting(err: std.c.E) bool {
    return err == .ACCES or err == .PERM or err == .NOENT;
}

pub const Walk = struct {
    gpa: std.mem.Allocator,
    cancel: *const std.atomic.Value(bool),
    size: Size = .{},
    linked: std.AutoHashMapUnmanaged(u64, void) = .empty,
    buf: []align(8) u8 = &.{},
    frames: std.ArrayList(Frame) = .empty,
    names: std.ArrayList(u8) = .empty,
    prev: ?*const Tree = null,
    limit: u32 = 0,
    nodes: std.ArrayList(Node) = .empty,
    tree_names: std.ArrayList(u8) = .empty,
    listed: u32 = 0,
    overflow: bool = false,
    here: Size = .{},
    here_shared: bool = false,
    rel: std.ArrayList(u8) = .empty,

    pub fn deinit(w: *Walk) void {
        w.linked.deinit(w.gpa);
        w.gpa.free(w.buf);
        w.frames.deinit(w.gpa);
        w.names.deinit(w.gpa);
        w.nodes.deinit(w.gpa);
        w.tree_names.deinit(w.gpa);
        w.rel.deinit(w.gpa);
    }

    fn reset(w: *Walk) void {
        w.size = .{};
        w.linked.clearRetainingCapacity();
        w.nodes.clearRetainingCapacity();
        w.tree_names.clearRetainingCapacity();
        w.listed = 0;
        w.overflow = false;
    }

    pub fn path(w: *Walk, p: [*:0]const u8) void {
        var buf: [one_len]u8 align(8) = undefined;
        if (getattrlist(p, &single_list, &buf, buf.len, FSOPT_NOFOLLOW | FSOPT_PACK_INVAL_ATTRS) != 0) return;
        w.size.newest = @max(w.size.newest, at(i64, &buf, one_modtime));
        if (at(u32, &buf, one_objtype) == VDIR) {
            const fd = open(p, dir_flags);
            if (fd >= 0) w.tree(fd, nanos(&buf, one_modtime));
            return;
        }
        if (at(u32, &buf, off_returned_file) & ATTR_FILE_ALLOCSIZE != 0) {
            w.size.bytes += @intCast(@max(0, at(i64, &buf, one_allocsize)));
            w.size.files += 1;
        }
    }

    pub fn takeTree(w: *Walk, gpa: std.mem.Allocator) ?Tree {
        if (w.limit == 0 or w.overflow or w.nodes.items.len == 0 or w.cancel.load(.monotonic)) return null;
        const nodes = gpa.dupe(Node, w.nodes.items) catch return null;
        const names = gpa.dupe(u8, w.tree_names.items) catch {
            gpa.free(nodes);
            return null;
        };
        return .{ .nodes = nodes, .names = names };
    }

    fn tree(w: *Walk, root: c_int, mtime: i64) void {
        if (w.buf.len == 0) w.buf = w.gpa.alignedAlloc(u8, .@"8", bulk_len) catch {
            _ = close(root);
            return;
        };
        const old: u32 = if (w.prev) |t| (if (t.nodes.len > 0) 0 else none) else none;
        w.rel.clearRetainingCapacity();
        w.enter(.{ .mtime = mtime, .old = old, .name = "", .mark = 0 }, root);
        while (w.descend()) |child| w.enter(child, -1);
        for (w.frames.items) |f| if (f.fd >= 0) {
            _ = close(f.fd);
        };
        w.frames.clearRetainingCapacity();
        w.names.clearRetainingCapacity();
    }

    fn relPath(w: *Walk, base: usize) [*:0]const u8 {
        w.rel.items.ptr[w.rel.items.len] = 0;
        return @ptrCast(w.rel.items[base..].ptr);
    }

    fn enter(w: *Walk, c: Child, root: c_int) void {
        const start = w.names.items.len;
        const reused = c.old != none and !w.prev.?.nodes[c.old].shared and w.prev.?.nodes[c.old].mtime == c.mtime;
        if (root < 0) w.size.newest = @max(w.size.newest, @divFloor(c.mtime, std.time.ns_per_s));
        var fd = root;
        var anchor = root;
        var base = w.rel.items.len;
        if (root < 0) {
            const parent = &w.frames.items[w.frames.items.len - 1];
            if (reused and w.rel.items.len - parent.base <= max_rel) {
                anchor = parent.anchor;
                base = parent.base;
            } else {
                fd = openat(parent.anchor, w.relPath(parent.base), dir_flags);
                if (fd < 0) {
                    if (!lasting(std.c.errno(fd))) w.overflow = true;
                    return w.rel.shrinkRetainingCapacity(c.mark);
                }
                anchor = fd;
                if (!parent.more(w.prev) and parent.fd >= 0) {
                    _ = close(parent.fd);
                    parent.fd = -1;
                }
            }
        }
        const node = w.record(c.name, c.mtime);
        w.frames.append(w.gpa, .{ .fd = fd, .anchor = anchor, .base = base, .mark = c.mark, .start = start, .end = start, .next = start, .node = node, .old = c.old, .old_next = c.old +% 1, .cursor = c.old +% 1, .reused = reused }) catch {
            if (fd >= 0) _ = close(fd);
            w.rel.shrinkRetainingCapacity(c.mark);
            w.overflow = true;
            return;
        };
        w.here_shared = false;
        if (reused) {
            const o = w.prev.?.nodes[c.old];
            w.here = .{ .bytes = o.bytes, .files = o.files, .newest = o.newest };
            w.size.bytes += o.bytes;
            w.size.files += o.files;
            w.size.newest = @max(w.size.newest, o.newest);
        } else {
            w.here = .{};
            w.dir(fd);
            w.listed += 1;
            w.frames.items[w.frames.items.len - 1].end = w.names.items.len;
        }
        if (node != none) {
            const n = &w.nodes.items[node];
            n.bytes = w.here.bytes;
            n.files = w.here.files;
            n.newest = w.here.newest;
            n.shared = w.here_shared;
        }
    }

    fn record(w: *Walk, name: []const u8, mtime: i64) u32 {
        if (w.limit == 0 or w.overflow) return none;
        if (w.nodes.items.len >= w.limit) {
            w.overflow = true;
            return none;
        }
        const i: u32 = @intCast(w.nodes.items.len);
        w.nodes.append(w.gpa, .{ .mtime = mtime, .name_at = @intCast(w.tree_names.items.len), .name_len = @intCast(name.len) }) catch {
            w.overflow = true;
            return none;
        };
        w.tree_names.appendSlice(w.gpa, name) catch {
            w.overflow = true;
            return none;
        };
        return i;
    }

    fn descend(w: *Walk) ?Child {
        while (w.frames.items.len > 0 and !w.cancel.load(.monotonic)) {
            const top = &w.frames.items[w.frames.items.len - 1];
            if (!top.more(w.prev)) {
                if (top.node != none) w.nodes.items[top.node].span = @intCast(w.nodes.items.len - top.node);
                if (top.fd >= 0) _ = close(top.fd);
                w.names.shrinkRetainingCapacity(top.start);
                w.rel.shrinkRetainingCapacity(top.mark);
                _ = w.frames.pop();
                continue;
            }
            var c: Child = undefined;
            if (top.reused) {
                const t = w.prev.?;
                const i = top.old_next;
                top.old_next = t.end(i);
                c = .{ .mtime = 0, .old = i, .name = t.name(i), .mark = w.rel.items.len };
            } else {
                const mtime = at(i64, w.names.items, top.next);
                const name = std.mem.sliceTo(w.names.items[top.next + mtime_len ..], 0);
                top.next += mtime_len + name.len + 1;
                c = .{ .mtime = mtime, .old = w.match(top, name), .name = name, .mark = w.rel.items.len };
            }
            const slash: usize = @intFromBool(w.rel.items.len > top.base);
            w.rel.ensureUnusedCapacity(w.gpa, slash + c.name.len + 1) catch {
                w.overflow = true;
                continue;
            };
            if (slash == 1) w.rel.appendAssumeCapacity('/');
            w.rel.appendSliceAssumeCapacity(c.name);
            if (top.reused) {
                var buf: [one_len]u8 align(8) = undefined;
                const got = getattrlistat(top.anchor, w.relPath(top.base), &single_list, &buf, buf.len, FSOPT_NOFOLLOW | FSOPT_PACK_INVAL_ATTRS);
                if (got != 0 or at(u32, &buf, one_objtype) != VDIR) {
                    if (got != 0 and !lasting(std.c.errno(got))) w.overflow = true;
                    w.rel.shrinkRetainingCapacity(c.mark);
                    continue;
                }
                c.mtime = nanos(&buf, one_modtime);
            }
            return c;
        }
        return null;
    }

    fn match(w: *Walk, top: *Frame, name: []const u8) u32 {
        if (top.old == none) return none;
        const t = w.prev.?;
        const first = top.old + 1;
        const last = t.end(top.old);
        if (first >= last) return none;
        var c = if (top.cursor < last) top.cursor else first;
        const begin = c;
        while (true) {
            const after = t.end(c);
            if (std.mem.eql(u8, t.name(c), name)) {
                top.cursor = after;
                return c;
            }
            c = if (after < last) after else first;
            if (c == begin) return none;
        }
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
        const modtime = at(i64, e, off_modtime);
        w.size.newest = @max(w.size.newest, modtime);
        w.here.newest = @max(w.here.newest, modtime);
        if (at(u32, e, off_objtype) == VDIR) {
            const name_at: usize = off_name + @as(usize, @intCast(at(i32, e, off_name)));
            const name_len = at(u32, e, off_name + 4);
            if (name_len == 0 or name_at + name_len > e.len) return;
            const name = std.mem.sliceTo(e[name_at .. name_at + name_len], 0);
            w.names.ensureUnusedCapacity(w.gpa, mtime_len + name.len + 1) catch {
                w.overflow = true;
                return;
            };
            var mtime: [mtime_len]u8 = undefined;
            std.mem.writeInt(i64, &mtime, nanos(e, off_modtime), .little);
            w.names.appendSliceAssumeCapacity(&mtime);
            w.names.appendSliceAssumeCapacity(name);
            w.names.appendAssumeCapacity(0);
            return;
        }
        if (at(u32, e, off_returned_file) & ATTR_FILE_ALLOCSIZE == 0) return;
        if (at(u32, e, off_linkcount) > 1) w.here_shared = true;
        if (at(u32, e, off_linkcount) > 1 and at(u32, e, off_returned_common) & ATTR_CMN_FILEID != 0) {
            const got = w.linked.getOrPut(w.gpa, at(u64, e, off_fileid)) catch {
                w.overflow = true;
                return;
            };
            if (got.found_existing) return;
        }
        const bytes: u64 = @intCast(@max(0, at(i64, e, off_allocsize)));
        w.size.bytes += bytes;
        w.size.files += 1;
        w.here.bytes += bytes;
        w.here.files += 1;
    }
};

pub fn measure(gpa: std.mem.Allocator, p: [*:0]const u8) Size {
    var cancel: std.atomic.Value(bool) = .init(false);
    var w: Walk = .{ .gpa = gpa, .cancel = &cancel };
    defer w.deinit();
    w.path(p);
    return w.size;
}

pub fn measureAgain(gpa: std.mem.Allocator, p: [*:0]const u8, prev: ?*const Tree, limit: u32) Measured {
    var cancel: std.atomic.Value(bool) = .init(false);
    var w: Walk = .{ .gpa = gpa, .cancel = &cancel, .prev = prev, .limit = limit };
    defer w.deinit();
    w.path(p);
    return .{ .size = w.size, .tree = w.takeTree(gpa), .listed = w.listed };
}

const workers = 4;

pub const Pool = struct {
    gpa: std.mem.Allocator,
    paths: []const [:0]const u8,
    out: []Size,
    next: std.atomic.Value(usize) = .init(0),
    cancel: std.atomic.Value(bool) = .init(false),
    stop: ?*const std.atomic.Value(bool) = null,
    measured: ?*std.atomic.Value(u64) = null,
    listed: ?*std.atomic.Value(u64) = null,
    prev: []const ?*const Tree = &.{},
    trees: []?Tree = &.{},
    limit: u32 = max_nodes,

    pub fn run(pool: *Pool) void {
        var helpers: [workers - 1]?std.Thread = @splat(null);
        for (&helpers) |*t| t.* = std.Thread.spawn(.{}, work, .{pool}) catch null;
        work(pool);
        for (helpers) |t| if (t) |th| th.join();
    }

    fn work(pool: *Pool) void {
        const cancel = pool.stop orelse &pool.cancel;
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena.deinit();
        var w: Walk = .{ .gpa = arena.allocator(), .cancel = cancel, .limit = if (pool.trees.len > 0) pool.limit else 0 };
        while (!pool.cancel.load(.monotonic) and !cancel.load(.monotonic)) {
            const i = pool.next.fetchAdd(1, .monotonic);
            if (i >= pool.paths.len) return;
            w.reset();
            w.prev = if (i < pool.prev.len) pool.prev[i] else null;
            w.path(pool.paths[i].ptr);
            pool.out[i] = w.size;
            if (i < pool.trees.len) pool.trees[i] = w.takeTree(pool.gpa);
            if (pool.measured) |m| _ = m.fetchAdd(w.size.bytes, .monotonic);
            if (pool.listed) |l| _ = l.fetchAdd(w.listed, .monotonic);
        }
    }
};
