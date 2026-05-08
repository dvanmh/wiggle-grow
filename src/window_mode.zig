const std = @import("std");
const c = @import("c");
const CursorGrowthCycle = @import("CursorGrowthCycle.zig");
const x11u = @import("x11_util.zig");

const Context = struct {
    allocator: std.mem.Allocator,
    display: *c.Display,
    animation_display: *c.Display,
    win: c.Window,
    gc: c.GC,
    grow_ximages: [][*c]c.XImage,
    shrink_ximages: [][*c]c.XImage,
    grow_sprites: [][*c]c.XcursorImage,
    shrink_sprites: [][*c]c.XcursorImage,
    anchor_x: c_int,
    anchor_y: c_int,
};

pub fn initDisplayer(
    allocator: std.mem.Allocator,
    display: *c.Display,
    root: c.Window,
    grow_sprites: [][*c]c.XcursorImage,
    shrink_sprites: [][*c]c.XcursorImage,
) !CursorGrowthCycle.Displayer {
    const animation_display = c.XOpenDisplay(null) orelse return error.CannotOpenDisplay;
    errdefer _ = c.XCloseDisplay(animation_display);

    const screen = c.XDefaultScreen(display);
    var vinfo: c.XVisualInfo = undefined;
    if (c.XMatchVisualInfo(display, screen, 32, c.TrueColor, &vinfo) == 0) {
        return error.NoArgbVisual;
    }

    const win_width, const win_height, const anchor_x, const anchor_y =
        calculateWindowSizeAndAnchor(grow_sprites, shrink_sprites);

    var attrs = c.XSetWindowAttributes{
        .colormap = c.XCreateColormap(display, root, vinfo.visual, c.AllocNone),
        .background_pixel = 0,
        .border_pixel = 0,
        .override_redirect = 1,
    };
    const win = c.XCreateWindow(
        display,
        root,
        0,
        0,
        win_width,
        win_height,
        0,
        vinfo.depth,
        c.InputOutput,
        vinfo.visual,
        c.CWColormap | c.CWBorderPixel | c.CWBackPixel | c.CWOverrideRedirect,
        &attrs,
    );
    errdefer _ = c.XDestroyWindow(display, win);

    var class_hint = c.XClassHint{
        .res_class = @ptrCast(@constCast("WiggleGrow")),
        .res_name = @ptrCast(@constCast("wiggle-grow")),
    };
    _ = c.XSetClassHint(display, win, &class_hint);

    const win_type = c.XInternAtom(display, "_NET_WM_WINDOW_TYPE_UTILITY", c.False);
    const win_type_prop = c.XInternAtom(display, "_NET_WM_WINDOW_TYPE", c.False);
    _ = c.XChangeProperty(display, win, win_type_prop, c.XA_ATOM, 32, c.PropModeReplace, @ptrCast(&win_type), 1);

    // Makes the window click-through
    c.XShapeCombineRectangles(display, win, c.ShapeInput, 0, 0, null, 0, c.ShapeSet, c.Unsorted);

    const gc = c.XCreateGC(display, win, 0, null);
    errdefer _ = c.XFreeGC(display, gc);

    const grow_ximages = try createXImages(allocator, display, &vinfo, grow_sprites);
    errdefer {
        for (grow_ximages) |xi| {
            xi.*.data = null;
            _ = xi.*.f.destroy_image.?(xi);
        }
        allocator.free(grow_ximages);
    }

    const shrink_ximages = try createXImages(allocator, display, &vinfo, shrink_sprites);
    errdefer {
        for (shrink_ximages) |xi| {
            xi.*.data = null;
            _ = xi.*.f.destroy_image.?(xi);
        }
        allocator.free(shrink_ximages);
    }

    const ctx = try allocator.create(Context);
    errdefer allocator.destroy(ctx);

    ctx.* = .{
        .allocator = allocator,
        .display = display,
        .animation_display = animation_display,
        .win = win,
        .gc = gc,
        .grow_ximages = grow_ximages,
        .shrink_ximages = shrink_ximages,
        .grow_sprites = grow_sprites,
        .shrink_sprites = shrink_sprites,
        .anchor_x = anchor_x,
        .anchor_y = anchor_y,
    };

    return .{
        .ctx = ctx,
        .deinit = deinit,
        .actions = .{
            .onBeforeGrow = onBeforeGrow,
            .onAfterShrink = onAfterShrink,
            .onAnimate = onAnimate,
            .onMotion = onMotion,
        },
    };
}

fn deinit(ptr: *anyopaque) void {
    const ctx: *Context = @ptrCast(@alignCast(ptr));

    for (ctx.grow_ximages) |xi| {
        xi.*.data = null;
        _ = xi.*.f.destroy_image.?(xi);
    }
    ctx.allocator.free(ctx.grow_ximages);

    for (ctx.shrink_ximages) |xi| {
        xi.*.data = null;
        _ = xi.*.f.destroy_image.?(xi);
    }
    ctx.allocator.free(ctx.shrink_ximages);

    _ = c.XFreeGC(ctx.display, ctx.gc);
    _ = c.XDestroyWindow(ctx.display, ctx.win);
    _ = c.XCloseDisplay(ctx.animation_display);

    ctx.allocator.destroy(ctx);
}

fn onBeforeGrow(ptr: *anyopaque) !void {
    const ctx: *Context = @ptrCast(@alignCast(ptr));

    const root = c.XDefaultRootWindow(ctx.animation_display);
    c.XFixesHideCursor(ctx.animation_display, root);
    _ = c.XMapWindow(ctx.animation_display, ctx.win);
    try x11u.xSync(ctx.animation_display, false);
}

fn onAfterShrink(ptr: *anyopaque) !void {
    const ctx: *Context = @ptrCast(@alignCast(ptr));

    const root = c.XDefaultRootWindow(ctx.animation_display);
    _ = c.XUnmapWindow(ctx.animation_display, ctx.win);
    c.XFixesShowCursor(ctx.animation_display, root);
    try x11u.xSync(ctx.animation_display, false);
}

fn onAnimate(ptr: *anyopaque, frame_idx: usize, anim_type: CursorGrowthCycle.AnimationType) !void {
    const ctx: *Context = @ptrCast(@alignCast(ptr));

    const ximages, const sprites = switch (anim_type) {
        .grow => .{ ctx.grow_ximages, ctx.grow_sprites },
        .shrink => .{ ctx.shrink_ximages, ctx.shrink_sprites },
    };
    const xi = ximages[frame_idx];
    const s = sprites[frame_idx];

    _ = c.XClearWindow(ctx.animation_display, ctx.win);
    _ = c.XPutImage(
        ctx.animation_display,
        ctx.win,
        ctx.gc,
        xi,
        0,
        0,
        ctx.anchor_x - @as(c_int, @intCast(s.*.xhot)),
        ctx.anchor_y - @as(c_int, @intCast(s.*.yhot)),
        s.*.width,
        s.*.height,
    );
    _ = c.XRaiseWindow(ctx.animation_display, ctx.win);
    try x11u.xSync(ctx.animation_display, false);
}

fn onMotion(ptr: *anyopaque, x: f64, y: f64) !void {
    const ctx: *Context = @ptrCast(@alignCast(ptr));

    const ix: c_int = @round(x);
    const iy: c_int = @round(y);
    _ = c.XMoveWindow(ctx.display, ctx.win, ix - ctx.anchor_x, iy - ctx.anchor_y);
    _ = c.XRaiseWindow(ctx.display, ctx.win);
    try x11u.xSync(ctx.display, false);
}

fn createXImages(
    allocator: std.mem.Allocator,
    display: *c.Display,
    vinfo: *c.XVisualInfo,
    sprites: [][*c]c.XcursorImage,
) ![][*c]c.XImage {
    const ximages = try allocator.alloc([*c]c.XImage, sprites.len);

    for (ximages, 0..) |*ximg, i| {
        const sprite = sprites[i];
        ximg.* = c.XCreateImage(
            display,
            vinfo.visual,
            @intCast(vinfo.depth),
            c.ZPixmap,
            0,
            @ptrCast(@alignCast(sprite.*.pixels)),
            sprite.*.width,
            sprite.*.height,
            32,
            0,
        );
    }

    return ximages;
}

fn calculateWindowSizeAndAnchor(
    grow_sprites: [][*c]c.XcursorImage,
    shrink_sprites: [][*c]c.XcursorImage,
) struct { c_uint, c_uint, c_int, c_int } {
    var max_left: u32 = 0;
    var max_right: u32 = 0;
    var max_top: u32 = 0;
    var max_bottom: u32 = 0;

    for (grow_sprites) |s| {
        max_left = @max(max_left, s.*.xhot);
        max_right = @max(max_right, s.*.width - s.*.xhot);
        max_top = @max(max_top, s.*.yhot);
        max_bottom = @max(max_bottom, s.*.height - s.*.yhot);
    }

    for (shrink_sprites) |s| {
        max_left = @max(max_left, s.*.xhot);
        max_right = @max(max_right, s.*.width - s.*.xhot);
        max_top = @max(max_top, s.*.yhot);
        max_bottom = @max(max_bottom, s.*.height - s.*.yhot);
    }

    return .{
        @intCast(max_left + max_right),
        @intCast(max_top + max_bottom),
        @intCast(max_left),
        @intCast(max_top),
    };
}
