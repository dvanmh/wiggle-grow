const std = @import("std");
const c = @import("c");

var xlib_error_occurred: bool = false;
var xlib_error_code: c_int = 0;

pub fn errorHandler(display: ?*c.Display, event: [*c]c.XErrorEvent) callconv(.c) c_int {
    xlib_error_occurred = true;
    xlib_error_code = event.*.error_code;

    var buf: [256:0]u8 = undefined;
    _ = c.XGetErrorText(display, event.*.error_code, &buf, @intCast(buf.len));
    std.debug.print("X11 error: {s} (code={})\n", .{ buf, event.*.error_code });

    return 0;
}

pub fn ioErrorHandler(display: ?*c.Display) callconv(.c) c_int {
    _ = display;
    std.debug.print("Fatal X11 I/O error\n", .{});
    std.process.exit(1);
}

pub fn xSync(display: *c.Display, discard: bool) !void {
    xlib_error_occurred = false;
    _ = c.XSync(display, @intFromBool(discard));
    if (xlib_error_occurred) return error.X11Error;
}
