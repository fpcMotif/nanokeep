const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;

pub const row_h = 26;

pub fn cell(c: *ui.Context, w: ?f32, right: bool) ui.Div {
    var d = ui.div(c).row().h(row_h).itemsCenter().px(6).clip();
    d = if (w) |px| d.w(px) else d.grow().w(0);
    if (right) d = d.justifyEnd();
    return d;
}

pub fn head(c: *ui.Context, title: []const u8, w: ?f32, right: bool, active: bool, reversed: bool) bool {
    const th = c.theme;
    ui.key(c, title);
    var d = cell(c, w, right).gap(3).rounded(5).control();
    d = d.hover(th.surface_hover);
    defer d.end();
    const clicked = d.clicked();
    ui.text(c, title, .{ .size = 11.5, .weight = if (active) .semibold else .regular, .color = if (active) th.text else th.muted });
    if (active) ui.icon(c, if (reversed) "chevron.up" else "chevron.down", .{ .size = 8, .weight = .bold, .color = th.muted });
    return clicked;
}

pub fn value(c: *ui.Context, s: []const u8, w: ?f32, color: ?ui.Color) void {
    const d = cell(c, w, true);
    defer d.end();
    ui.text(c, s, .{ .size = 12, .mono = true, .color = color orelse c.theme.text });
}

pub fn chevron(c: *ui.Context, open: bool, visible: bool) bool {
    const th = c.theme;
    ui.key(c, "chevron");
    var d = ui.div(c).row().w(18).h(18).center().rounded(4);
    if (visible) d = d.hover(th.surface_hover).control();
    defer d.end();
    if (!visible) return false;
    const clicked = d.clicked();
    ui.icon(c, if (open) "chevron.down" else "chevron.right", .{ .size = 9, .weight = .bold, .color = th.muted });
    return clicked;
}

pub fn check(c: *ui.Context, on: bool, enabled: bool) bool {
    const th = c.theme;
    ui.key(c, "check");
    var d = ui.div(c).row().w(16).h(16).center().rounded(4).border(if (on) th.accent else th.border).bg(if (on) th.accent else th.background.alpha(0)).control();
    if (!enabled) d = d.opacity(0.4);
    defer d.end();
    const clicked = d.clicked() and enabled;
    if (on) ui.icon(c, "checkmark", .{ .size = 8.5, .weight = .bold, .color = th.accent_text });
    return clicked;
}

pub fn dot(c: *ui.Context, size: f32, color: ui.Color) void {
    _ = c.leaf(.{ .width = .{ .px = size }, .height = .{ .px = size }, .radius = size / 2, .background = color }, .none, null);
}

pub fn line(c: *ui.Context) void {
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = c.theme.border }, .none, null);
}
