const std = @import("std");

const Self = @This();

time_window_ms: i64 = 1000,
min_distance_px: f64 = 3000.0,
min_flips: u32 = 4,
flip_dot_product_threshold: f64 = 0.5,
min_velocity_px_per_ms: f64 = 3.5,

samples: std.Deque(Sample),
allocator: std.mem.Allocator,
last_pos: ?Point = null,
last_time: i64 = 0,

pub const Point = struct {
    x: f64,
    y: f64,
};

pub const Sample = struct {
    timestamp: i64,
    duration_ms: i64,
    pos: Point,
    delta: Point,
};

pub fn init(allocator: std.mem.Allocator) !Self {
    return .{
        .allocator = allocator,
        .samples = try std.Deque(Sample).initCapacity(allocator, 64),
    };
}

pub fn deinit(self: *Self) void {
    self.samples.deinit(self.allocator);
}

pub fn reset(self: *Self) void {
    self.samples.len = 0;
    self.last_pos = null;
    self.last_time = 0;
}

pub fn addSample(self: *Self, x: f64, y: f64, timestamp_ms: i64) !bool {
    const current_pos = Point{ .x = x, .y = y };

    if (self.last_pos) |last| {
        try self.samples.pushBack(self.allocator, .{
            .timestamp = timestamp_ms,
            .duration_ms = timestamp_ms - self.last_time,
            .pos = current_pos,
            .delta = .{ .x = x - last.x, .y = y - last.y },
        });
    }

    self.last_pos = current_pos;
    self.last_time = timestamp_ms;
    self.cleanup(timestamp_ms);

    return self.isWiggling(timestamp_ms);
}

pub fn isWiggling(self: *const Self, current_time: i64) bool {
    const first_usable = self.firstUsable(current_time);
    if (first_usable == null) return false;

    var total_dist: f64 = 0;
    var total_time_ms: i64 = 0;
    var flips: u32 = 0;

    var last_delta: ?Point = null;
    var i: usize = 0;
    var it = self.samples.iterator();
    while (it.next()) |sample| : (i += 1) {
        if (i < first_usable.?) continue;

        const d = sample.delta;
        const dist = @sqrt(d.x * d.x + d.y * d.y);
        total_dist += dist;
        total_time_ms += sample.duration_ms;

        // Ignores micro-movements for flip detection
        if (dist > 1.0) {
            if (last_delta) |ld| {
                const ld_mag = @sqrt(ld.x * ld.x + ld.y * ld.y);
                if (ld_mag > 1.0) {
                    const dot = (ld.x * d.x + ld.y * d.y) / (ld_mag * dist);
                    if (dot < -self.flip_dot_product_threshold) {
                        flips += 1;
                    }
                }
            }
            last_delta = d;
        }
    }

    const velocity = if (total_time_ms > 0)
        total_dist / @as(f64, @floatFromInt(total_time_ms))
    else
        0;

    return total_dist >= self.min_distance_px and
        flips >= self.min_flips and
        velocity >= self.min_velocity_px_per_ms;
}

fn firstUsable(self: *const Self, current_time: i64) ?usize {
    const threshold = current_time - self.time_window_ms;

    var i: usize = 0;
    var it = self.samples.iterator();
    while (it.next()) |sample| : (i += 1) {
        if (sample.timestamp >= threshold) return i;
    }

    return null;
}

fn cleanup(self: *Self, current_time: i64) void {
    if (self.firstUsable(current_time)) |first_usable| {
        for (0..first_usable) |_| {
            _ = self.samples.popFront();
        }
    }
}

test "linear movement" {
    const allocator = std.testing.allocator;
    var detector = try Self.init(allocator);
    defer detector.deinit();

    detector.min_distance_px = 100;
    detector.min_flips = 3;

    var i: f64 = 0;
    while (i < 200) : (i += 10) {
        const is_wiggling = try detector.addSample(i, 0, @as(i64, @intFromFloat(i)));
        try std.testing.expect(!is_wiggling);
    }
}

test "zig-zag movement" {
    const allocator = std.testing.allocator;
    var detector = try Self.init(allocator);
    defer detector.deinit();

    detector.min_distance_px = 50;
    detector.min_flips = 3;
    detector.time_window_ms = 1000;

    _ = try detector.addSample(0, 0, 0);
    _ = try detector.addSample(50, 0, 10);
    _ = try detector.addSample(0, 0, 20);
    _ = try detector.addSample(50, 0, 30);
    const is_wiggling = try detector.addSample(0, 0, 40);
    try std.testing.expect(is_wiggling);
}

test "min velocity" {
    const allocator = std.testing.allocator;

    {
        var detector = try Self.init(allocator);
        defer detector.deinit();

        detector.min_distance_px = 50;
        detector.min_flips = 3;
        detector.time_window_ms = 1000;
        detector.min_velocity_px_per_ms = 2;

        // Move slowly (50px in 100ms)
        _ = try detector.addSample(0, 0, 0);
        _ = try detector.addSample(50, 0, 100);
        _ = try detector.addSample(0, 0, 200);
        _ = try detector.addSample(50, 0, 300);
        const is_wiggling = try detector.addSample(0, 0, 400);
        try std.testing.expect(!is_wiggling);
    }

    {
        var detector = try Self.init(allocator);
        defer detector.deinit();

        detector.min_distance_px = 50;
        detector.min_flips = 3;
        detector.time_window_ms = 1000;
        detector.min_velocity_px_per_ms = 2;

        // Move fast (50px in 10ms)
        _ = try detector.addSample(0, 0, 0);
        _ = try detector.addSample(50, 0, 10);
        _ = try detector.addSample(0, 0, 20);
        _ = try detector.addSample(50, 0, 30);
        const is_wiggling = try detector.addSample(0, 0, 40);
        try std.testing.expect(is_wiggling);
    }
}

test "window expiration" {
    const allocator = std.testing.allocator;
    var detector = try Self.init(allocator);
    defer detector.deinit();

    detector.min_distance_px = 50;
    detector.min_flips = 3;
    detector.time_window_ms = 1000;

    _ = try detector.addSample(0, 0, 0);
    _ = try detector.addSample(50, 0, 10);
    _ = try detector.addSample(0, 0, 20);
    _ = try detector.addSample(50, 0, 30);
    var is_wiggling = try detector.addSample(0, 0, 40);
    try std.testing.expect(is_wiggling);

    is_wiggling = try detector.addSample(0, 0, 1500);
    try std.testing.expect(!is_wiggling);
}
