const std = @import("std");
const config = @import("config");
const c = @import("c");
const image_resizer = @import("image_resizer.zig");
const args_parser = @import("args_parser.zig");
const CubicBezier = @import("CubicBezier.zig");
const WiggleDetector = @import("WiggleDetector.zig");
const CursorGrowthCycle = @import("CursorGrowthCycle.zig");
const cursor_mode = @import("cursor_mode.zig");
const window_mode = @import("window_mode.zig");
const x11u = @import("x11_util.zig");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args_iterator = init.minimal.args.iterate();
    _ = args_iterator.next(); // Skips the executable name
    const options = try args_parser.parse(
        struct {
            help: bool = false,
            version: bool = false,
            mode: enum { window, cursor } = .window,
            fps: u32 = 60,
            cursor_size: u32 = 180,
            grow_duration: u32 = 300,
            shrink_duration: u32 = 150,
            hold_duration: u32 = 75,
            grow_bezier: []const u8 = "easeInOut",
            shrink_bezier: []const u8 = "easeInOut",
            wiggle_detection_window: u32 = 750,
            min_wiggle_distance: f32 = 3000.0,
            min_wiggle_flips: u32 = 6,
            min_wiggle_velocity: f32 = 3.5,

            pub const shorts = struct {
                h: []const u8 = "help",
                v: []const u8 = "version",
                m: []const u8 = "mode",
                f: []const u8 = "fps",
                c: []const u8 = "cursor_size",
                g: []const u8 = "grow_duration",
                s: []const u8 = "shrink_duration",
                H: []const u8 = "hold_duration",
                b: []const u8 = "grow_bezier",
                B: []const u8 = "shrink_bezier",
                w: []const u8 = "wiggle_detection_window",
                d: []const u8 = "min_wiggle_distance",
                n: []const u8 = "min_wiggle_flips",
                V: []const u8 = "min_wiggle_velocity",
            };
        },
        args_iterator,
    );

    if (options.help) {
        try std.Io.File.stdout().writeStreamingAll(io,
            \\Makes your cursor grow when you wiggle it.
            \\
            \\
        ++ "Usage: " ++ config.exe_name ++ " [options]\n" ++
            \\
            \\Options:
            \\  -h, --help                         Show this help message
            \\  -v, --version                      Show version
            \\  -m, --mode <mode>                  How to display the grown cursor (window or cursor, default: window)
            \\  -f, --fps <N>                      Cursor animation frame rate (default: 60)
            \\  -c, --cursor-size <N>              Cursor size in pixels when grown (default: 180)
            \\  -g, --grow-duration <N>            Duration in ms to grow the cursor (default: 300)
            \\  -s, --shrink-duration <N>          Duration in ms to shrink the cursor back (default: 150)
            \\  -H, --hold-duration <N>            Duration in ms to stay grown before shrinking (default: 75)
            \\  -b, --grow-bezier <S>              Cubic Bézier curve for grow animation (default: easeInOut)
            \\  -B, --shrink-bezier <S>            Cubic Bézier curve for shrink animation (default: easeInOut)
            \\  -w, --wiggle-detection-window <N>  Time window in ms for wiggle detection (default: 750)
            \\  -d, --min-wiggle-distance <N>      Minimum distance in pixels to count as wiggling (default: 3000)
            \\  -n, --min-wiggle-flips <N>         Minimum direction changes to count as wiggling (default: 6)
            \\  -V, --min-wiggle-velocity <N>      Minimum velocity in px/ms to count as wiggling (default: 3.5)
            \\
            \\Bézier curve format (used by -b and -B):
            \\  Preset: one of
            \\    linear, ease, easeIn, easeOut, easeInOut,
            \\    easeInSine, easeOutSine, easeInOutSine,
            \\    easeInQuad, easeOutQuad, easeInOutQuad,
            \\    easeInCubic, easeOutCubic, easeInOutCubic,
            \\    easeInExpo, easeOutExpo, easeInOutExpo,
            \\    easeInCirc, easeOutCirc, easeInOutCirc,
            \\    sharp, decelerate, accelerate, swift
            \\  Custom: <x1>,<y1>,<x2>,<y2>  (e.g. 0.25,0.1,0.25,1.0)
            \\
        );
        return;
    }

    if (options.version) {
        try std.Io.File.stdout().writeStreamingAll(io, config.version ++ "\n");
        return;
    }

    const grow_bezier = CubicBezier.parse(options.grow_bezier) catch |e| {
        std.debug.print("Invalid grow bezier: {s}\n", .{options.grow_bezier});
        return e;
    };
    const shrink_bezier = CubicBezier.parse(options.shrink_bezier) catch |e| {
        std.debug.print("Invalid shrink bezier: {s}\n", .{options.shrink_bezier});
        return e;
    };

    const display = c.XOpenDisplay(null) orelse return error.CannotOpenDisplay;
    defer _ = c.XCloseDisplay(display);
    const root = c.XDefaultRootWindow(display);

    _ = c.XSetErrorHandler(x11u.errorHandler);
    _ = c.XSetIOErrorHandler(x11u.ioErrorHandler);

    const grow_sprite_count: usize =
        @intCast(@divTrunc(options.fps * options.grow_duration + std.time.ms_per_s - 1, std.time.ms_per_s));
    const shrink_sprite_count: usize =
        @intCast(@divTrunc(options.fps * options.shrink_duration + std.time.ms_per_s - 1, std.time.ms_per_s));
    const time_between_frame_ns = @divTrunc(std.time.ns_per_s, options.fps);

    if (options.mode == .cursor) {
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
        if (options.cursor_size > max_cursor_width or options.cursor_size > max_cursor_height) {
            return error.GrownCursorSizeTooBig;
        }
    }

    std.debug.print("Generating cursor sprites\n", .{});

    const cursor_config_size = c.XcursorGetDefaultSize(display);
    const base_cursor_ptr = c.XcursorLibraryLoadImage("left_ptr", null, cursor_config_size);
    defer c.XcursorImageDestroy(base_cursor_ptr);

    // Get the largest cursor image for the best grown cursor quality
    const cursor_image_ptr = c.XcursorLibraryLoadImage("left_ptr", null, std.math.maxInt(i32));
    defer c.XcursorImageDestroy(cursor_image_ptr);

    const grow_sprites =
        try generateCursorSprites(gpa, base_cursor_ptr, cursor_image_ptr, grow_sprite_count, options.cursor_size, grow_bezier);
    defer {
        for (grow_sprites) |s| c.XcursorImageDestroy(s);
        gpa.free(grow_sprites);
    }

    const shrink_sprites =
        try generateCursorSprites(gpa, base_cursor_ptr, cursor_image_ptr, shrink_sprite_count, options.cursor_size, shrink_bezier);
    defer {
        for (shrink_sprites) |s| c.XcursorImageDestroy(s);
        gpa.free(shrink_sprites);
    }

    std.debug.print("Listening for cursor movements\n", .{});

    const xi_opcode, const event_mask_ptr, const mask = try registerPointerMotionEvents(gpa, display, root);
    defer {
        gpa.destroy(event_mask_ptr);
        gpa.free(mask);
    }

    var wiggle_detector = try WiggleDetector.init(gpa, .{
        .time_window_ms = options.wiggle_detection_window,
        .min_distance_px = options.min_wiggle_distance,
        .min_flips = options.min_wiggle_flips,
        .min_velocity_px_per_ms = options.min_wiggle_velocity,
    });
    defer wiggle_detector.deinit();

    const displayer = try switch (options.mode) {
        .window => window_mode.initDisplayer(gpa, display, root, grow_sprites, shrink_sprites),
        .cursor => cursor_mode.initDisplayer(gpa, display, root, grow_sprites, shrink_sprites),
    };
    defer displayer.deinit(displayer.ctx);

    var cycle = CursorGrowthCycle.init(
        &wiggle_detector,
        displayer,
        .{
            .grow_frame_count = grow_sprite_count,
            .shrink_frame_count = shrink_sprite_count,
            .hold_duration_ms = options.hold_duration,
            .time_between_frame_ns = time_between_frame_ns,
        },
    );
    try cycle.run(io, display, xi_opcode);
}

fn generateCursorSprites(
    gpa: std.mem.Allocator,
    base_cursor_ptr: [*c]c.XcursorImage,
    cursor_image_ptr: [*c]c.XcursorImage,
    sprite_count: usize,
    grown_size: u32,
    animation_curve: CubicBezier,
) ![][*c]c.XcursorImage {
    const base_cursor = base_cursor_ptr.*;

    var initialized_sprites: usize = 0;
    var sprites = try gpa.alloc([*c]c.XcursorImage, sprite_count);
    errdefer {
        for (sprites[0..initialized_sprites]) |s| c.XcursorImageDestroy(s);
        gpa.free(sprites);
    }

    const grown_ratio = @as(f32, @floatFromInt(grown_size)) / @as(f32, @floatFromInt(base_cursor.size));

    for (sprites) |*s| {
        const progress = animation_curve.eval(
            @as(f32, @floatFromInt(initialized_sprites)) / @as(f32, @floatFromInt(sprite_count - 1)),
        );
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

    return sprites;
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

    try x11u.xSync(display, false);

    return .{ xi_opcode, event_mask_ptr, mask };
}

test {
    std.testing.refAllDecls(@This());
}
