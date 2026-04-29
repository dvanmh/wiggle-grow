const std = @import("std");
const CubicBezier = @import("CubicBezier.zig");
const X = @import("x.zig");
const image_resizer = @import("image_resizer.zig");
const Io = std.Io;

const POINTER_GRABBING_MASK = X.ButtonPressMask | X.PointerMotionMask;

const TARGET_FPS = 60;
const GROWN_SIZE = 240;
const GROW_DURATION_MS = 600;
const GROW_CURVE = CubicBezier{ .x1 = 0.42, .y1 = 0.0, .x2 = 0.58, .y2 = 1.0 };

const SPRITE_COUNT = (TARGET_FPS * GROW_DURATION_MS + std.time.ms_per_s - 1) / std.time.ms_per_s;
const FPS_SLEEP = std.time.ns_per_s / TARGET_FPS;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const display = X.openDisplay(null) orelse return error.CannotOpenDisplay;
    defer _ = X.closeDisplay(display);

    X.setupErrorHandlers();
    const root = X.defaultRootWindow(display);

    const cursor_config_size = X.cursorGetDefaultSize(display);
    const base_cursor = X.cursorLibraryLoadImage("left_ptr", null, cursor_config_size).?;

    // Get the largest cursor image for the best grown cursor quality
    const cursor_image = X.cursorLibraryLoadImage("left_ptr", null, std.math.maxInt(i32)).?;

    var initialized_sprites: usize = 0;
    var sprites = try gpa.alloc(*X.CursorImage, SPRITE_COUNT);
    defer {
        for (sprites[0..initialized_sprites]) |s| X.cursorImageDestroy(s);
        gpa.free(sprites);
    }

    const grown_ratio = @as(f32, @floatFromInt(GROWN_SIZE)) / @as(f32, @floatFromInt(base_cursor.size));

    for (sprites) |*s| {
        const progress = GROW_CURVE.eval(@as(f32, @floatFromInt(initialized_sprites)) / (SPRITE_COUNT - 1));
        const width: i32 = @round(std.math.lerp(
            @as(f32, @floatFromInt(base_cursor.width)),
            @as(f32, @floatFromInt(base_cursor.width)) * grown_ratio,
            progress,
        ));
        const height: i32 = @round(std.math.lerp(
            @as(f32, @floatFromInt(base_cursor.height)),
            @as(f32, @floatFromInt(base_cursor.height)) * grown_ratio,
            progress,
        ));

        s.* = X.cursorImageCreate(width, height) orelse return error.CursorImageCreateFailed;
        initialized_sprites += 1;

        const img = s.*;
        img.xhot = @round(std.math.lerp(
            @as(f32, @floatFromInt(base_cursor.xhot)),
            @as(f32, @floatFromInt(base_cursor.xhot)) * grown_ratio,
            progress,
        ));
        img.yhot = @round(std.math.lerp(
            @as(f32, @floatFromInt(base_cursor.yhot)),
            @as(f32, @floatFromInt(base_cursor.yhot)) * grown_ratio,
            progress,
        ));

        image_resizer.resize(cursor_image, img);
    }

    var initialized_cursors: usize = 0;
    var cursors = try gpa.alloc(X.Cursor, SPRITE_COUNT);
    defer {
        for (cursors[0..initialized_sprites]) |c| X.freeCursor(display, c);
        gpa.free(cursors);
    }

    for (cursors, 0..) |*c, i| {
        c.* = X.cursorImageLoadCursor(display, sprites[i]);
        initialized_cursors += 1;
    }

    const grab_result = X.grabPointer(
        display,
        root,
        false,
        POINTER_GRABBING_MASK,
        X.GrabModeAsync,
        X.GrabModeAsync,
        X.None,
        cursors[0],
        X.CurrentTime,
    );
    if (grab_result != X.GrabSuccess) return error.GrabPointerFailed;
    defer _ = X.ungrabPointer(display, X.CurrentTime);

    try X.sync(display, false);

    // var event: XEvent = undefined;
    // while (true) {
    //     _ = XNextEvent(display, &event);
    //     if (event.type == ButtonPress) break;
    // }

    var timer = Io.Timestamp.now(io, .awake);
    var next_frame_ns = timer.nanoseconds;
    for (0..SPRITE_COUNT) |i| {
        X.changeActivePointerGrab(display, POINTER_GRABBING_MASK, cursors[i], X.CurrentTime);
        try X.sync(display, false);

        next_frame_ns += FPS_SLEEP;

        const now_ts = Io.Clock.awake.now(io);
        const frame_end_ns = timer.nanoseconds + timer.durationTo(now_ts).nanoseconds;
        timer = now_ts;

        if (next_frame_ns > frame_end_ns) {
            try io.sleep(.fromNanoseconds(next_frame_ns - frame_end_ns), .awake);
        }
    }

    try io.sleep(.fromSeconds(1), .awake);

    timer = Io.Timestamp.now(io, .awake);
    next_frame_ns = timer.nanoseconds;
    for (0..SPRITE_COUNT) |inv_i| {
        const i = SPRITE_COUNT - inv_i - 1;
        X.changeActivePointerGrab(display, POINTER_GRABBING_MASK, cursors[i], X.CurrentTime);
        try X.sync(display, false);

        next_frame_ns += FPS_SLEEP;

        const now_ts = Io.Clock.awake.now(io);
        const frame_end_ns = timer.nanoseconds + timer.durationTo(now_ts).nanoseconds;
        timer = now_ts;

        if (next_frame_ns > frame_end_ns) {
            try io.sleep(.fromNanoseconds(next_frame_ns - frame_end_ns), .awake);
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
