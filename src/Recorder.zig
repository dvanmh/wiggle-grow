const std = @import("std");
const c = @import("c");
const x11u = @import("x11_util.zig");
const Io = std.Io;
const Self = @This();

const BUF_SIZE = 256;

io: Io,
future: Io.Future(void),

control_display: *c.Display,
data_display: *c.Display,
ctx: c.XRecordContext,
motion_range: *c.XRecordRange,
button_range: *c.XRecordRange,

mutex: Io.Mutex = Io.Mutex.init,
cond: Io.Condition = Io.Condition.init,

event_buf: [BUF_SIZE]Event = undefined,
head: u16 = 0,
count: u16 = 0,

return_buf: [BUF_SIZE]Event = undefined,

pub const Event = union(enum) {
    motion: Motion,
    button_press,

    pub const Motion = struct {
        x: f64,
        y: f64,
        state: u16,
    };
};

pub fn init(io: Io, control_display: *c.Display) !Self {
    const data_display = c.XOpenDisplay(null) orelse return error.CannotOpenDisplay;
    errdefer _ = c.XCloseDisplay(data_display);

    var rec_major: c_int = undefined;
    var rec_minor: c_int = undefined;
    if (c.XRecordQueryVersion(control_display, &rec_major, &rec_minor) == 0) {
        return error.RecordNotAvailable;
    }

    const motion_range = c.XRecordAllocRange() orelse return error.OutOfMemory;
    errdefer _ = c.XFree(motion_range);
    motion_range.*.device_events.first = c.MotionNotify;
    motion_range.*.device_events.last = c.MotionNotify;

    const button_range = c.XRecordAllocRange() orelse return error.OutOfMemory;
    errdefer _ = c.XFree(button_range);
    button_range.*.device_events.first = c.ButtonPress;
    button_range.*.device_events.last = c.ButtonPress;

    const ranges = [_]?*c.XRecordRange{ motion_range, button_range };
    var clients: c.XRecordClientSpec = c.XRecordAllClients;
    const ctx = c.XRecordCreateContext(control_display, 0, &clients, 1, @constCast(&ranges), ranges.len);
    if (ctx == 0) return error.RecordCreateContextFailed;
    errdefer {
        _ = c.XRecordDisableContext(control_display, ctx);
        _ = c.XRecordFreeContext(control_display, ctx);
    }

    try x11u.xSync(control_display, false);

    return .{
        .io = io,
        .control_display = control_display,
        .data_display = data_display,
        .ctx = ctx,
        .future = undefined,
        .motion_range = motion_range,
        .button_range = button_range,
    };
}

pub fn start(self: *Self) void {
    self.future = self.io.async(recordStart, .{self});
}

pub fn deinit(self: *Self, io: Io) void {
    _ = c.XRecordDisableContext(self.control_display, self.ctx);
    _ = c.XRecordFreeContext(self.control_display, self.ctx);
    _ = c.XFree(self.button_range);
    _ = c.XFree(self.motion_range);
    _ = c.XCloseDisplay(self.data_display);
    _ = self.future.await(io);
}

pub fn waitForEvents(self: *Self) ![]Event {
    try self.mutex.lock(self.io);
    defer self.mutex.unlock(self.io);

    while (self.count == 0) {
        try self.cond.wait(self.io, &self.mutex);
    }

    const n = self.count;
    const first_chunk = @min(n, BUF_SIZE - self.head);
    @memcpy(self.return_buf[0..first_chunk], self.event_buf[self.head..][0..first_chunk]);
    if (n > first_chunk) {
        @memcpy(self.return_buf[first_chunk..n], self.event_buf[0 .. n - first_chunk]);
    }

    self.head = 0;
    self.count = 0;
    return self.return_buf[0..n];
}

fn recordStart(recorder: *Self) void {
    if (c.XRecordEnableContext(recorder.data_display, recorder.ctx, recordCallback, @ptrCast(recorder)) == 0) {
        std.debug.print("XRecordEnableContext failed\n", .{});
    }
}

fn recordCallback(closure: c.XPointer, data_ptr: [*c]c.XRecordInterceptData) callconv(.c) void {
    defer _ = c.XRecordFreeData(data_ptr);

    const data: *c.XRecordInterceptData = data_ptr orelse return;
    const recorder: *Self = @ptrCast(@alignCast(closure));

    if (data.category != c.XRecordFromServer) return;
    if (data.data_len < 8) return;

    const ev: *c.xEvent = @ptrCast(@alignCast(data.data));
    const event_type: u8 = @intCast(ev.u.u.type & 0x7F);

    switch (event_type) {
        c.MotionNotify => recorder.pushEvent(.{ .motion = .{
            .x = @floatFromInt(ev.u.keyButtonPointer.rootX),
            .y = @floatFromInt(ev.u.keyButtonPointer.rootY),
            .state = @intCast(ev.u.keyButtonPointer.state),
        } }),
        c.ButtonPress => recorder.pushEvent(.button_press),
        else => {},
    }
}

fn pushEvent(self: *Self, event: Event) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    if (self.count < BUF_SIZE) {
        self.event_buf[(self.head + self.count) % BUF_SIZE] = event;
        self.count += 1;
    } else {
        self.event_buf[self.head] = event;
        self.head = (self.head + 1) % BUF_SIZE;
    }
    self.cond.signal(self.io);
}
