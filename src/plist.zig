const std = @import("std");

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;

const max_size = 1 << 20;

pub fn readFile(gpa: std.mem.Allocator, path: [*:0]const u8) ![]u8 {
    const fd = open(path, 0);
    if (fd < 0) return error.FileNotFound;
    defer _ = close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    while (out.items.len < max_size) {
        try out.ensureUnusedCapacity(gpa, 16 * 1024);
        const n = read(fd, out.unusedCapacitySlice().ptr, @min(out.unusedCapacitySlice().len, max_size - out.items.len));
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        out.items.len += @intCast(n);
    }
    return out.toOwnedSlice(gpa);
}

pub fn string(gpa: std.mem.Allocator, data: []const u8, key: []const u8) !?[]u8 {
    if (std.mem.startsWith(u8, data, "bplist00")) return binaryString(gpa, data, key) catch |err| switch (err) {
        error.OutOfMemory => err,
        else => null,
    };
    return xmlString(gpa, data, key);
}

const Tag = struct { name: []const u8, close: bool, empty: bool, end: usize };

fn nextTag(data: []const u8, from: usize) ?Tag {
    var pos = from;
    while (std.mem.indexOfScalarPos(u8, data, pos, '<')) |lt| {
        if (std.mem.startsWith(u8, data[lt..], "<!--")) {
            pos = (std.mem.indexOfPos(u8, data, lt, "-->") orelse return null) + 3;
            continue;
        }
        const gt = std.mem.indexOfScalarPos(u8, data, lt, '>') orelse return null;
        if (data[lt + 1] == '?' or data[lt + 1] == '!') {
            pos = gt + 1;
            continue;
        }
        const closing = data[lt + 1] == '/';
        const empty = gt > lt + 1 + @intFromBool(closing) and data[gt - 1] == '/';
        const body = data[lt + 1 + @intFromBool(closing) .. gt - @intFromBool(empty)];
        const name_end = std.mem.indexOfAny(u8, body, " \t\r\n") orelse body.len;
        return .{ .name = body[0..name_end], .close = closing, .empty = empty, .end = gt + 1 };
    }
    return null;
}

fn xmlString(gpa: std.mem.Allocator, data: []const u8, key: []const u8) !?[]u8 {
    var tag = nextTag(data, 0) orelse return null;
    while (!std.mem.eql(u8, tag.name, "dict") or tag.close) tag = nextTag(data, tag.end) orelse return null;
    if (tag.empty) return null;
    var depth: usize = 0;
    var matched = false;
    while (nextTag(data, tag.end)) |t| {
        tag = t;
        const nests = std.mem.eql(u8, t.name, "dict") or std.mem.eql(u8, t.name, "array");
        if (t.close) {
            if (!nests) continue;
            if (depth == 0) return null;
            depth -= 1;
            continue;
        }
        if (depth == 0) {
            if (std.mem.eql(u8, t.name, "key") and !t.empty) {
                const end = std.mem.indexOfPos(u8, data, t.end, "</key>") orelse return null;
                matched = std.mem.eql(u8, data[t.end..end], key);
                tag.end = end;
                continue;
            }
            if (matched) {
                if (!std.mem.eql(u8, t.name, "string")) return null;
                if (t.empty) return try gpa.dupe(u8, "");
                const end = std.mem.indexOfPos(u8, data, t.end, "</string>") orelse return null;
                return try unescape(gpa, data[t.end..end]);
            }
        }
        if (nests and !t.empty) depth += 1;
    }
    return null;
}

fn unescape(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = try .initCapacity(gpa, text.len);
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) {
        const semi = if (text[i] == '&') std.mem.indexOfScalarPos(u8, text, i, ';') else null;
        const entity = if (semi) |s| text[i + 1 .. s] else "";
        const named: ?u8 = if (std.mem.eql(u8, entity, "amp")) '&' else if (std.mem.eql(u8, entity, "lt")) '<' else if (std.mem.eql(u8, entity, "gt")) '>' else if (std.mem.eql(u8, entity, "quot")) '"' else if (std.mem.eql(u8, entity, "apos")) '\'' else null;
        if (named) |c| {
            out.appendAssumeCapacity(c);
        } else if (entity.len > 1 and entity[0] == '#') {
            const code = (if (entity[1] == 'x') std.fmt.parseInt(u21, entity[2..], 16) else std.fmt.parseInt(u21, entity[1..], 10)) catch {
                out.appendAssumeCapacity(text[i]);
                i += 1;
                continue;
            };
            var utf8: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(code, &utf8) catch 0;
            try out.appendSlice(gpa, utf8[0..n]);
        } else {
            out.appendAssumeCapacity(text[i]);
            i += 1;
            continue;
        }
        i = semi.? + 1;
    }
    return out.toOwnedSlice(gpa);
}

const Binary = struct {
    data: []const u8,
    offset_size: u8,
    ref_size: u8,
    count: u64,
    table: u64,

    fn int(data: []const u8, at: u64, size: u8) !u64 {
        if (size == 0 or size > 8 or at > data.len or size > data.len - at) return error.Invalid;
        var v: u64 = 0;
        for (data[@intCast(at)..][0..size]) |b| v = v << 8 | b;
        return v;
    }

    fn object(b: Binary, index: u64) !u64 {
        if (index >= b.count) return error.Invalid;
        return int(b.data, try offset(b.table, index, b.offset_size), b.offset_size);
    }

    fn ref(b: Binary, at: u64, i: u64) !u64 {
        return int(b.data, try offset(at, i, b.ref_size), b.ref_size);
    }

    fn offset(base: u64, index: u64, size: u64) !u64 {
        return std.math.add(u64, base, std.math.mul(u64, index, size) catch return error.Invalid) catch error.Invalid;
    }

    fn fits(b: Binary, at: u64, len: u64) bool {
        return at <= b.data.len and len <= b.data.len - at;
    }

    const Head = struct { kind: u8, len: u64, body: u64 };

    fn head(b: Binary, at: u64) !Head {
        if (at >= b.data.len) return error.Invalid;
        const marker = b.data[@intCast(at)];
        const info = marker & 0xf;
        if (info != 0xf) return .{ .kind = marker >> 4, .len = info, .body = at + 1 };
        if (at + 1 >= b.data.len or b.data[@intCast(at + 1)] >> 4 != 1) return error.Invalid;
        const power = b.data[@intCast(at + 1)] & 0xf;
        if (power > 3) return error.Invalid;
        const size: u8 = @as(u8, 1) << @intCast(power);
        return .{ .kind = marker >> 4, .len = try int(b.data, at + 2, size), .body = at + 2 + size };
    }

    fn ascii(b: Binary, h: Head) ![]const u8 {
        if (h.kind != 5 or !b.fits(h.body, h.len)) return error.Invalid;
        return b.data[@intCast(h.body)..][0..@intCast(h.len)];
    }
};

fn binaryString(gpa: std.mem.Allocator, data: []const u8, key: []const u8) !?[]u8 {
    if (data.len < 40) return error.Invalid;
    const trailer = data[data.len - 32 ..];
    const b: Binary = .{
        .data = data,
        .offset_size = trailer[6],
        .ref_size = trailer[7],
        .count = try Binary.int(trailer, 8, 8),
        .table = try Binary.int(trailer, 24, 8),
    };
    const root = try b.head(try b.object(try Binary.int(trailer, 16, 8)));
    if (root.kind != 0xd or root.len > data.len) return null;
    for (0..root.len) |i| {
        const k = try b.head(try b.object(try b.ref(root.body, i)));
        if (k.kind != 5 or !std.mem.eql(u8, try b.ascii(k), key)) continue;
        const v = try b.head(try b.object(try b.ref(root.body, root.len + i)));
        if (v.kind == 5) return try gpa.dupe(u8, try b.ascii(v));
        if (v.kind != 6 or v.len > data.len or !b.fits(v.body, v.len * 2)) return null;
        const units = try gpa.alloc(u16, @intCast(v.len));
        defer gpa.free(units);
        for (units, 0..) |*u, j| u.* = std.mem.readInt(u16, data[@intCast(v.body + j * 2)..][0..2], .big);
        return try std.unicode.utf16LeToUtf8Alloc(gpa, units);
    }
    return null;
}
