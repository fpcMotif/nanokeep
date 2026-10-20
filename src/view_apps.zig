const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const apps = @import("apps.zig");
const table = @import("view_table.zig");
const view = @import("view.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;

const Col = struct { title: []const u8, sort: app_mod.AppSort, w: ?f32, right: bool };

const cols = [_]Col{
    .{ .title = "Name", .sort = .name, .w = null, .right = false },
    .{ .title = "Version", .sort = .version, .w = 110, .right = false },
    .{ .title = "Size", .sort = .size, .w = 84, .right = true },
    .{ .title = "Kind", .sort = .kind, .w = 110, .right = false },
    .{ .title = "Last Opened", .sort = .opened, .w = 116, .right = false },
    .{ .title = "Source", .sort = .source, .w = 84, .right = false },
};

pub fn page(c: *ui.Context, a: *App) void {
    const th = c.theme;
    const inv = &a.inventory;
    if (!inv.loaded) {
        inv.load();
        a.orderApps();
    }
    {
        const sub = if (inv.measuring != null)
            c.print("{d} apps · measuring sizes…", .{inv.apps.items.len})
        else
            c.print("{d} apps · {s}", .{ inv.apps.items.len, view.size(c, inv.total()) });
        const h = view.header(c, "Apps", sub);
        defer h.end();
        if (ui.textField(c, &a.app_query, .{ .placeholder = "Search", .width = .{ .px = 160 }, .size = 12 }).changed) a.orderApps();
        if (ui.button(c, "Reload", .{ .size = 12, .icon = "arrow.clockwise", .disabled = inv.measuring != null }).clicked) {
            a.app_selected = null;
            inv.load();
            a.orderApps();
        }
        const chosen = a.selectedApp();
        if (ui.button(c, "Uninstall", .{ .variant = .danger, .size = 12, .disabled = chosen == null }).clicked) a.confirm_uninstall = true;
    }
    {
        const head = ui.div(c).row().wFull().px(14).itemsCenter();
        defer head.end();
        _ = c.leaf(.{ .width = .{ .px = 24 } }, .none, null);
        for (cols) |col| if (table.head(c, col.title, col.w, col.right, a.app_sort == col.sort, a.app_reversed)) a.sortAppsBy(col.sort);
    }
    table.line(c);
    const now = a.now();
    var rows = ui.list(c, .{ .count = a.app_rows.items.len, .row_height = table.row_h, .padding = .{ .left = 8, .right = 8 } });
    while (rows.next()) |i| row(c, a, a.app_rows.items[i], i, now);
    rows.end();
    _ = th;
}

fn row(c: *ui.Context, a: *App, index: u32, i: usize, now: i64) void {
    const th = c.theme;
    const info = &a.inventory.apps.items[index];
    ui.key(c, info.path);
    const sel = a.app_selected == index;
    const bg = if (sel) th.accent.alpha(0.2) else if (i % 2 == 1) th.surface_hover.alpha(0.45) else th.background.alpha(0);
    const d = ui.div(c).row().wFull().h(table.row_h).px(6).itemsCenter().rounded(6).bg(bg).control();
    defer d.end();
    if (d.clicked()) {
        a.app_selected = if (sel) null else index;
        c.changed = true;
    }
    const open = a.appRunning(info);
    {
        const s = ui.div(c).row().w(18).h(18).center();
        defer s.end();
        if (open) table.dot(c, 6, .hex(0x30d158));
    }
    {
        const n = table.cell(c, null, false);
        defer n.end();
        ui.text(c, info.name, .{ .size = 12.5 });
    }
    text(c, if (info.version.len > 0) info.version else "–", cols[1].w, th.muted);
    table.value(c, if (info.measured) view.size(c, info.size.bytes) else "…", cols[2].w, null);
    text(c, info.kind.title(), cols[3].w, if (info.kind == .intel) ui.Color.hex(0xff9f0a) else th.muted);
    text(c, view.ago(c, now, info.last_opened), cols[4].w, th.muted);
    text(c, if (info.app_store) "App Store" else "Other", cols[5].w, th.muted);
}

fn text(c: *ui.Context, s: []const u8, w: ?f32, color: ui.Color) void {
    const d = table.cell(c, w, false);
    defer d.end();
    ui.text(c, s, .{ .size = 12, .color = color });
}

pub fn dialog(c: *ui.Context, a: *App) void {
    const info = a.selectedApp() orelse {
        a.confirm_uninstall = false;
        return;
    };
    const open = a.appRunning(info);
    const desc = if (open) "It is open now. Quit it first." else "Its settings and data stay. You can put it back from the Trash.";
    if (kit.dialog(c, "uninstall", &a.confirm_uninstall, .{ .title = c.print("Move {s} to the Trash?", .{info.name}), .description = desc, .ok = "Move to Trash", .ok_variant = .danger })) |d| {
        if (d.end() == .ok) a.uninstallSelected();
    }
}
