const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Color = ui.Color;

pub const Hue = enum { violet, sand, lime, yellow, red, neutral };

pub const Palette = struct {
    win: Color,
    win_2: Color,
    label: Color,
    label_2: Color,
    label_3: Color,
    sep: Color,
    fill: Color,
    fill_2: Color,
    alt: Color,
    hover: Color,
    accent: Color,
    accent_hover: Color,
    accent_soft: Color,
    on_accent: Color,
    sand: Color,
    lime: Color,
    red: Color,
    yellow: Color,
    glass_tint: Color,
};

fn ink(a: f32) Color {
    return .{ .a = a };
}

fn paper(a: f32) Color {
    return .{ .r = 1, .g = 1, .b = 1, .a = a };
}

pub const light: Palette = .{
    .win = .hex(0xffffff),
    .win_2 = .hex(0xf6f5f8),
    .label = ink(0.86),
    .label_2 = ink(0.52),
    .label_3 = ink(0.28),
    .sep = ink(0.09),
    .fill = ink(0.05),
    .fill_2 = ink(0.08),
    .alt = ink(0.022),
    .hover = .hex(0xe2e1e4),
    .accent = .hex(0x9536d6),
    .accent_hover = .hex(0x8530c0),
    .accent_soft = Color.hex(0x9536d6).alpha(0.12),
    .on_accent = .white,
    .sand = .hex(0xc9853a),
    .lime = .hex(0x5e9a2c),
    .red = .hex(0xff3b30),
    .yellow = .hex(0xf5a623),
    .glass_tint = Color.hex(0x9536d6).alpha(0.04),
};

pub const dark: Palette = .{
    .win = .hex(0x1e1c21),
    .win_2 = .hex(0x252229),
    .label = paper(0.88),
    .label_2 = paper(0.55),
    .label_3 = paper(0.26),
    .sep = paper(0.09),
    .fill = paper(0.06),
    .fill_2 = paper(0.1),
    .alt = paper(0.025),
    .hover = .hex(0x3b383e),
    .accent = .hex(0xb66bf0),
    .accent_hover = .hex(0xc384f3),
    .accent_soft = Color.hex(0xb66bf0).alpha(0.18),
    .on_accent = .hex(0x1a0b26),
    .sand = .hex(0xeabd86),
    .lime = .hex(0xabd86f),
    .red = .hex(0xff453a),
    .yellow = .hex(0xffd60a),
    .glass_tint = Color.hex(0xb66bf0).alpha(0.06),
};

pub fn of(c: *ui.Context) Palette {
    return if (c.theme.dark) dark else light;
}

pub fn apply(c: *ui.Context) void {
    const p = of(c);
    c.theme.background = p.win_2;
    c.theme.surface = p.win;
    c.theme.surface_hover = p.hover;
    c.theme.text = p.label;
    c.theme.muted = p.label_2;
    c.theme.border = p.sep;
    c.theme.accent = p.accent;
    c.theme.accent_hover = p.accent_hover;
    c.theme.accent_text = p.on_accent;
    c.theme.track = p.fill_2;
    c.theme.danger = p.red;
    c.theme.success = p.lime;
}

pub fn hue(c: *ui.Context, h: Hue) Color {
    const p = of(c);
    return switch (h) {
        .violet => p.accent,
        .sand => p.sand,
        .lime => p.lime,
        .yellow => p.yellow,
        .red => p.red,
        .neutral => p.label_3,
    };
}

pub const radius = struct {
    pub const hero = 22;
    pub const card = 18;
    pub const window = 16;
    pub const panel = 12;
    pub const control = 8;
    pub const row = 6;
    pub const chip = 4;
};

pub const space = struct {
    pub const hair = 2;
    pub const xs = 4;
    pub const sm = 6;
    pub const md = 8;
    pub const lg = 10;
    pub const xl = 12;
    pub const gutter = 14;
    pub const card = 16;
    pub const page = 20;
};

pub fn inner(outer: f32, pad: f32) f32 {
    return @max(outer - pad, radius.chip);
}

pub fn surface(c: *ui.Context, d: ui.Div, r: f32) ui.Div {
    const p = of(c);
    const edged = d.rounded(r).bg(p.win).border(p.sep);
    if (c.theme.dark) return edged;
    return edged.borderW(0.5).shadow(.{ .color = .{ .a = 0.04 }, .blur = 2, .y = 1 });
}
