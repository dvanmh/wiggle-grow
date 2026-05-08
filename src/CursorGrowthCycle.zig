const std = @import("std");
const c = @import("c");
const WiggleDetector = @import("WiggleDetector.zig");
const Io = std.Io;

const Self = @This();

pub const AnimationType = enum { grow, shrink };

pub const Actions = struct {
    onBeforeGrow: *const fn (ctx: *anyopaque) anyerror!void,
    onAfterShrink: *const fn (ctx: *anyopaque) anyerror!void,
    onAnimate: *const fn (ctx: *anyopaque, frame_idx: usize, anim_type: AnimationType) anyerror!void,
    onMotion: ?*const fn (ctx: *anyopaque, x: f64, y: f64) anyerror!void = null,
};

pub const Displayer = struct {
    actions: Actions,
    ctx: *anyopaque,
    deinit: *const fn (ctx: *anyopaque) void,
};

pub const Config = struct {
    grow_frame_count: usize,
    shrink_frame_count: usize,
    hold_duration_ms: u32,
    time_between_frame_ns: u64,
};

wiggle_detector: *WiggleDetector,
displayer: Displayer,
config: Config,

future_finished: bool = true,
future_canceling: bool = false,
last_wiggle_tracking_future_finished: bool = true,
future: Io.Future(@typeInfo(@TypeOf(runAnimation)).@"fn".return_type.?) = undefined,

pub fn init(wiggle_detector: *WiggleDetector, displayer: Displayer, config: Config) Self {
    return .{
        .wiggle_detector = wiggle_detector,
        .displayer = displayer,
        .config = config,
    };
}

pub fn run(self: *Self, io: Io, display: *c.Display, xi_opcode: i32) !void {
    defer if (!self.future_finished) self.future.cancel(io) catch {};

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

                const any_buttons_held = blk: for (0..@intCast(raw_event.buttons.mask_len)) |i| {
                    if (raw_event.buttons.mask[i >> 3] & (@as(u8, 1) << @as(u3, @intCast(i & 7))) != 0) {
                        break :blk true;
                    }
                } else false;

                try self.handleMotion(io, x, y, any_buttons_held);
            }

            if (cookie.evtype == c.XI_ButtonPress) {
                self.handleButtonPress(io);
            }
        }
    }
}

fn handleMotion(self: *Self, io: Io, x: f64, y: f64, any_buttons_held: bool) !void {
    const now_ms = Io.Timestamp.now(io, .awake).toMilliseconds();

    // Resets wiggle_detector after each cursor growing cycle so user cannot trigger
    // cursor growing too many times in a short period
    if (!self.last_wiggle_tracking_future_finished and self.future_finished) {
        self.wiggle_detector.reset();
    }
    const is_wiggling = try self.wiggle_detector.addSample(x, y, now_ms);
    self.last_wiggle_tracking_future_finished = self.future_finished;

    if (!any_buttons_held and is_wiggling and self.future_finished) {
        self.future_finished = false;
        self.future = io.async(runAnimation, .{ self, io });
    }

    if (!self.future_finished) {
        if (self.displayer.actions.onMotion) |onMotion| {
            try onMotion(self.displayer.ctx, x, y);
        }
    }
}

fn handleButtonPress(self: *Self, io: Io) void {
    if (!self.future_finished and !self.future_canceling) {
        self.future_canceling = true;
        _ = io.async(cancelFuture, .{ io, self });
    }
}

fn cancelFuture(io: std.Io, self: *Self) void {
    defer self.future_canceling = false;
    _ = self.future.cancel(io) catch {};
}

fn runAnimation(self: *Self, io: Io) !void {
    defer self.future_finished = true;

    try self.displayer.actions.onBeforeGrow(self.displayer.ctx);
    defer self.displayer.actions.onAfterShrink(self.displayer.ctx) catch {};

    var animated_frame_idx: usize = 0;
    animateLoop(
        io,
        self.displayer.actions,
        self.displayer.ctx,
        self.config.grow_frame_count,
        .grow,
        self.config.time_between_frame_ns,
        false,
        false,
        &animated_frame_idx,
    ) catch |e| switch (e) {
        error.Canceled => {
            if (animated_frame_idx > 0) {
                // Plays the grow animation in reverse because the shrink animation can be
                // different in duration and bezier curve, ruining the transition
                try animateLoop(
                    io,
                    self.displayer.actions,
                    self.displayer.ctx,
                    animated_frame_idx,
                    .grow,
                    self.config.time_between_frame_ns,
                    true,
                    true,
                    null,
                );
            }
            return;
        },
        else => return e,
    };

    stayGrown(io, self.wiggle_detector, self.config.hold_duration_ms) catch |e| switch (e) {
        error.Canceled => {}, // Shrinks immediately when being canceled
    };

    try animateLoop(
        io,
        self.displayer.actions,
        self.displayer.ctx,
        self.config.shrink_frame_count,
        .shrink,
        self.config.time_between_frame_ns,
        true,
        true,
        null,
    );
}

fn animateLoop(
    io: Io,
    actions: Actions,
    ctx: *anyopaque,
    frame_count: usize,
    anim_type: AnimationType,
    time_between_frame_ns: u64,
    in_reverse: bool,
    force_sleep: bool,
    animated_frame_idx: ?*usize,
) !void {
    if (frame_count == 0) return;

    const start_time = Io.Timestamp.now(io, .awake);
    const total_duration_ns = frame_count * time_between_frame_ns;

    var last_frame_idx: ?usize = null;
    while (true) {
        const now = Io.Timestamp.now(io, .awake);
        const elapsed_ns: u64 = @intCast(start_time.durationTo(now).nanoseconds);
        if (elapsed_ns >= total_duration_ns) break;

        const frame_idx: usize = @intCast(elapsed_ns / time_between_frame_ns);
        if (last_frame_idx == null or last_frame_idx.? != frame_idx) {
            const idx = if (in_reverse) frame_count - 1 - frame_idx else frame_idx;
            try actions.onAnimate(ctx, idx, anim_type);
            if (animated_frame_idx) |af| af.* = frame_idx;
            last_frame_idx = frame_idx;
        }

        const next_deadline_ns = (frame_idx + 1) * time_between_frame_ns;
        if (next_deadline_ns > elapsed_ns) {
            const sleep_ns = next_deadline_ns - elapsed_ns;
            io.sleep(.fromNanoseconds(sleep_ns), .awake) catch |e| switch (e) {
                error.Canceled => if (force_sleep) {
                    try io.sleep(.fromNanoseconds(sleep_ns), .awake);
                } else {
                    return e;
                },
            };
        }
    }

    // Ensures the final frame is displayed
    const final_frame_idx = frame_count - 1;
    if (last_frame_idx == null or last_frame_idx.? != final_frame_idx) {
        const idx = if (in_reverse) 0 else final_frame_idx;
        try actions.onAnimate(ctx, idx, anim_type);
        if (animated_frame_idx) |af| af.* = final_frame_idx;
    }
}

fn stayGrown(io: Io, wiggle_detector: *const WiggleDetector, stay_grown_duration_ms: u32) !void {
    var sleep_time_left_ms: i64 = stay_grown_duration_ms;
    var last_pos = wiggle_detector.last_pos;
    while (wiggle_detector.isWiggling(Io.Timestamp.now(io, .awake).toMilliseconds())) {
        try io.sleep(.fromMilliseconds(10), .awake);

        const current_pos = wiggle_detector.last_pos;
        if (std.meta.eql(last_pos, current_pos)) {
            sleep_time_left_ms -= 10;
        } else {
            sleep_time_left_ms = stay_grown_duration_ms;
        }

        if (sleep_time_left_ms <= 0) {
            break;
        }

        last_pos = current_pos;
    }
    if (sleep_time_left_ms > 0) try io.sleep(.fromMilliseconds(sleep_time_left_ms), .awake);
}
