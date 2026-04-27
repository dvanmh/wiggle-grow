const std = @import("std");

pub const Display = opaque {};
pub const Window = usize;
pub const Cursor = usize;

pub const None = 0;
pub const CurrentTime = 0;
pub const GrabModeAsync = 1;

pub const ButtonPressMask = 1 << 2;
pub const PointerMotionMask = 1 << 6;

pub const GrabSuccess = 0;
pub const ButtonPress = 4;

pub const CursorImage = extern struct {
    version: u32,
    size: u32,
    width: u32,
    height: u32,
    xhot: u32,
    yhot: u32,
    delay: u32,
    pixels: [*c]u32,
};

pub const CursorImages = extern struct {
    nimage: i32,
    images: [*c]*CursorImage,
    name: [*c]const u8,
};

pub const Event = extern struct {
    type: i32,
    pad: [24]usize,
};

pub const ErrorEvent = extern struct {
    type: i32,
    display: ?*Display,
    resourceid: i64,
    serial: i64,
    error_code: u8,
    request_code: u8,
    minor_code: u8,
};

var xlib_error_occurred: bool = false;
pub var last_error_code: c_int = 0;

extern "c" fn XOpenDisplay(display_name: ?[*:0]const u8) ?*Display;
pub fn openDisplay(display_name: ?[*:0]const u8) ?*Display {
    return XOpenDisplay(display_name);
}

extern "c" fn XCloseDisplay(display: *Display) i32;
pub fn closeDisplay(display: *Display) i32 {
    return XCloseDisplay(display);
}

extern "c" fn XDefaultRootWindow(display: *Display) Window;
pub fn defaultRootWindow(display: *Display) Window {
    return XDefaultRootWindow(display);
}

extern "c" fn XNextEvent(display: *Display, event_return: *Event) i32;
pub fn nextEvent(display: *Display, event_return: *Event) i32 {
    return XNextEvent(display, event_return);
}

extern "c" fn XGrabPointer(
    display: *Display,
    grab_window: Window,
    owner_events: bool,
    event_mask: u32,
    pointer_mode: i32,
    keyboard_mode: i32,
    confine_to: Window,
    cursor: Cursor,
    time: u64,
) i32;
pub fn grabPointer(
    display: *Display,
    grab_window: Window,
    owner_events: bool,
    event_mask: u32,
    pointer_mode: i32,
    keyboard_mode: i32,
    confine_to: Window,
    cursor: Cursor,
    time: u64,
) i32 {
    return XGrabPointer(
        display,
        grab_window,
        owner_events,
        event_mask,
        pointer_mode,
        keyboard_mode,
        confine_to,
        cursor,
        time,
    );
}

extern "c" fn XChangeActivePointerGrab(display: *Display, event_mask: u32, cursor: Cursor, time: u64) void;
pub fn changeActivePointerGrab(display: *Display, event_mask: u32, cursor: Cursor, time: u64) void {
    XChangeActivePointerGrab(display, event_mask, cursor, time);
}

extern "c" fn XUngrabPointer(display: *Display, time: u64) i32;
pub fn ungrabPointer(display: *Display, time: u64) i32 {
    return XUngrabPointer(display, time);
}

extern "c" fn XFreeCursor(display: *Display, cursor: Cursor) void;
pub fn freeCursor(display: *Display, cursor: Cursor) void {
    XFreeCursor(display, cursor);
}

extern "c" fn XSync(display: *Display, discard: bool) void;
pub fn sync(display: *Display, discard: bool) !void {
    xlib_error_occurred = false;
    XSync(display, discard);
    if (xlib_error_occurred) return error.X11Error;
}

extern "c" fn XGetErrorText(display: *Display, code: i32, buffer_return: [*:0]const u8, length: i32) void;
pub fn getErrorText(display: *Display, code: i32, buffer_return: [*:0]const u8, length: i32) void {
    XGetErrorText(display, code, buffer_return, length);
}

extern "c" fn XcursorLibraryLoadImage(file: ?[*:0]const u8, theme: ?[*:0]const u8, size: i32) ?*CursorImage;
pub fn cursorLibraryLoadImage(file: ?[*:0]const u8, theme: ?[*:0]const u8, size: i32) ?*CursorImage {
    return XcursorLibraryLoadImage(file, theme, size);
}

extern "c" fn XcursorImageCreate(width: i32, height: i32) ?*CursorImage;
pub fn cursorImageCreate(width: i32, height: i32) ?*CursorImage {
    return XcursorImageCreate(width, height);
}

extern "c" fn XcursorImageDestroy(image: *CursorImage) void;
pub fn cursorImageDestroy(image: *CursorImage) void {
    XcursorImageDestroy(image);
}

extern "c" fn XcursorImageLoadCursor(display: *Display, image: *CursorImage) Cursor;
pub fn cursorImageLoadCursor(display: *Display, image: *CursorImage) Cursor {
    return XcursorImageLoadCursor(display, image);
}

extern "c" fn XcursorGetDefaultSize(display: *Display) i32;
pub fn cursorGetDefaultSize(display: *Display) i32 {
    return XcursorGetDefaultSize(display);
}

extern "c" fn XSetErrorHandler(handler: ?XErrorHandler) ?XErrorHandler;
const XErrorHandler = *const fn (display: *Display, event: ?*ErrorEvent) callconv(.c) c_int;
fn xErrorHandler(display: *Display, event: [*c]ErrorEvent) callconv(.c) c_int {
    xlib_error_occurred = true;
    last_error_code = event.*.error_code;

    var buf: [256:0]u8 = undefined;
    XGetErrorText(display, event.*.error_code, &buf, @intCast(buf.len));
    std.debug.print("X11 error: {s} (code={})\n", .{ buf, event.*.error_code });

    return 0;
}

extern "c" fn XSetIOErrorHandler(handler: ?XIOErrorHandler) ?XIOErrorHandler;
const XIOErrorHandler = *const fn (display: ?*Display) callconv(.c) c_int;
fn xIOErrorHandler(display: ?*Display) callconv(.c) c_int {
    _ = display;
    std.debug.print("Fatal X11 I/O error\n", .{});
    std.process.exit(1);
}

pub fn setupErrorHandlers() void {
    _ = XSetErrorHandler(xErrorHandler);
    _ = XSetIOErrorHandler(xIOErrorHandler);
}
