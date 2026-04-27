const std = @import("std");
const CubicBezier = @import("CubicBezier.zig");
const X = @import("x.zig");
const Io = std.Io;

const POINTER_GRABBING_MASK = X.ButtonPressMask | X.PointerMotionMask;

const TARGET_FPS = 60;
const GROWN_SIZE = 240;
const GROW_DURATION_MS = 1000;
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

    // Get the largest cursor image for the best big cursor quality
    const cursor_image = X.cursorLibraryLoadImage("left_ptr", null, std.math.maxInt(i32)).?;

    var initialized_sprites: usize = 0;
    var sprites = try gpa.alloc(*X.CursorImage, SPRITE_COUNT);
    defer {
        for (sprites[0..initialized_sprites]) |s| X.cursorImageDestroy(s);
        gpa.free(sprites);
    }

    const grown_ratio = @as(f32, @floatFromInt(GROWN_SIZE)) / @as(f32, @floatFromInt(base_cursor.size));

    for (sprites) |*s| {
        s.* = X.cursorImageCreate(GROWN_SIZE, GROWN_SIZE) orelse return error.CursorImageCreateFailed;
        initialized_sprites += 1;

        const progress = GROW_CURVE.eval(
            @as(f32, @floatFromInt(initialized_sprites - 1)) / (SPRITE_COUNT - 1),
        );
        const size: u32 = @round(std.math.lerp(
            @as(f32, @floatFromInt(base_cursor.size)),
            GROWN_SIZE,
            progress,
        ));
        const xhot: u32 = @round(std.math.lerp(
            @as(f32, @floatFromInt(base_cursor.xhot)),
            @as(f32, @floatFromInt(base_cursor.xhot)) * grown_ratio,
            progress,
        ));
        const yhot: u32 = @round(std.math.lerp(
            @as(f32, @floatFromInt(base_cursor.yhot)),
            @as(f32, @floatFromInt(base_cursor.yhot)) * grown_ratio,
            progress,
        ));

        const img = s.*;
        img.xhot = xhot;
        img.yhot = yhot;
        for (0..size) |y| {
            const cur_y: usize = @round(std.math.lerp(
                0,
                @as(f32, @floatFromInt(cursor_image.size - 1)),
                @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(size - 1)),
            ));
            for (0..size) |x| {
                const cur_x: usize = @round(std.math.lerp(
                    0,
                    @as(f32, @floatFromInt(cursor_image.size - 1)),
                    @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(size - 1)),
                ));

                const idx = y * img.size + x;
                const cur_idx = cur_y * cursor_image.size + cur_x;
                img.pixels[idx] = cursor_image.pixels[cur_idx];
            }
        }
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
}

test {
    std.testing.refAllDecls(@This());
}
