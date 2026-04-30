const std = @import("std");
const c = @import("c");
const image_resizer = @import("image_resizer.zig");
const CubicBezier = @import("CubicBezier.zig");
const WiggleDetector = @import("WiggleDetector.zig");
const Io = std.Io;

const TARGET_FPS = 60;
const GROWN_SIZE = 176;
const GROW_DURATION_MS = 300;
const SHRINK_DURATION_MS = 200;
const STAY_GROWN_DURATION_MS = 100;
const GROW_CURVE = CubicBezier{ .x1 = 0.42, .y1 = 0.0, .x2 = 0.58, .y2 = 1.0 };

const GROW_SPRITE_COUNT = (TARGET_FPS * GROW_DURATION_MS + std.time.ms_per_s - 1) / std.time.ms_per_s;
const SHRINK_SPRITE_COUNT = (TARGET_FPS * SHRINK_DURATION_MS + std.time.ms_per_s - 1) / std.time.ms_per_s;
const FPS_SLEEP = std.time.ns_per_s / TARGET_FPS;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const display = c.XOpenDisplay(null) orelse return error.CannotOpenDisplay;
    defer _ = c.XCloseDisplay(display);
    const root = c.XDefaultRootWindow(display);

    _ = c.XSetErrorHandler(xErrorHandler);
    _ = c.XSetIOErrorHandler(xIOErrorHandler);

    var max_cursor_width: c_uint = 0;
    var max_cursor_height: c_uint = 0;
    _ = c.XQueryBestCursor(
        display,
        root,
        std.math.maxInt(c_uint),
        std.math.maxInt(c_uint),
        &max_cursor_width,
        &max_cursor_height,
    );
    if (GROWN_SIZE > max_cursor_width or GROWN_SIZE > max_cursor_height) {
        return error.GrownCursorSizeTooBig;
    }

    std.debug.print("Generating cursor sprites\n", .{});

    const grow_sprites, const grow_cursors = try generateCursorSprites(gpa, display, GROW_SPRITE_COUNT);
    defer {
        for (grow_sprites) |s| c.XcursorImageDestroy(s);
        gpa.free(grow_sprites);
        for (grow_cursors) |cs| _ = c.XFreeCursor(display, cs);
        gpa.free(grow_cursors);
    }

    const shrink_sprites, const shrink_cursors = try generateCursorSprites(gpa, display, SHRINK_SPRITE_COUNT);
    defer {
        for (shrink_sprites) |s| c.XcursorImageDestroy(s);
        gpa.free(shrink_sprites);
        for (shrink_cursors) |cs| _ = c.XFreeCursor(display, cs);
        gpa.free(shrink_cursors);
    }
    std.mem.reverse(c.Cursor, shrink_cursors);

    std.debug.print("Listening for cursor movements\n", .{});

    const xi_opcode, const event_mask_ptr, const mask = try registerPointerMotionEvents(gpa, display, root);
    defer {
        gpa.destroy(event_mask_ptr);
        gpa.free(mask);
    }

    var wiggle_detector = try WiggleDetector.init(gpa);
    defer wiggle_detector.deinit();

    var future_finished = true;
    var last_wiggle_tracking_future_finished = true;
    var future: Io.Future(@typeInfo(@TypeOf(growCursor)).@"fn".return_type.?) = undefined;
    defer if (!future_finished) future.cancel(io) catch {};

    var event: c.XEvent = undefined;
    while (true) {
        _ = c.XNextEvent(display, &event);
        if (event.type == c.GenericEvent and event.xgeneric.extension == xi_opcode and
            c.XGetEventData(display, &event.xcookie) != 0)
        {
            const cookie = &event.xcookie;
            defer c.XFreeEventData(display, cookie);

            if (cookie.evtype == c.XI_Motion) {
                const raw_event: *c.XIDeviceEvent = @ptrCast(@alignCast(cookie.data));
                const x = raw_event.event_x;
                const y = raw_event.event_y;
                const now_ms = Io.Timestamp.now(io, .awake).toMilliseconds();

                // Resets wiggle_detector after each cursor growing cycle so user cannot trigger
                // cursor growing too many times in a short period
                if (!last_wiggle_tracking_future_finished and future_finished) {
                    wiggle_detector.reset();
                }
                const is_wiggling = try wiggle_detector.addSample(x, y, now_ms);
                last_wiggle_tracking_future_finished = future_finished;

                const any_buttons_held = blk: for (0..@intCast(raw_event.buttons.mask_len)) |i| {
                    if (raw_event.buttons.mask[i >> 3] & (@as(u8, 1) << @as(u3, @intCast(i & 7))) != 0) {
                        break :blk true;
                    }
                } else false;

                if (!any_buttons_held and is_wiggling and future_finished) {
                    future_finished = false;
                    future = io.async(growCursor, .{
                        io,
                        display,
                        root,
                        grow_cursors,
                        shrink_cursors,
                        &wiggle_detector,
                        &future_finished,
                    });
                }
            }

            if (cookie.evtype == c.XI_ButtonPress and !future_finished) {
                future.cancel(io) catch {};
            }
        }
    }
}

const POINTER_GRABBING_MASK = c.ButtonPressMask | c.PointerMotionMask;

fn growCursor(
    io: std.Io,
    display: *c.Display,
    window: c.Window,
    grow_cursors: []c.Cursor,
    shrink_cursors: []c.Cursor,
    wiggle_detector: *const WiggleDetector,
    future_finished: *bool,
) !void {
    defer future_finished.* = true;

    const grab_result = c.XGrabPointer(
        display,
        window,
        @intFromBool(false),
        POINTER_GRABBING_MASK,
        c.GrabModeAsync,
        c.GrabModeAsync,
        c.None,
        grow_cursors[0],
        c.CurrentTime,
    );
    if (grab_result != c.GrabSuccess) return error.GrabPointerFailed;
    defer _ = c.XUngrabPointer(display, c.CurrentTime);
    try xSync(display, false);

    try animateCursor(io, display, grow_cursors);
    stayGrown(io, wiggle_detector) catch |e| switch (e) {
        error.Canceled => {}, // Shrinks immediately when being canceled
    };
    try animateCursor(io, display, shrink_cursors);
}

fn animateCursor(io: std.Io, display: *c.Display, cursors: []c.Cursor) !void {
    var timer = Io.Timestamp.now(io, .awake);
    var next_frame_ns = timer.nanoseconds;
    for (cursors) |cs| {
        _ = c.XChangeActivePointerGrab(display, POINTER_GRABBING_MASK, cs, c.CurrentTime);
        try xSync(display, false);

        next_frame_ns += FPS_SLEEP;

        const now_ts = Io.Clock.awake.now(io);
        const frame_end_ns = timer.nanoseconds + timer.durationTo(now_ts).nanoseconds;
        timer = now_ts;

        if (next_frame_ns > frame_end_ns) {
            try io.sleep(.fromNanoseconds(next_frame_ns - frame_end_ns), .awake);
        }
    }
}

fn stayGrown(io: std.Io, wiggle_detector: *const WiggleDetector) !void {
    var sleep_time_left_ms: i64 = STAY_GROWN_DURATION_MS;
    var last_pos = wiggle_detector.last_pos;
    while (wiggle_detector.isWiggling(Io.Timestamp.now(io, .awake).toMilliseconds())) {
        try io.sleep(.fromMilliseconds(10), .awake);

        const current_pos = wiggle_detector.last_pos;
        if (std.meta.eql(last_pos, current_pos)) {
            sleep_time_left_ms -= 10;
        } else {
            sleep_time_left_ms = STAY_GROWN_DURATION_MS;
        }

        if (sleep_time_left_ms <= 0) {
            break;
        }

        last_pos = current_pos;
    }
    if (sleep_time_left_ms > 0) try io.sleep(.fromMilliseconds(sleep_time_left_ms), .awake);
}

fn generateCursorSprites(
    gpa: std.mem.Allocator,
    display: *c.Display,
    sprite_count: usize,
) !struct { [][*c]c.XcursorImage, []c.Cursor } {
    const cursor_config_size = c.XcursorGetDefaultSize(display);
    const base_cursor_ptr = c.XcursorLibraryLoadImage("left_ptr", null, cursor_config_size);
    const base_cursor = base_cursor_ptr.*;

    // Get the largest cursor image for the best grown cursor quality
    const cursor_image_ptr = c.XcursorLibraryLoadImage("left_ptr", null, std.math.maxInt(i32));

    var initialized_sprites: usize = 0;
    var sprites = try gpa.alloc([*c]c.XcursorImage, sprite_count);
    errdefer {
        for (sprites[0..initialized_sprites]) |s| c.XcursorImageDestroy(s);
        gpa.free(sprites);
    }

    const grown_ratio = @as(f32, @floatFromInt(GROWN_SIZE)) / @as(f32, @floatFromInt(base_cursor.size));

    for (sprites) |*s| {
        const progress = GROW_CURVE.eval(@as(f32, @floatFromInt(initialized_sprites)) / @as(f32, @floatFromInt(sprite_count - 1)));
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

        s.* = c.XcursorImageCreate(width, height) orelse return error.CursorImageCreateFailed;
        initialized_sprites += 1;

        const img = s.*;
        img.*.xhot = @round(std.math.lerp(
            @as(f32, @floatFromInt(base_cursor.xhot)),
            @as(f32, @floatFromInt(base_cursor.xhot)) * grown_ratio,
            progress,
        ));
        img.*.yhot = @round(std.math.lerp(
            @as(f32, @floatFromInt(base_cursor.yhot)),
            @as(f32, @floatFromInt(base_cursor.yhot)) * grown_ratio,
            progress,
        ));

        image_resizer.resize(@ptrCast(@alignCast(cursor_image_ptr)), @ptrCast(@alignCast(img)));
    }

    var initialized_cursors: usize = 0;
    var cursors = try gpa.alloc(c.Cursor, sprite_count);
    errdefer {
        for (cursors[0..initialized_sprites]) |cs| _ = c.XFreeCursor(display, cs);
        gpa.free(cursors);
    }

    for (cursors, 0..) |*cs, i| {
        cs.* = c.XcursorImageLoadCursor(display, sprites[i]);
        initialized_cursors += 1;
    }

    return .{ sprites, cursors };
}

fn registerPointerMotionEvents(
    gpa: std.mem.Allocator,
    display: *c.Display,
    window: c.Window,
) !struct { i32, *c.XIEventMask, []u8 } {
    var xi_opcode: i32 = undefined;
    var event: i32 = undefined;
    var err: i32 = undefined;
    if (c.XQueryExtension(display, "XInputExtension", &xi_opcode, &event, &err) == 0) {
        return error.XInputNotAvailable;
    }

    var major: i32 = 2;
    var minor: i32 = 0;
    const query_result = c.XIQueryVersion(display, &major, &minor);
    if (query_result != c.Success) return error.XInput2NotSupported;

    const event_mask_ptr = try gpa.create(c.XIEventMask);
    errdefer gpa.destroy(event_mask_ptr);

    const mask = try gpa.alloc(u8, c.XIMaskLen(c.XI_LASTEVENT));
    errdefer gpa.free(mask);
    @memset(mask, 0);

    mask[c.XI_Motion >> 3] |= (1 << (c.XI_Motion & 7));
    mask[c.XI_ButtonPress >> 3] |= (1 << (c.XI_ButtonPress & 7));

    event_mask_ptr.* = c.XIEventMask{
        .deviceid = c.XIAllDevices,
        .mask_len = @intCast(mask.len),
        .mask = @ptrCast(mask),
    };

    const select_result = c.XISelectEvents(display, window, event_mask_ptr, 1);
    if (select_result != c.Success) return error.XInputSelectEventsFailed;

    try xSync(display, false);

    return .{ xi_opcode, event_mask_ptr, mask };
}

var xlib_error_occurred: bool = false;
var xlib_error_code: c_int = 0;

fn xErrorHandler(display: ?*c.Display, event: [*c]c.XErrorEvent) callconv(.c) c_int {
    xlib_error_occurred = true;
    xlib_error_code = event.*.error_code;

    var buf: [256:0]u8 = undefined;
    _ = c.XGetErrorText(display, event.*.error_code, &buf, @intCast(buf.len));
    std.debug.print("X11 error: {s} (code={})\n", .{ buf, event.*.error_code });

    return 0;
}

fn xIOErrorHandler(display: ?*c.Display) callconv(.c) c_int {
    _ = display;
    std.debug.print("Fatal X11 I/O error\n", .{});
    std.process.exit(1);
}

fn xSync(display: *c.Display, discard: bool) !void {
    xlib_error_occurred = false;
    _ = c.XSync(display, @intFromBool(discard));
    if (xlib_error_occurred) return error.X11Error;
}

test {
    std.testing.refAllDecls(@This());
}
