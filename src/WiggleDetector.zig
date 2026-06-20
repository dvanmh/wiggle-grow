const std = @import("std");

const Self = @This();

config: Config,
samples: std.Deque(Sample),
allocator: std.mem.Allocator,
last_pos: ?Point = null,
last_time: i64 = 0,

pub const Config = struct {
    time_window_ms: u32,
    min_distance_px: f32,
    min_flips: u32,
    min_velocity_px_per_ms: f32,
    min_maintain_velocity_px_per_ms: f32,
};

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

pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
    return .{
        .allocator = allocator,
        .config = config,
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

const Metrics = struct {
    total_dist: f64,
    total_flips: u32,
    velocity: f64,
};

fn computeMetrics(self: *const Self, current_time: i64) ?Metrics {
    const first_usable = self.firstUsable(current_time);
    if (first_usable == null) return null;

    var total_dist: f64 = 0;
    var total_time_ms: i64 = 0;
    var total_flips: u32 = 0;
    var rotation_acc: f64 = 0;

    var last_delta: ?Point = null;
    var i: usize = 0;
    var it = self.samples.iterator();
    while (it.next()) |sample| : (i += 1) {
        if (i < first_usable.?) continue;

        const d = sample.delta;
        const dist = @sqrt(d.x * d.x + d.y * d.y);
        total_dist += dist;
        total_time_ms += sample.duration_ms;

        // Ignores micro-movements for curvature detection
        if (dist > 1.0) {
            if (last_delta) |ld| {
                const ld_mag = @sqrt(ld.x * ld.x + ld.y * ld.y);
                if (ld_mag > 1.0) {
                    const dot = (ld.x * d.x + ld.y * d.y) / (ld_mag * dist);
                    const cross = (ld.x * d.y - ld.y * d.x) / (ld_mag * dist);

                    if (dot < -0.5) {
                        // Sharp turn (wiggling)

                        total_flips += 1;
                        rotation_acc = 0;
                    } else {
                        // Smooth turn (circling)

                        // One flip per around 180 degrees to account for sampling
                        const rotation_per_flip = std.math.pi * 0.98;
                        const turn_angle = std.math.atan2(cross, dot);
                        rotation_acc += turn_angle;
                        if (@abs(rotation_acc) >= rotation_per_flip) {
                            total_flips += 1;
                            if (rotation_acc > 0) {
                                rotation_acc -= rotation_per_flip;
                            } else {
                                rotation_acc += rotation_per_flip;
                            }
                        }
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

    return .{
        .total_dist = total_dist,
        .total_flips = total_flips,
        .velocity = velocity,
    };
}

pub fn isWiggling(self: *const Self, current_time: i64) bool {
    const metrics = self.computeMetrics(current_time) orelse return false;
    return metrics.total_dist >= self.config.min_distance_px and
        metrics.total_flips >= self.config.min_flips and
        metrics.velocity >= self.config.min_velocity_px_per_ms;
}

pub fn isStillWiggling(self: *const Self, current_time: i64) bool {
    const metrics = self.computeMetrics(current_time) orelse return false;
    return metrics.velocity >= self.config.min_maintain_velocity_px_per_ms;
}

fn firstUsable(self: *const Self, current_time: i64) ?usize {
    const threshold = current_time - self.config.time_window_ms;

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
    var detector = try Self.init(allocator, .{
        .time_window_ms = 750,
        .min_distance_px = 100,
        .min_flips = 3,
        .min_velocity_px_per_ms = 3.5,
        .min_maintain_velocity_px_per_ms = 3.5,
    });
    defer detector.deinit();

    var i: f64 = 0;
    while (i < 200) : (i += 10) {
        const is_wiggling = try detector.addSample(i, 0, @as(i64, @intFromFloat(i)));
        try std.testing.expect(!is_wiggling);
    }
}

test "wiggling movement" {
    const allocator = std.testing.allocator;
    var detector = try Self.init(allocator, .{
        .min_distance_px = 50,
        .min_flips = 3,
        .time_window_ms = 1000,
        .min_velocity_px_per_ms = 3.5,
        .min_maintain_velocity_px_per_ms = 3.5,
    });
    defer detector.deinit();

    _ = try detector.addSample(0, 0, 0);
    _ = try detector.addSample(50, 0, 10);
    _ = try detector.addSample(0, 0, 20);
    _ = try detector.addSample(50, 0, 30);
    const is_wiggling = try detector.addSample(0, 0, 40);
    try std.testing.expect(is_wiggling);
}

test "circling movement" {
    const allocator = std.testing.allocator;
    var detector = try Self.init(allocator, .{
        .min_distance_px = 50,
        .min_flips = 2,
        .time_window_ms = 2000,
        .min_velocity_px_per_ms = 0,
        .min_maintain_velocity_px_per_ms = 0,
    });
    defer detector.deinit();

    const radius = 50.0;
    const steps_per_lap = 20;

    var time_ms: i64 = 0;
    for (0..2) |_| {
        for (0..steps_per_lap) |s| {
            const angle = 2.0 * std.math.pi * @as(f64, @floatFromInt(s)) / steps_per_lap;
            const x = radius * @cos(angle);
            const y = radius * @sin(angle);
            _ = try detector.addSample(x, y, time_ms);
            time_ms += 10;
        }
    }

    const is_wiggling = try detector.addSample(radius, 0, time_ms);
    try std.testing.expect(is_wiggling);
}

test "mixed movement" {
    const allocator = std.testing.allocator;
    var detector = try Self.init(allocator, .{
        .time_window_ms = 750,
        .min_distance_px = 50,
        .min_flips = 2,
        .min_velocity_px_per_ms = 0,
        .min_maintain_velocity_px_per_ms = 0,
    });
    defer detector.deinit();

    // 1. One wiggle flip
    _ = try detector.addSample(0, 0, 0);
    _ = try detector.addSample(50, 0, 10);
    _ = try detector.addSample(0, 0, 20);

    // 2. Half circular lap
    const radius = 30.0;
    const steps = 10;
    for (0..steps) |s| {
        const angle = 2.0 * std.math.pi * @as(f64, @floatFromInt(s)) / steps;
        const x = radius * @cos(angle);
        const y = radius * @sin(angle);
        _ = try detector.addSample(x, y, 30 + @as(i64, @intCast(s)) * 10);
    }

    const is_wiggling = try detector.addSample(radius, 0, 300);
    try std.testing.expect(is_wiggling);
}

test "min velocity" {
    const allocator = std.testing.allocator;

    {
        var detector = try Self.init(allocator, .{
            .min_distance_px = 50,
            .min_flips = 3,
            .time_window_ms = 1000,
            .min_velocity_px_per_ms = 2,
            .min_maintain_velocity_px_per_ms = 2,
        });
        defer detector.deinit();

        // Move slowly (50px in 100ms)
        _ = try detector.addSample(0, 0, 0);
        _ = try detector.addSample(50, 0, 100);
        _ = try detector.addSample(0, 0, 200);
        _ = try detector.addSample(50, 0, 300);
        const is_wiggling = try detector.addSample(0, 0, 400);
        try std.testing.expect(!is_wiggling);
    }

    {
        var detector = try Self.init(allocator, .{
            .min_distance_px = 50,
            .min_flips = 3,
            .time_window_ms = 1000,
            .min_velocity_px_per_ms = 2,
            .min_maintain_velocity_px_per_ms = 2,
        });
        defer detector.deinit();

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
    var detector = try Self.init(allocator, .{
        .min_distance_px = 50,
        .min_flips = 3,
        .time_window_ms = 1000,
        .min_velocity_px_per_ms = 3.5,
        .min_maintain_velocity_px_per_ms = 3.5,
    });
    defer detector.deinit();

    _ = try detector.addSample(0, 0, 0);
    _ = try detector.addSample(50, 0, 10);
    _ = try detector.addSample(0, 0, 20);
    _ = try detector.addSample(50, 0, 30);
    var is_wiggling = try detector.addSample(0, 0, 40);
    try std.testing.expect(is_wiggling);

    is_wiggling = try detector.addSample(0, 0, 1500);
    try std.testing.expect(!is_wiggling);
}

test "isStillWiggling only checks maintain velocity" {
    const allocator = std.testing.allocator;
    var detector = try Self.init(allocator, .{
        .min_distance_px = 9999,
        .min_flips = 9999,
        .time_window_ms = 1000,
        .min_velocity_px_per_ms = 5,
        .min_maintain_velocity_px_per_ms = 1,
    });
    defer detector.deinit();

    // Slow movement doesn't meet distance/flips/velocity trigger, only maintain velocity
    _ = try detector.addSample(0, 0, 0);
    _ = try detector.addSample(50, 0, 20);
    _ = try detector.addSample(0, 0, 40);
    _ = try detector.addSample(50, 0, 60);
    _ = try detector.addSample(0, 0, 80);

    try std.testing.expect(!detector.isWiggling(80));
    try std.testing.expect(detector.isStillWiggling(80));
}
