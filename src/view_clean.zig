const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const procs = @import("procs.zig");
const cleaner = @import("cleaner.zig");
const table = @import("view_table.zig");
const view = @import("view.zig");
const App = @import("app.zig").App;

const child_rows = 8;
const map_cols = 64;
const map_rows = 12;
const full_disk_access = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles";

const w_size = 90;
const w_files = 90;
const w_modified = 120;

pub fn page(c: *ui.Context, a: *App) void {
    const cl = &a.cleaner;
    if (!cl.scanned and cl.phase == .idle) cl.scan();
    var b: [2][32]u8 = undefined;
    {
        const sub = switch (cl.phase) {
            .scanning => "Looking through caches, logs, worktrees and temporary files…",
            .cleaning => "Cleaning…",
            .idle => if (cl.scanned) c.print("{s} found · measured in {d} ms", .{ procs.bytes(&b[0], cl.total()), cl.scan_ms }) else "",
        };
        const h = view.header(c, "Cleanup", sub);
        defer h.end();
        if (cl.phase != .idle) kit.spinner(c, .{});
        if (ui.button(c, "Rescan", .{ .size = 12, .icon = "arrow.clockwise", .disabled = cl.phase != .idle }).clicked) cl.scan();
        const chosen = cl.selectedBytes();
        if (ui.button(c, c.print("Clean {s}", .{procs.bytes(&b[1], chosen)}), .{ .variant = .primary, .size = 12, .disabled = chosen == 0 or cl.phase != .idle }).clicked) a.confirm_clean = true;
    }
    const body = ui.div(c).column().wFull().grow().scrollY().px(20).pb(20).gap(14);
    defer body.end();
    diskMap(c, a);
    categories(c, a);
}

const Slice = struct { color: ui.Color, bytes: u64 };

fn diskMap(c: *ui.Context, a: *App) void {
    const th = c.theme;
    const cl = &a.cleaner;
    const sy = a.sampler.system;
    const card = ui.div(c).column().wFull().p(16).gap(12).rounded(12).bg(th.surface).border(th.border);
    defer card.end();
    var slices: [cleaner.specs.len + 2]Slice = undefined;
    for (&cl.cats, 0..) |*cat, i| slices[i] = .{ .color = .hex(cat.spec.color), .bytes = cat.bytes() };
    const found = cl.total();
    const used = sy.disk_total -| sy.disk_free;
    slices[cleaner.specs.len] = .{ .color = th.muted.alpha(0.55), .bytes = used -| found };
    slices[cleaner.specs.len + 1] = .{ .color = th.surface_hover, .bytes = sy.disk_free };
    var dots: [cleaner.specs.len + 2]usize = @splat(0);
    const all = @max(1, sy.disk_total);
    const cells = map_cols * map_rows;
    var given: usize = 0;
    for (slices[0..cleaner.specs.len], 0..) |s, i| if (s.bytes > 0) {
        dots[i] = @max(1, @as(usize, @intCast(s.bytes * cells / all)));
        given += dots[i];
    };
    dots[cleaner.specs.len] = @min(cells -| given, @as(usize, @intCast(slices[cleaner.specs.len].bytes * cells / all)));
    given += dots[cleaner.specs.len];
    dots[cleaner.specs.len + 1] = cells -| given;
    {
        const grid = ui.div(c).column().wFull().gap(4);
        defer grid.end();
        var slice: usize = 0;
        var left: usize = dots[0];
        for (0..map_rows) |r| {
            ui.key(c, c.print("map-{d}", .{r}));
            const row = ui.div(c).row().wFull().gap(4).justifyBetween();
            defer row.end();
            for (0..map_cols) |_| {
                while (left == 0 and slice + 1 < slices.len) {
                    slice += 1;
                    left = dots[slice];
                }
                left -|= 1;
                table.dot(c, 7, slices[slice].color);
            }
        }
    }
    const legend = ui.div(c).row().wFull().gap(16).clip();
    defer legend.end();
    for (&cl.cats) |*cat| if (cat.bytes() > 0) legendItem(c, .hex(cat.spec.color), cat.spec.title, cat.bytes());
    legendItem(c, slices[cleaner.specs.len].color, "Other files", slices[cleaner.specs.len].bytes);
    legendItem(c, th.border, "Free", sy.disk_free);
}

fn legendItem(c: *ui.Context, color: ui.Color, title: []const u8, n: u64) void {
    ui.key(c, title);
    const d = ui.div(c).row().gap(6).itemsCenter();
    defer d.end();
    table.dot(c, 8, color);
    ui.text(c, title, .{ .size = 11.5 });
    ui.text(c, view.size(c, n), .{ .size = 11.5, .mono = true, .color = c.theme.muted });
}

fn categories(c: *ui.Context, a: *App) void {
    const th = c.theme;
    const cl = &a.cleaner;
    const card = ui.div(c).column().wFull().py(6).rounded(12).bg(th.surface).border(th.border).clip();
    defer card.end();
    {
        const head = ui.div(c).row().wFull().px(12).itemsCenter();
        defer head.end();
        _ = c.leaf(.{ .width = .{ .px = 46 } }, .none, null);
        _ = table.head(c, "Name", null, false, false, false);
        _ = table.head(c, "Size", w_size, true, false, false);
        _ = table.head(c, "Files", w_files, true, false, false);
        _ = table.head(c, "Modified", w_modified, true, false, false);
        _ = c.leaf(.{ .width = .{ .px = 24 } }, .none, null);
    }
    table.line(c);
    const now = a.now();
    for (&cl.cats, 0..) |*cat, i| category(c, a, cat, i, now);
}

fn category(c: *ui.Context, a: *App, cat: *cleaner.Category, i: usize, now: i64) void {
    const th = c.theme;
    const spec = cat.spec;
    const scanning = a.cleaner.phase == .scanning;
    ui.key(c, spec.title);
    const box = ui.div(c).column().wFull();
    defer box.end();
    const size = cat.bytes();
    {
        const r = ui.div(c).row().wFull().h(50).px(12).gap(8).itemsCenter();
        defer r.end();
        if (table.check(c, cat.selected and size > 0, size > 0)) {
            cat.selected = !cat.selected;
            c.changed = true;
        }
        table.dot(c, 10, .hex(spec.color));
        {
            const t = ui.div(c).column().gap(2).grow().w(0).px(6).clip();
            defer t.end();
            ui.text(c, spec.title, .{ .size = 13, .weight = .semibold });
            ui.text(c, spec.desc, .{ .size = 11.5, .color = th.muted });
        }
        if (cat.found.denied and size == 0) {
            if (ui.button(c, "Allow Full Disk Access", .{ .size = 11.5, .icon = "lock.shield" }).clicked) _ = nanoui.shell.openUrl(full_disk_access);
        } else if (scanning) {
            const s = table.cell(c, w_size + w_files + w_modified, true);
            defer s.end();
            kit.skeleton(c, .{ .width = .{ .px = 64 }, .height = 12 });
        } else {
            table.value(c, view.size(c, size), w_size, if (size == 0) th.muted else null);
            table.value(c, if (size > 0) c.print("{d}", .{cat.files()}) else "–", w_files, th.muted);
            table.value(c, if (size > 0) view.ago(c, now, cat.newest()) else "–", w_modified, th.muted);
        }
        if (table.chevron(c, a.expanded[i], cat.items().len > 0 and !scanning)) {
            a.expanded[i] = !a.expanded[i];
            c.changed = true;
        }
    }
    if (cat.selected and size > 0 and spec.note.len > 0) {
        const danger = a.cleaner.selectedForever() and (spec.forever or spec.kind == .developer);
        const n = ui.div(c).row().wFull().pl(62).pr(12).pb(8).gap(6).itemsCenter();
        defer n.end();
        ui.icon(c, if (danger) "exclamationmark.triangle.fill" else "info.circle", .{ .size = 11, .color = if (danger) th.danger else th.muted });
        ui.text(c, spec.note, .{ .size = 11.5, .color = if (danger) th.danger else th.muted });
    }
    if (a.expanded[i] and !scanning) children(c, cat, now);
    table.line(c);
}

fn children(c: *ui.Context, cat: *const cleaner.Category, now: i64) void {
    const th = c.theme;
    const items = cat.items();
    const shown = @min(items.len, child_rows);
    for (items[0..shown], 0..) |it, n| {
        ui.key(c, c.print("item-{d}", .{n}));
        const r = ui.div(c).row().wFull().h(table.row_h).pl(62).pr(12).itemsCenter();
        defer r.end();
        {
            const name = table.cell(c, null, false).gap(6);
            defer name.end();
            if (it.repo != null) ui.icon(c, "arrow.triangle.branch", .{ .size = 10, .color = th.muted });
            ui.text(c, std.fs.path.basename(it.path), .{ .size = 12 });
            if (it.repo) |repo| ui.text(c, std.fs.path.basename(repo), .{ .size = 11, .color = th.muted });
        }
        table.value(c, view.size(c, it.size.bytes), w_size, null);
        table.value(c, c.print("{d}", .{it.size.files}), w_files, th.muted);
        table.value(c, view.ago(c, now, it.size.newest), w_modified, th.muted);
        _ = c.leaf(.{ .width = .{ .px = 18 } }, .none, null);
    }
    if (items.len > child_rows) {
        var rest: u64 = 0;
        for (items[child_rows..]) |it| rest += it.size.bytes;
        const r = ui.div(c).row().wFull().h(table.row_h).pl(68).itemsCenter();
        defer r.end();
        ui.text(c, c.print("and {d} more · {s}", .{ items.len - child_rows, view.size(c, rest) }), .{ .size = 11.5, .color = th.muted });
    }
}

pub fn dialog(c: *ui.Context, a: *App) void {
    var b: [32]u8 = undefined;
    const cl = &a.cleaner;
    const forever = cl.selectedForever();
    const desc = if (forever)
        "Caches, logs and other files move to the Trash. Git removes clean worktrees, and what is already in the Trash is deleted for good."
    else
        "The files move to the Trash. Apps make their caches again as they need them.";
    if (kit.dialog(c, "clean", &a.confirm_clean, .{ .title = c.print("Clean {s}?", .{procs.bytes(&b, cl.selectedBytes())}), .description = desc, .ok = "Clean", .ok_variant = if (forever) .danger else .primary })) |d| {
        if (d.end() == .ok) cl.clean();
    }
}
