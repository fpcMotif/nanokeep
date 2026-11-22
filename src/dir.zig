const std = @import("std");

const c = struct {
    extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn __getdirentries64(fd: c_int, buf: [*]u8, len: usize, basep: *i64) isize;
};

const O_RDONLY = 0;
const O_DIRECTORY = 0x100000;
const O_CLOEXEC = 0x1000000;

pub const DT_DIR = 4;
pub const DT_REG = 8;

const Header = extern struct { ino: u64, seekoff: u64, reclen: u16, namlen: u16, kind: u8 };
const name_at = @offsetOf(Header, "kind") + 1;

pub const Entry = struct { name: []const u8, kind: u8 };

pub const Dir = struct {
    fd: c_int,
    buf: [8192]u8 align(8) = undefined,
    len: usize = 0,
    at: usize = 0,
    seek: i64 = 0,

    pub fn open(path: [*:0]const u8) ?Dir {
        const fd = c.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        if (fd < 0) return null;
        return .{ .fd = fd };
    }

    pub fn close(d: *Dir) void {
        _ = c.close(d.fd);
    }

    pub fn next(d: *Dir) ?Entry {
        while (true) {
            if (d.at >= d.len) {
                const n = c.__getdirentries64(d.fd, &d.buf, d.buf.len, &d.seek);
                if (n <= 0) return null;
                d.len = @intCast(n);
                d.at = 0;
            }
            const e = std.mem.bytesToValue(Header, d.buf[d.at..][0..@sizeOf(Header)]);
            if (e.reclen == 0) return null;
            const start = d.at;
            d.at += e.reclen;
            if (e.ino == 0) continue;
            return .{ .name = d.buf[start + name_at ..][0..e.namlen], .kind = e.kind };
        }
    }
};
