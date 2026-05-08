const std = @import("std");
const c = @import("c");
const CursorGrowthCycle = @import("CursorGrowthCycle.zig");
const x11u = @import("x11_util.zig");

const POINTER_GRABBING_MASK = c.ButtonPressMask | c.PointerMotionMask;

const Context = struct {
    display: *c.Display,
    root: c.Window,
    grow_cursors: []c.Cursor,
    shrink_cursors: []c.Cursor,
    allocator: std.mem.Allocator,
};

pub fn initDisplayer(
    allocator: std.mem.Allocator,
    display: *c.Display,
    root: c.Window,
    grow_sprites: [][*c]c.XcursorImage,
    shrink_sprites: [][*c]c.XcursorImage,
) !CursorGrowthCycle.Displayer {
    const ctx = try allocator.create(Context);
    errdefer allocator.destroy(ctx);

    ctx.allocator = allocator;
    ctx.display = display;
    ctx.root = root;

    ctx.grow_cursors = try loadCursors(allocator, display, grow_sprites);
    errdefer {
        for (ctx.grow_cursors) |cs| _ = c.XFreeCursor(display, cs);
        allocator.free(ctx.grow_cursors);
    }

    ctx.shrink_cursors = try loadCursors(allocator, display, shrink_sprites);
    errdefer {
        for (ctx.shrink_cursors) |cs| _ = c.XFreeCursor(display, cs);
        allocator.free(ctx.shrink_cursors);
    }

    return .{
        .ctx = ctx,
        .deinit = deinit,
        .actions = .{
            .onBeforeGrow = onBeforeGrow,
            .onAfterShrink = onAfterShrink,
            .onAnimate = onAnimate,
        },
    };
}

fn deinit(ptr: *anyopaque) void {
    const ctx: *Context = @ptrCast(@alignCast(ptr));

    for (ctx.grow_cursors) |cs| _ = c.XFreeCursor(ctx.display, cs);
    ctx.allocator.free(ctx.grow_cursors);

    for (ctx.shrink_cursors) |cs| _ = c.XFreeCursor(ctx.display, cs);
    ctx.allocator.free(ctx.shrink_cursors);

    ctx.allocator.destroy(ctx);
}

fn onBeforeGrow(ptr: *anyopaque) !void {
    const ctx: *Context = @ptrCast(@alignCast(ptr));

    const grab_result = c.XGrabPointer(
        ctx.display,
        ctx.root,
        c.False,
        POINTER_GRABBING_MASK,
        c.GrabModeAsync,
        c.GrabModeAsync,
        c.None,
        ctx.grow_cursors[0],
        c.CurrentTime,
    );
    if (grab_result != c.GrabSuccess) return error.GrabPointerFailed;
    try x11u.xSync(ctx.display, false);
}

fn onAfterShrink(ptr: *anyopaque) !void {
    const ctx: *Context = @ptrCast(@alignCast(ptr));

    _ = c.XUngrabPointer(ctx.display, c.CurrentTime);
    try x11u.xSync(ctx.display, false);
}

fn onAnimate(ptr: *anyopaque, frame_idx: usize, anim_type: CursorGrowthCycle.AnimationType) !void {
    const ctx: *Context = @ptrCast(@alignCast(ptr));

    const cursors = switch (anim_type) {
        .grow => ctx.grow_cursors,
        .shrink => ctx.shrink_cursors,
    };
    const cs = cursors[frame_idx];

    _ = c.XChangeActivePointerGrab(ctx.display, POINTER_GRABBING_MASK, cs, c.CurrentTime);
    try x11u.xSync(ctx.display, false);
}

fn loadCursors(
    allocator: std.mem.Allocator,
    display: *c.Display,
    sprites: [][*c]c.XcursorImage,
) ![]c.Cursor {
    var initialized_cursors: usize = 0;
    var cursors = try allocator.alloc(c.Cursor, sprites.len);
    errdefer {
        for (cursors[0..initialized_cursors]) |cs| _ = c.XFreeCursor(display, cs);
        allocator.free(cursors);
    }

    for (cursors, 0..) |*cs, i| {
        cs.* = c.XcursorImageLoadCursor(display, sprites[i]);
        initialized_cursors += 1;
    }

    return cursors;
}
