const std = @import("std");

extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern "c" fn posix_spawn(pid: *c_int, path: [*:0]const u8, actions: ?*const anyopaque, attr: ?*const anyopaque, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn posix_spawn_file_actions_init(a: *?*anyopaque) c_int;
extern "c" fn posix_spawn_file_actions_destroy(a: *?*anyopaque) c_int;
extern "c" fn posix_spawn_file_actions_adddup2(a: *?*anyopaque, fd: c_int, newfd: c_int) c_int;
extern "c" fn posix_spawn_file_actions_addclose(a: *?*anyopaque, fd: c_int) c_int;
extern "c" fn posix_spawn_file_actions_addopen(a: *?*anyopaque, fd: c_int, path: [*:0]const u8, oflag: c_int, mode: c_uint) c_int;

const O_WRONLY = 0x1;

pub const Output = struct {
    out: []u8,
    code: u8,

    pub fn deinit(o: Output, gpa: std.mem.Allocator) void {
        gpa.free(o.out);
    }
};

pub fn capture(gpa: std.mem.Allocator, argv: []const []const u8) !Output {
    const cargv = try gpa.allocSentinel(?[*:0]const u8, argv.len, null);
    @memset(cargv, null);
    defer {
        for (cargv) |s| if (s) |p| gpa.free(std.mem.span(p));
        gpa.free(cargv);
    }
    for (argv, 0..) |s, i| cargv[i] = try gpa.dupeSentinel(u8, s, 0);

    var fds: [2]c_int = undefined;
    if (pipe(&fds) != 0) return error.Pipe;
    var fa: ?*anyopaque = null;
    _ = posix_spawn_file_actions_init(&fa);
    defer _ = posix_spawn_file_actions_destroy(&fa);
    _ = posix_spawn_file_actions_adddup2(&fa, fds[1], 1);
    _ = posix_spawn_file_actions_addclose(&fa, fds[0]);
    _ = posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);
    const envp = [_:null]?[*:0]const u8{ "LC_ALL=C", "GIT_OPTIONAL_LOCKS=0", "PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin" };
    var pid: c_int = 0;
    const rc = posix_spawn(&pid, cargv[0].?, @ptrCast(&fa), null, cargv.ptr, &envp);
    _ = close(fds[1]);
    if (rc != 0) {
        _ = close(fds[0]);
        return error.Spawn;
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = read(fds[0], &buf, buf.len);
        if (n <= 0) break;
        try out.appendSlice(gpa, buf[0..@intCast(n)]);
    }
    _ = close(fds[0]);
    var status: c_int = 0;
    _ = waitpid(pid, &status, 0);
    return .{ .out = try out.toOwnedSlice(gpa), .code = @truncate(@as(u32, @bitCast(status)) >> 8) };
}
