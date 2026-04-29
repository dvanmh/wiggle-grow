pub const c = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xcursor/Xcursor.h");
    @cInclude("X11/extensions/XInput2.h");
});
