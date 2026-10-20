const std = @import("std");
const run = @import("run.zig");

extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn opendir(path: [*:0]const u8) ?*anyopaque;
extern "c" fn readdir(dir: *anyopaque) ?*const Dirent;
extern "c" fn closedir(dir: *anyopaque) c_int;

const Dirent = extern struct { ino: u64, seekoff: u64, reclen: u16, namlen: u16, kind: u8, name: [1024]u8 };
const DT_DIR = 4;

pub const git = "/usr/bin/git";

pub const roots = [_][]const u8{ "devv", "Developer", "Projects", "projects", "code", "Code", "src", "work", "repos", "git", "GitHub", "github", "Documents/GitHub", ".codex/worktrees", ".claude/worktrees" };

const skipped = [_][]const u8{ "node_modules", "target", "zig-out", "build", "dist", "vendor", "DerivedData", "Library", "Pods" };

pub const Entry = struct {
    path: []const u8,
    locked: bool = false,
    prunable: bool = false,
    bare: bool = false,
};

pub const Found = struct {
    path: [:0]u8,
    repo: [:0]u8,
};

pub fn parseList(gpa: std.mem.Allocator, text: []const u8) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "worktree ")) {
            try out.append(gpa, .{ .path = line["worktree ".len..] });
            continue;
        }
        if (out.items.len == 0) continue;
        const last = &out.items[out.items.len - 1];
        if (std.mem.eql(u8, line, "bare")) last.bare = true;
        if (std.mem.startsWith(u8, line, "locked")) last.locked = true;
        if (std.mem.startsWith(u8, line, "prunable")) last.prunable = true;
    }
    return out.toOwnedSlice(gpa);
}

pub fn candidates(gpa: std.mem.Allocator, home: []const u8) !std.ArrayList([:0]u8) {
    var out: std.ArrayList([:0]u8) = .empty;
    errdefer {
        for (out.items) |p| gpa.free(p);
        out.deinit(gpa);
    }
    for (roots) |root| {
        const dir = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ home, root }, 0);
        defer gpa.free(dir);
        try collect(gpa, &out, dir, 2);
    }
    return out;
}

fn isRepo(gpa: std.mem.Allocator, dir: []const u8) bool {
    const dot = std.fmt.allocPrintSentinel(gpa, "{s}/.git", .{dir}, 0) catch return false;
    defer gpa.free(dot);
    return access(dot, 0) == 0;
}

fn collect(gpa: std.mem.Allocator, out: *std.ArrayList([:0]u8), dir: [:0]const u8, depth: u8) !void {
    if (isRepo(gpa, dir)) try out.append(gpa, try gpa.dupeSentinel(u8, dir, 0));
    if (depth == 0) return;
    const d = opendir(dir) orelse return;
    defer _ = closedir(d);
    while (readdir(d)) |ent| {
        if (ent.kind != DT_DIR) continue;
        const name = ent.name[0..ent.namlen];
        if (name.len == 0 or name[0] == '.') continue;
        if (isSkipped(name)) continue;
        const child = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ dir, name }, 0);
        defer gpa.free(child);
        try collect(gpa, out, child, depth - 1);
    }
}

fn isSkipped(name: []const u8) bool {
    for (skipped) |s| if (std.mem.eql(u8, s, name)) return true;
    return std.mem.endsWith(u8, name, "-cache") or std.mem.eql(u8, name, ".zig-cache");
}

pub fn isClean(gpa: std.mem.Allocator, path: []const u8) bool {
    const st = run.capture(gpa, &.{ git, "-C", path, "status", "--porcelain" }) catch return false;
    defer st.deinit(gpa);
    return st.code == 0 and std.mem.trim(u8, st.out, " \n").len == 0;
}

pub fn find(gpa: std.mem.Allocator, home: []const u8) !std.ArrayList(Found) {
    var dirs = try candidates(gpa, home);
    defer {
        for (dirs.items) |p| gpa.free(p);
        dirs.deinit(gpa);
    }
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        seen.deinit(gpa);
    }
    var out: std.ArrayList(Found) = .empty;
    errdefer {
        for (out.items) |f| {
            gpa.free(f.path);
            gpa.free(f.repo);
        }
        out.deinit(gpa);
    }
    for (dirs.items) |dir| {
        const listed = run.capture(gpa, &.{ git, "-C", dir, "worktree", "list", "--porcelain" }) catch continue;
        defer listed.deinit(gpa);
        if (listed.code != 0) continue;
        const entries = parseList(gpa, listed.out) catch continue;
        defer gpa.free(entries);
        if (entries.len < 2) continue;
        const main = entries[0].path;
        if (seen.contains(main)) continue;
        try seen.put(gpa, try gpa.dupe(u8, main), {});
        for (entries[1..]) |e| {
            if (e.locked or e.prunable or e.bare) continue;
            const path = try gpa.dupeSentinel(u8, e.path, 0);
            if (access(path, 0) != 0 or !isClean(gpa, path)) {
                gpa.free(path);
                continue;
            }
            const repo = try gpa.dupeSentinel(u8, main, 0);
            try out.append(gpa, .{ .path = path, .repo = repo });
        }
    }
    return out;
}

pub fn remove(gpa: std.mem.Allocator, repo: []const u8, path: []const u8) bool {
    const r = run.capture(gpa, &.{ git, "-C", repo, "worktree", "remove", path }) catch return false;
    defer r.deinit(gpa);
    return r.code == 0;
}
