const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const procs = @import("procs.zig");
const cleaner = @import("cleaner.zig");
const table = @import("view_table.zig");
const view = @import("view.zig");
const card = @import("view_card.zig");
const App = @import("app.zig").App;

const child_rows = 8;
const map_rows = 13;
const map_dot = 5;
const map_gap = 3;
const max_cols = 400;

const w_size = 96;
const w_files = 90;
const w_modified = 120;

const theme = @import("theme.zig");
const hero_pad = 22;

const hues = [_]theme.Hue{ .violet, .sand, .lime, .yellow };

fn ink(c: *ui.Context, kind: cleaner.Kind) ui.Color {
    return theme.hue(c, hues[@intFromEnum(kind) % hues.len]);
}

fn tone(c: *ui.Context, kind: cleaner.Kind) ui.Color {
    const full = ink(c, kind);
    return if (@intFromEnum(kind) < hues.len) full else theme.of(c).win.mix(full, 0.5);
}

pub fn iconOf(kind: cleaner.Kind) []const u8 {
    return switch (kind) {
        .caches => "archivebox",
        .packages => "shippingbox",
        .developer => "hammer",
        .agents => "bubble.left.and.bubble.right",
        .installers => "arrow.down.circle",
        .logs => "doc.text",
        .temporary => "clock",
        .trash => "trash",
    };
}

const Hero = enum { idle, scanning, cleaning, found };

fn heroOf(cl: *const cleaner.Cleaner) Hero {
    return switch (cl.phase) {
        .scanning => .scanning,
        .cleaning => .cleaning,
        .idle => if (cl.scanned) .found else .idle,
    };
}

pub fn page(c: *ui.Context, a: *App) void {
    const cl = &a.cleaner;
    {
        const sub = switch (heroOf(cl)) {
            .scanning => "Scanning…",
            .cleaning => "Cleaning…",
            .found => c.print("{s} to clean · {s}", .{ view.size(c, cl.total()), view.ago(c, a.now(), cl.scanned_at) }),
            .idle => if (cl.cancelled) "Scan stopped" else "",
        };
        const h = view.header(c, "Cleanup", sub);
        defer h.end();
        if (kit.iconButton(c, "arrow.clockwise", .{ .size = .sm, .variant = .secondary, .pill = true, .tooltip = "Scan Again", .disabled = cl.phase != .idle }).clicked) cl.scan();
        card.pauseButton(c, a);
    }
    const body = ui.div(c).column().wFull().grow().scrollY().pb(20);
    defer body.end();
    {
        const pad = ui.div(c).column().wFull().px(20).pb(14);
        defer pad.end();
        hero(c, a);
    }
    if (cl.step()) |spec| status(c, spec.doing);
    categories(c, a);
}

fn hero(c: *ui.Context, a: *App) void {
    const th = c.theme;
    const cl = &a.cleaner;
    const state = heroOf(cl);
    const box = theme.surface(c, ui.div(c).column().wFull().p(hero_pad).gap(18), theme.radius.hero);
    defer box.end();
    {
        const r = ui.div(c).row().wFull().gap(16).itemsCenter();
        defer r.end();
        {
            const badge = ui.div(c).row().w(52).h(52).center().rounded(theme.radius.panel).bg(theme.of(c).accent_soft);
            defer badge.end();
            const spin: f32 = if (state == .scanning) @floatCast(1 + 0.08 * @sin(c.time * 5)) else 1;
            const s = ui.div(c).row().center().scale(spin);
            defer s.end();
            ui.icon(c, "sparkles", .{ .size = 24, .color = th.accent });
        }
        {
            ui.key(c, @tagName(state));
            const f = ui.motion.frame(c, .{ .initial = .{ .opacity = 0, .y = 6 }, .target = .{ .opacity = 1, .y = 0 }, .transition = .{ .tween = .{ .duration = 0.35 } } });
            const t = ui.div(c).column().gap(3).grow().w(0).clip().motion(f);
            defer t.end();
            const sy = a.sampler.system;
            const label = switch (state) {
                .idle => "Free space",
                .scanning => "Scanning…",
                .cleaning => "Cleaning…",
                .found => "Found to clean",
            };
            ui.text(c, label, .{ .size = 13, .color = th.muted });
            const target: f32 = @floatFromInt(switch (state) {
                .idle => sy.disk_free,
                .scanning, .cleaning => cl.found(),
                .found => cl.total(),
            });
            const shown = ui.motion.number(c, "hero-bytes", target, .{ .tween = .{ .duration = 0.6 } });
            const text = view.size(c, @intFromFloat(@max(0, shown)));
            const sp = std.mem.indexOfScalar(u8, text, ' ') orelse text.len;
            {
                const n = ui.div(c).row().gap(5).itemsEnd();
                defer n.end();
                ui.text(c, text[0..sp], .{ .size = 40, .weight = .bold });
                const u = ui.div(c).column().pb(6);
                defer u.end();
                ui.text(c, if (sp < text.len) text[sp + 1 ..] else "", .{ .size = 17, .weight = .semibold, .color = th.muted });
            }
            const sub = switch (state) {
                .idle => "Scan to see what can be cleaned.",
                .scanning => "Looking through caches, logs and temporary files…",
                .cleaning => "Moving what you chose to the Trash…",
                .found => c.print("{s} chosen · {d} {s}", .{ view.size(c, cl.selectedBytes()), cl.selectedItems(), if (cl.selectedItems() == 1) "item" else "items" }),
            };
            ui.text(c, sub, .{ .size = 12.5, .color = th.muted });
        }
        switch (state) {
            .idle => if (ui.button(c, "Scan", .{ .variant = .primary, .size = 14 }).clicked) cl.scan(),
            .scanning => if (ui.button(c, "Cancel", .{ .size = 13 }).clicked) cl.cancel(),
            .cleaning => kit.spinner(c, .{ .size = 18 }),
            .found => {
                const chosen = cl.selectedBytes();
                if (ui.button(c, c.print("Clean {s}", .{view.size(c, chosen)}), .{ .variant = .primary, .size = 14, .disabled = chosen == 0 }).clicked) a.confirm_clean = true;
            },
        }
    }
    diskMap(c, a);
}

const Slice = struct { color: ui.Color, bytes: u64 };

pub fn allocate(dots: []usize, bytes: []const u64, all: u64, cells: usize) void {
    var given: usize = 0;
    const last = bytes.len - 1;
    for (bytes[0..last], 0..) |n, i| {
        dots[i] = if (n == 0) 0 else @max(1, @as(usize, @intCast(@as(u128, n) * cells / @max(1, all))));
        dots[i] = @min(dots[i], cells -| given);
        given += dots[i];
    }
    dots[last] = cells -| given;
}

fn hash(x: u64) u64 {
    var z = x +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

fn diskMap(c: *ui.Context, a: *App) void {
    const th = c.theme;
    const cl = &a.cleaner;
    const sy = a.sampler.system;
    const n = cleaner.specs.len;
    const scanning = cl.phase == .scanning;
    var slices: [n + 2]Slice = undefined;
    var bytes: [n + 2]u64 = undefined;
    var found: u64 = 0;
    for (&cl.cats, 0..) |*cat, i| {
        const b = cat.bytes();
        const alpha: f32 = if (cat.selected or !cl.scanned) 1 else 0.38;
        slices[i] = .{ .color = tone(c, cat.spec.kind).alpha(alpha), .bytes = b };
        found += b;
    }
    if (scanning) if (cl.step()) |spec| {
        const live = cl.found() -| found;
        const k = @intFromEnum(spec.kind);
        slices[k].bytes += live;
        found += live;
    };
    const used = sy.disk_total -| sy.disk_free;
    slices[n] = .{ .color = theme.of(c).label_3, .bytes = used -| found };
    slices[n + 1] = .{ .color = theme.of(c).fill_2, .bytes = sy.disk_free };
    for (slices, 0..) |s, i| bytes[i] = s.bytes;

    ui.key(c, "disk-map");
    const grid = ui.div(c).row().wFull().justifyBetween();
    const width = if (grid.interaction().rect) |r| r.w else 900;
    const cols: usize = @min(max_cols, @as(usize, @intFromFloat(@max(16, @floor((width + map_gap) / (map_dot + map_gap))))));
    const cells = cols * map_rows;
    var dots: [n + 2]usize = undefined;
    allocate(&dots, &bytes, @max(1, sy.disk_total), cells);
    var found_dots: usize = 0;
    for (dots[0..n]) |d| found_dots += d;

    const beat = @floor(c.time * 7);
    const phase: f32 = @floatCast(c.time * 7 - beat);
    const step_color: ui.Color = if (cl.step()) |spec| tone(c, spec.kind) else th.accent;
    const sparkle_span = found_dots + dots[n];
    var slice: usize = 0;
    var left: usize = dots[0];
    var cell: usize = 0;
    for (0..cols) |col| {
        ui.key(c, c.print("mc{d}", .{col}));
        const column = ui.div(c).column().gap(map_gap);
        defer column.end();
        for (0..map_rows) |_| {
            while (left == 0 and slice + 1 < slices.len) {
                slice += 1;
                left = dots[slice];
            }
            left -|= 1;
            var color = slices[slice].color;
            if (scanning and sparkle_span > 0) {
                if (cell == found_dots) color = step_color.alpha(0.45 + 0.55 * phase);
                if (slice == n) for (0..7) |k| {
                    const pick = hash(@as(u64, @intFromFloat(beat)) * 31 + k) % sparkle_span;
                    if (pick == cell) color = step_color.alpha(0.25 + 0.75 * (1 - phase));
                };
            }
            card.dot(c, map_dot, color);
            cell += 1;
        }
    }
    grid.end();
    if (scanning) c.frameIn(1.0 / 14.0);
    const legend = ui.div(c).row().wFull().gap(16).clip();
    defer legend.end();
    for (&cl.cats) |*cat| {
        if (cl.scanned and cat.bytes() == 0) continue;
        legendItem(c, tone(c, cat.spec.kind), cat.spec.title, if (cat.measured or cat.bytes() > 0) cat.bytes() else null);
    }
    legendItem(c, theme.of(c).label_3, "Other files", null);
    legendItem(c, theme.of(c).fill_2, c.print("Free {s}", .{view.size(c, sy.disk_free)}), null);
}

fn legendItem(c: *ui.Context, color: ui.Color, title: []const u8, n: ?u64) void {
    ui.key(c, title);
    const d = ui.div(c).row().gap(6).itemsCenter();
    defer d.end();
    card.dot(c, 7, color);
    ui.text(c, title, .{ .size = 12, .color = c.theme.muted });
    if (n) |v| if (v > 0) ui.text(c, view.size(c, v), .{ .size = 12, .color = c.theme.muted });
}

fn status(c: *ui.Context, doing: []const u8) void {
    const th = c.theme;
    table.line(c);
    {
        const s = ui.div(c).row().wFull().h(34).px(20).gap(10).itemsCenter().bg(th.surface.alpha(0.6));
        defer s.end();
        kit.spinner(c, .{ .size = 14 });
        ui.key(c, doing);
        const f = ui.motion.frame(c, .{ .initial = .{ .opacity = 0, .x = -4 }, .target = .{ .opacity = 1, .x = 0 }, .transition = .{ .tween = .{ .duration = 0.25 } } });
        const t = ui.div(c).row().motion(f);
        defer t.end();
        ui.text(c, doing, .{ .size = 12.5, .color = th.muted });
    }
}

fn categories(c: *ui.Context, a: *App) void {
    const cl = &a.cleaner;
    table.line(c);
    {
        const head = ui.div(c).row().wFull().px(20).itemsCenter();
        defer head.end();
        _ = table.head(c, "Name", null, false, false, false);
        _ = table.head(c, "Size", w_size, true, cl.scanned, false);
        _ = table.head(c, "Files", w_files, true, false, false);
        _ = table.head(c, "Modified", w_modified, true, false, false);
    }
    table.line(c);
    var order: [cleaner.specs.len]usize = undefined;
    for (&order, 0..) |*o, i| o.* = i;
    if (cl.scanned) std.mem.sort(usize, &order, cl, struct {
        fn gt(x: *const cleaner.Cleaner, l: usize, r: usize) bool {
            return x.cats[l].bytes() > x.cats[r].bytes();
        }
    }.gt);
    const now = a.now();
    const list = ui.div(c).column().wFull().px(12).pt(4);
    defer list.end();
    for (order, 0..) |i, row| category(c, a, &cl.cats[i], i, row, now);
}

fn category(c: *ui.Context, a: *App, cat: *cleaner.Category, i: usize, row: usize, now: i64) void {
    const th = c.theme;
    const spec = cat.spec;
    const cl = &a.cleaner;
    const pending = cl.phase == .scanning and !cat.measured;
    const measuring = if (cl.step()) |s| s.kind == spec.kind else false;
    ui.key(c, spec.title);
    const box = ui.div(c).column().wFull().rounded(table.row_radius).bg(table.rowFill(c, false, row));
    defer box.end();
    const size = cat.bytes();
    {
        const ready = !pending and size > 0;
        const opens = ready and cat.items().len > 0;
        var r = ui.div(c).row().wFull().h(31).px(8).gap(8).itemsCenter().rounded(table.row_radius);
        if (opens) r = r.control().hover(theme.of(c).fill);
        defer r.end();
        var toggled = opens and r.interaction().clicked;
        if (table.chevron(c, a.expanded[i], opens)) toggled = true;
        if (ready) {
            if (table.check(c, cat.selected, true)) {
                cat.selected = !cat.selected;
                toggled = false;
                c.changed = true;
            }
        } else _ = c.leaf(.{ .width = .{ .px = 16 } }, .none, null);
        if (toggled) {
            a.expanded[i] = !a.expanded[i];
            c.changed = true;
        }
        {
            const color = ink(c, spec.kind);
            const badge = ui.div(c).row().w(18).h(18).center().rounded(theme.radius.chip).bg(color.alpha(0.16));
            defer badge.end();
            ui.icon(c, iconOf(spec.kind), .{ .size = 10, .color = color });
        }
        {
            const t = ui.div(c).row().gap(7).grow().w(0).itemsCenter().clip();
            defer t.end();
            ui.text(c, spec.title, .{ .size = 13, .weight = .semibold });
            ui.text(c, spec.desc, .{ .size = 12, .color = th.muted });
        }
        if (cat.found.denied and size == 0 and !pending) {
            if (ui.button(c, "Allow Full Disk Access", .{ .size = 11.5, .icon = "lock.shield" }).clicked) a.requestAccess();
        } else if (measuring) {
            const s = table.cell(c, w_size + w_files + w_modified, true);
            defer s.end();
            kit.skeleton(c, .{ .width = .{ .px = 64 }, .height = 11 });
        } else {
            const has = size > 0;
            table.value(c, if (has) view.size(c, size) else "–", w_size, if (has) null else th.muted);
            table.value(c, if (has) c.print("{d}", .{cat.files()}) else "–", w_files, th.muted);
            table.value(c, if (has) view.ago(c, now, cat.newest()) else "–", w_modified, th.muted);
        }
    }
    if (cat.selected and size > 0 and spec.note.len > 0 and !pending) {
        const danger = cl.selectedForever() and (spec.forever or spec.kind == .developer);
        const n = ui.div(c).row().wFull().pl(84).pr(12).pb(8).gap(6).itemsCenter();
        defer n.end();
        ui.icon(c, if (danger) "exclamationmark.triangle.fill" else "info.circle", .{ .size = 11, .color = if (danger) th.danger else th.muted });
        ui.text(c, spec.note, .{ .size = 11.5, .color = if (danger) th.danger else th.muted });
    }
    if (a.expanded[i] and !pending) children(c, cat, now);
}

fn children(c: *ui.Context, cat: *const cleaner.Category, now: i64) void {
    const th = c.theme;
    const items = cat.items();
    const shown: usize = @min(items.len, child_rows);
    for (items[0..shown], 0..) |it, n| {
        ui.key(c, c.print("item-{d}", .{n}));
        const r = ui.div(c).row().wFull().h(table.row_h).pl(84).pr(8).itemsCenter();
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
    }
    if (items.len > child_rows) {
        var rest: u64 = 0;
        for (items[child_rows..]) |it| rest += it.size.bytes;
        const r = ui.div(c).row().wFull().h(table.row_h).pl(90).itemsCenter();
        defer r.end();
        ui.text(c, c.print("and {d} more · {s}", .{ items.len - child_rows, view.size(c, rest) }), .{ .size = 11.5, .color = th.muted });
    }
}

pub fn dialog(c: *ui.Context, a: *App) void {
    var b: [32]u8 = undefined;
    const cl = &a.cleaner;
    const forever = cl.selectedForever();
    const desc = if (forever)
        "Caches, logs and other files move to the Trash. Git removes clean worktrees with their ignored files, and what is already in the Trash is deleted for good."
    else
        "The files move to the Trash. Apps make their caches again as they need them.";
    if (kit.dialog(c, "clean", &a.confirm_clean, .{ .title = c.print("Clean {s}?", .{procs.bytes(&b, cl.selectedBytes())}), .description = desc, .ok = "Clean", .ok_variant = if (forever) .danger else .primary })) |d| {
        if (d.end() == .ok) cl.clean();
    }
}
