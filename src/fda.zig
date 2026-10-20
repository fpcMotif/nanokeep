const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const Object = objc.Object;
const SEL = objc.SEL;
const CGRect = objc.CGRect;
const CGPoint = objc.CGPoint;

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn CGWindowListCopyWindowInfo(option: u32, relative: u32) ?Object;
extern "c" fn CGRectMakeWithDictionaryRepresentation(dict: Object, rect: *CGRect) bool;
extern "c" fn CFRelease(obj: Object) void;

const settings_urls = [_][]const u8{
    "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
    "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
};
const settings_owners = [_][]const u8{ "System Settings", "System Preferences" };

const panel_w = 380;
const panel_h = 110;
const borderless_nonactivating = 1 << 7;
const floating_level = 3;
const drag_copy_link_generic = 1 | 2 | 4;

/// macOS guards the TCC database with Full Disk Access: reading it is the grant check.
pub fn granted(home: []const u8) bool {
    var buf: [1024]u8 = undefined;
    const p = std.fmt.bufPrintSentinel(&buf, "{s}/Library/Application Support/com.apple.TCC/TCC.db", .{home}, 0) catch return false;
    const fd = open(p, 0);
    if (fd < 0) return false;
    _ = close(fd);
    return true;
}

pub const Notify = struct { ctx: *anyopaque, func: *const fn (*anyopaque) void };

pub const Phase = enum { idle, guiding, granted };

pub const Guide = struct {
    home: []const u8,
    on_granted: Notify,
    phase: Phase = .idle,
    item: [:0]const u8 = "",
    panel: ?Object = null,
    controller: ?Object = null,
    timer: ?Object = null,
    title: ?Object = null,
    arrow: ?Object = null,
    card: ?Object = null,
    footer: ?Object = null,
    item_buf: [1024]u8 = undefined,

    pub fn begin(g: *Guide) void {
        if (granted(g.home)) return g.grant();
        if (g.phase == .guiding) {
            if (g.panel) |p| objc.msg(void, p, "orderFrontRegardless", .{});
            return;
        }
        g.phase = .guiding;
        for (settings_urls) |u| if (nanoui.shell.openUrl(u)) break;
        g.build();
        g.place();
        objc.msg(void, g.panel.?, "orderFrontRegardless", .{});
        g.timer = objc.retain(objc.msg(Object, objc.class("NSTimer"), "scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:", .{
            @as(f64, 0.5), g.controller.?, objc.sel("poll:"), @as(?Object, null), objc.YES,
        }));
    }

    pub fn poll(g: *Guide) void {
        if (g.phase != .guiding) return;
        if (granted(g.home)) return g.grant();
        g.place();
    }

    fn grant(g: *Guide) void {
        g.stopTimer();
        const was_guiding = g.phase == .guiding;
        g.phase = .granted;
        g.on_granted.func(g.on_granted.ctx);
        if (!was_guiding) return;
        objc.msg(void, g.title.?, "setStringValue:", .{objc.nsString("Full Disk Access granted")});
        objc.msg(void, g.arrow.?, "setImage:", .{symbol("checkmark.circle.fill")});
        objc.msg(void, g.arrow.?, "setContentTintColor:", .{objc.msg(Object, objc.class("NSColor"), "systemGreenColor", .{})});
        objc.msg(void, g.card.?, "setHidden:", .{objc.YES});
        objc.msg(void, g.footer.?, "setStringValue:", .{objc.nsString("nanokeep can now clean Installers and the Trash.")});
        objc.dispatchAfter(1500 * std.time.ns_per_ms, g, closeLater);
    }

    fn closeLater(ctx: ?*anyopaque) callconv(.c) void {
        const g: *Guide = @ptrCast(@alignCast(ctx));
        g.dismiss();
    }

    pub fn dismiss(g: *Guide) void {
        g.stopTimer();
        if (g.phase == .guiding) g.phase = .idle;
        const p = g.panel orelse return;
        objc.msg(void, p, "orderOut:", .{@as(?Object, null)});
        objc.release(p);
        if (g.controller) |c| objc.release(c);
        g.panel = null;
        g.controller = null;
    }

    pub fn deinit(g: *Guide) void {
        g.dismiss();
    }

    fn stopTimer(g: *Guide) void {
        const t = g.timer orelse return;
        objc.msg(void, t, "invalidate", .{});
        objc.release(t);
        g.timer = null;
    }

    /// The path a user drags into the list: the app bundle, or the bare executable when unbundled.
    pub fn dragPath(g: *Guide) [:0]const u8 {
        const bundle = objc.msg(Object, objc.class("NSBundle"), "mainBundle", .{});
        const path = objc.fromNSString(objc.msg(?Object, bundle, "bundlePath", .{}));
        const chosen = if (std.mem.endsWith(u8, path, ".app")) path else objc.fromNSString(objc.msg(?Object, bundle, "executablePath", .{}));
        g.item = std.fmt.bufPrintSentinel(&g.item_buf, "{s}", .{chosen}, 0) catch "";
        return g.item;
    }

    pub fn build(g: *Guide) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const path = g.dragPath();
        const panel_class = objc.defineClass(.{ .name = "NanokeepGuidePanel", .superclass = "NSPanel", .methods = &.{} });
        const panel = objc.msg(Object, objc.msg(Object, panel_class, "alloc", .{}), "initWithContentRect:styleMask:backing:defer:", .{
            rect(0, 0, panel_w, panel_h), @as(objc.NSUInteger, borderless_nonactivating), @as(objc.NSUInteger, 2), objc.NO,
        });
        objc.msg(void, panel, "setReleasedWhenClosed:", .{objc.NO});
        objc.msg(void, panel, "setFloatingPanel:", .{objc.YES});
        objc.msg(void, panel, "setHidesOnDeactivate:", .{objc.NO});
        objc.msg(void, panel, "setLevel:", .{@as(objc.NSInteger, floating_level)});
        objc.msg(void, panel, "setOpaque:", .{objc.NO});
        objc.msg(void, panel, "setBackgroundColor:", .{objc.msg(Object, objc.class("NSColor"), "clearColor", .{})});
        objc.msg(void, panel, "setHasShadow:", .{objc.YES});
        objc.msg(void, panel, "setMovableByWindowBackground:", .{objc.YES});
        objc.msg(void, panel, "setCollectionBehavior:", .{@as(objc.NSUInteger, 1 | (1 << 8))});

        const controller_class = objc.defineClass(.{ .name = "NanokeepGuideController", .methods = &.{
            .{ .name = "poll:", .imp = &pollAction, .types = "v@:@" },
            .{ .name = "dismiss:", .imp = &dismissAction, .types = "v@:@" },
        } });
        const controller = objc.msg(Object, controller_class, "new", .{});
        objc.setZig(controller, g);

        const glass = objc.msg(Object, objc.msg(Object, objc.class("NSVisualEffectView"), "alloc", .{}), "initWithFrame:", .{rect(0, 0, panel_w, panel_h)});
        objc.msg(void, glass, "setMaterial:", .{@as(objc.NSInteger, 6)});
        objc.msg(void, glass, "setBlendingMode:", .{@as(objc.NSInteger, 0)});
        objc.msg(void, glass, "setState:", .{@as(objc.NSInteger, 1)});
        objc.msg(void, glass, "setWantsLayer:", .{objc.YES});
        const layer = objc.msg(Object, glass, "layer", .{});
        objc.msg(void, layer, "setCornerRadius:", .{@as(f64, 16)});
        objc.msg(void, layer, "setMasksToBounds:", .{objc.YES});
        objc.msg(void, panel, "setContentView:", .{glass});
        objc.release(glass);

        const arrow = imageView(symbol("arrow.up"), rect(14, 80, 14, 16));
        objc.msg(void, arrow, "setContentTintColor:", .{objc.msg(Object, objc.class("NSColor"), "controlAccentColor", .{})});
        add(glass, arrow);
        const title = label("Drag nanokeep into the Full Disk Access list", 12.5, 0.23, "labelColor", rect(32, 79, 310, 18));
        add(glass, title);
        const x = objc.msg(Object, objc.class("NSButton"), "buttonWithImage:target:action:", .{ symbol("xmark"), controller, objc.sel("dismiss:") });
        objc.msg(void, x, "setBordered:", .{objc.NO});
        objc.msg(void, x, "setFrame:", .{rect(panel_w - 30, 80, 16, 16)});
        add(glass, x);

        const card_class = objc.defineClass(.{ .name = "NanokeepDragCard", .superclass = "NSView", .protocols = &.{"NSDraggingSource"}, .methods = &.{
            .{ .name = "mouseDown:", .imp = &cardMouseDown, .types = "v@:@" },
            .{ .name = "hitTest:", .imp = &cardHitTest, .types = "@@:{CGPoint=dd}" },
            .{ .name = "draggingSession:sourceOperationMaskForDraggingContext:", .imp = &cardMask, .types = "Q@:@q" },
        } });
        const card = objc.msg(Object, objc.msg(Object, card_class, "alloc", .{}), "initWithFrame:", .{rect(14, 32, panel_w - 28, 38)});
        objc.setZig(card, g);
        objc.msg(void, card, "setWantsLayer:", .{objc.YES});
        const card_layer = objc.msg(Object, card, "layer", .{});
        objc.msg(void, card_layer, "setCornerRadius:", .{@as(f64, 8)});
        const tint = objc.msg(Object, objc.class("NSColor"), "colorWithWhite:alpha:", .{ @as(f64, 0.5), @as(f64, 0.14) });
        objc.msg(void, card_layer, "setBackgroundColor:", .{objc.msg(*anyopaque, tint, "CGColor", .{})});
        add(card, imageView(icon(path), rect(10, 8, 22, 22)));
        add(card, label("nanokeep", 12, 0.23, "labelColor", rect(40, 10, 200, 17)));
        add(card, imageView(symbol("line.3.horizontal"), rect(panel_w - 28 - 26, 11, 14, 14)));
        add(glass, card);
        objc.release(card);

        const footer = label("Or click + in System Settings and choose nanokeep", 10.5, 0, "secondaryLabelColor", rect(14, 10, panel_w - 28, 15));
        add(glass, footer);

        g.panel = panel;
        g.controller = controller;
        g.title = title;
        g.arrow = arrow;
        g.card = card;
        g.footer = footer;
    }

    fn place(g: *Guide) void {
        const p = g.panel orelse return;
        const screens = objc.msg(Object, objc.class("NSScreen"), "screens", .{});
        if (objc.msg(objc.NSUInteger, screens, "count", .{}) == 0) return;
        const primary = objc.msg(CGRect, objc.msg(Object, screens, "objectAtIndex:", .{@as(objc.NSUInteger, 0)}), "frame", .{});
        const main = objc.msg(?Object, objc.class("NSScreen"), "mainScreen", .{}) orelse return;
        const visible = objc.msg(CGRect, main, "visibleFrame", .{});
        const frame = anchor(settingsWindow(primary.size.height), visible);
        const now = objc.msg(CGRect, p, "frame", .{});
        if (@abs(now.origin.x - frame.origin.x) > 4 or @abs(now.origin.y - frame.origin.y) > 4)
            objc.msg(void, p, "setFrame:display:", .{ frame, objc.YES });
    }
};

/// Under the System Settings window when it is on screen, else low in the middle of the screen.
pub fn anchor(target: ?CGRect, screen: CGRect) CGRect {
    var r = if (target) |t|
        rect(t.origin.x + t.size.width / 2 - panel_w / 2, t.origin.y - panel_h + 20, panel_w, panel_h)
    else
        rect(screen.origin.x + screen.size.width / 2 - panel_w / 2, screen.origin.y + 80, panel_w, panel_h);
    r.origin.x = std.math.clamp(r.origin.x, screen.origin.x + 12, screen.origin.x + screen.size.width - panel_w - 12);
    r.origin.y = std.math.clamp(r.origin.y, screen.origin.y + 8, screen.origin.y + screen.size.height - panel_h - 8);
    return r;
}

fn settingsWindow(primary_height: f64) ?CGRect {
    const list = CGWindowListCopyWindowInfo(1 | 16, 0) orelse return null;
    defer CFRelease(list);
    const n = objc.msg(objc.NSUInteger, list, "count", .{});
    for (0..n) |i| {
        const info = objc.msg(Object, list, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
        const owner = objc.fromNSString(objc.msg(?Object, info, "objectForKey:", .{objc.nsString("kCGWindowOwnerName")}));
        var known = false;
        for (settings_owners) |o| known = known or std.mem.eql(u8, o, owner);
        if (!known) continue;
        const layer = objc.msg(?Object, info, "objectForKey:", .{objc.nsString("kCGWindowLayer")}) orelse continue;
        if (objc.msg(objc.NSInteger, layer, "integerValue", .{}) != 0) continue;
        const dict = objc.msg(?Object, info, "objectForKey:", .{objc.nsString("kCGWindowBounds")}) orelse continue;
        var q: CGRect = .{};
        if (!CGRectMakeWithDictionaryRepresentation(dict, &q)) continue;
        return rect(q.origin.x, primary_height - (q.origin.y + q.size.height), q.size.width, q.size.height);
    }
    return null;
}

fn pollAction(self: Object, _: SEL, _: Object) callconv(.c) void {
    const g = objc.getZig(Guide, self) orelse return;
    g.poll();
}

fn dismissAction(self: Object, _: SEL, _: Object) callconv(.c) void {
    const g = objc.getZig(Guide, self) orelse return;
    g.dismiss();
}

fn cardHitTest(self: Object, _: SEL, point: CGPoint) callconv(.c) ?Object {
    const f = objc.msg(CGRect, self, "frame", .{});
    const inside = point.x >= f.origin.x and point.y >= f.origin.y and point.x < f.origin.x + f.size.width and point.y < f.origin.y + f.size.height;
    return if (inside) self else null;
}

fn cardMask(_: Object, _: SEL, _: Object, _: objc.NSInteger) callconv(.c) objc.NSUInteger {
    return drag_copy_link_generic;
}

fn cardMouseDown(self: Object, _: SEL, event: Object) callconv(.c) void {
    const g = objc.getZig(Guide, self) orelse return;
    const item = draggingItem(g.item);
    defer objc.release(item);
    const items = objc.msg(Object, objc.class("NSArray"), "arrayWithObject:", .{item});
    _ = objc.msg(Object, self, "beginDraggingSessionWithItems:event:source:", .{ items, event, self });
}

/// What the card hands to a drag: the file URL of `path`, shown as its Finder icon.
pub fn draggingItem(path: []const u8) Object {
    const url = objc.msg(Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(path)});
    const item = objc.msg(Object, objc.msg(Object, objc.class("NSDraggingItem"), "alloc", .{}), "initWithPasteboardWriter:", .{url});
    objc.msg(void, item, "setDraggingFrame:contents:", .{ rect(10, 8, 22, 22), icon(path) });
    return item;
}

fn rect(x: f64, y: f64, w: f64, h: f64) CGRect {
    return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } };
}

fn symbol(name: []const u8) Object {
    return objc.msg(Object, objc.class("NSImage"), "imageWithSystemSymbolName:accessibilityDescription:", .{ objc.nsString(name), @as(?Object, null) });
}

fn icon(path: []const u8) Object {
    const ws = objc.msg(Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    return objc.msg(Object, ws, "iconForFile:", .{objc.nsString(path)});
}

fn imageView(image: Object, frame: CGRect) Object {
    const v = objc.msg(Object, objc.class("NSImageView"), "imageViewWithImage:", .{image});
    objc.msg(void, v, "setFrame:", .{frame});
    return v;
}

fn label(text: []const u8, size: f64, weight: f64, color: [:0]const u8, frame: CGRect) Object {
    const l = objc.msg(Object, objc.class("NSTextField"), "labelWithString:", .{objc.nsString(text)});
    objc.msg(void, l, "setFont:", .{objc.msg(Object, objc.class("NSFont"), "systemFontOfSize:weight:", .{ size, weight })});
    objc.msg(void, l, "setTextColor:", .{objc.msg(Object, objc.class("NSColor"), color, .{})});
    objc.msg(void, l, "setFrame:", .{frame});
    return l;
}

fn add(parent: Object, child: Object) void {
    objc.msg(void, parent, "addSubview:", .{child});
}
