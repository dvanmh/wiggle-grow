const std = @import("std");

const Self = @This();

x1: f32,
y1: f32,
x2: f32,
y2: f32,

pub fn eval(self: Self, x: f32) f32 {
    if (x < 0.0 or x > 1.0) @panic("Input out of range");

    var t = x;
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const xt = bezier1D(0.0, self.x1, self.x2, 1.0, t);
        const dxt = bezier1DDerivative(0.0, self.x1, self.x2, 1.0, t);

        if (@abs(dxt) < 1e-6) break;

        t -= (xt - x) / dxt;
        t = std.math.clamp(t, 0.0, 1.0);
    }

    return bezier1D(0.0, self.y1, self.y2, 1.0, t);
}

fn bezier1D(p0: f32, p1: f32, p2: f32, p3: f32, t: f32) f32 {
    const u = 1.0 - t;
    return u * u * u * p0 + 3.0 * u * u * t * p1 + 3.0 * u * t * t * p2 + t * t * t * p3;
}

fn bezier1DDerivative(p0: f32, p1: f32, p2: f32, p3: f32, t: f32) f32 {
    const u = 1.0 - t;
    return 3.0 * u * u * (p1 - p0) + 6.0 * u * t * (p2 - p1) + 3.0 * t * t * (p3 - p2);
}

pub const PRESETS = .{
    .linear = Self{ .x1 = 0.0, .y1 = 0.0, .x2 = 1.0, .y2 = 1.0 },
    .ease = Self{ .x1 = 0.25, .y1 = 0.1, .x2 = 0.25, .y2 = 1.0 },
    .easeIn = Self{ .x1 = 0.42, .y1 = 0.0, .x2 = 1.0, .y2 = 1.0 },
    .easeOut = Self{ .x1 = 0.0, .y1 = 0.0, .x2 = 0.58, .y2 = 1.0 },
    .easeInOut = Self{ .x1 = 0.42, .y1 = 0.0, .x2 = 0.58, .y2 = 1.0 },
    .easeInSine = Self{ .x1 = 0.12, .y1 = 0.0, .x2 = 0.39, .y2 = 0.0 },
    .easeOutSine = Self{ .x1 = 0.61, .y1 = 1.0, .x2 = 0.88, .y2 = 1.0 },
    .easeInOutSine = Self{ .x1 = 0.37, .y1 = 0.0, .x2 = 0.63, .y2 = 1.0 },
    .easeInQuad = Self{ .x1 = 0.11, .y1 = 0.0, .x2 = 0.5, .y2 = 0.0 },
    .easeOutQuad = Self{ .x1 = 0.5, .y1 = 1.0, .x2 = 0.89, .y2 = 1.0 },
    .easeInOutQuad = Self{ .x1 = 0.45, .y1 = 0.0, .x2 = 0.55, .y2 = 1.0 },
    .easeInCubic = Self{ .x1 = 0.32, .y1 = 0.0, .x2 = 0.67, .y2 = 0.0 },
    .easeOutCubic = Self{ .x1 = 0.33, .y1 = 1.0, .x2 = 0.68, .y2 = 1.0 },
    .easeInOutCubic = Self{ .x1 = 0.65, .y1 = 0.0, .x2 = 0.35, .y2 = 1.0 },
    .easeInExpo = Self{ .x1 = 0.7, .y1 = 0.0, .x2 = 0.84, .y2 = 0.0 },
    .easeOutExpo = Self{ .x1 = 0.16, .y1 = 1.0, .x2 = 0.3, .y2 = 1.0 },
    .easeInOutExpo = Self{ .x1 = 0.87, .y1 = 0.0, .x2 = 0.13, .y2 = 1.0 },
    .easeInCirc = Self{ .x1 = 0.55, .y1 = 0.0, .x2 = 1.0, .y2 = 0.45 },
    .easeOutCirc = Self{ .x1 = 0.0, .y1 = 0.55, .x2 = 0.45, .y2 = 1.0 },
    .easeInOutCirc = Self{ .x1 = 0.85, .y1 = 0.0, .x2 = 0.15, .y2 = 1.0 },
    .sharp = Self{ .x1 = 0.4, .y1 = 0.0, .x2 = 0.6, .y2 = 1.0 },
    .decelerate = Self{ .x1 = 0.0, .y1 = 0.0, .x2 = 0.2, .y2 = 1.0 },
    .accelerate = Self{ .x1 = 0.4, .y1 = 0.0, .x2 = 1.0, .y2 = 1.0 },
    .swift = Self{ .x1 = 0.55, .y1 = 0.0, .x2 = 0.1, .y2 = 1.0 },
};

pub fn getPreset(name: []const u8) ?Self {
    inline for (std.meta.fields(@TypeOf(PRESETS))) |field| {
        if (std.mem.eql(u8, name, field.name)) return @field(PRESETS, field.name);
    }
    return null;
}

const TEST_TOLERANCE = 1e-4;

test "CubicBezier eval" {
    const TestCase = struct {
        name: []const u8,
        samples: [6][2]f32,
    };

    const test_cases = [_]TestCase{
        .{ .name = "linear", .samples = .{
            .{ 0, 0 },
            .{ 0.2, 0.2 },
            .{ 0.4, 0.4 },
            .{ 0.6, 0.6 },
            .{ 0.8, 0.8 },
            .{ 1, 1 },
        } },
        .{ .name = "ease", .samples = .{
            .{ 0, 0 },
            .{ 0.2, 0.2952443343 },
            .{ 0.4, 0.682540506 },
            .{ 0.6, 0.8852293099 },
            .{ 0.8, 0.9756253556 },
            .{ 1, 1 },
        } },
        .{ .name = "easeIn", .samples = .{
            .{ 0, 0 },
            .{ 0.2, 0.0622820001 },
            .{ 0.4, 0.2148609388 },
            .{ 0.6, 0.4291197693 },
            .{ 0.8, 0.6916339333 },
            .{ 1, 1 },
        } },
        .{ .name = "easeOut", .samples = .{
            .{ 0, 0 },
            .{ 0.2, 0.3083660667 },
            .{ 0.4, 0.5708802307 },
            .{ 0.6, 0.7851390612 },
            .{ 0.8, 0.9377179999 },
            .{ 1, 1 },
        } },
        .{ .name = "easeInOut", .samples = .{
            .{ 0, 0 },
            .{ 0.2, 0.0816598563 },
            .{ 0.4, 0.3318838701 },
            .{ 0.6, 0.6681161299 },
            .{ 0.8, 0.9183401437 },
            .{ 1, 1 },
        } },
        .{ .name = "easeInSine", .samples = .{
            .{ 0, 0 },
            .{ 0.2, 0.0483188894 },
            .{ 0.4, 0.1977020656 },
            .{ 0.6, 0.4177972493 },
            .{ 0.8, 0.6891259433 },
            .{ 1, 1 },
        } },
        .{ .name = "easeOutSine", .samples = .{
            .{ 0, 0 },
            .{ 0.2, 0.3108740567 },
            .{ 0.4, 0.5822027507 },
            .{ 0.6, 0.8022979344 },
            .{ 0.8, 0.9516811106 },
            .{ 1, 1 },
        } },
        .{ .name = "easeInOutSine", .samples = .{
            .{ 0, 0 },
            .{ 0.2, 0.0941283343 },
            .{ 0.4, 0.344032016 },
            .{ 0.6, 0.655967984 },
            .{ 0.8, 0.9058716657 },
            .{ 1, 1 },
        } },
        .{ .name = "easeInQuad", .samples = .{
            .{ 0, 0 },
            .{ 0.2, 0.0382314713 },
            .{ 0.4, 0.1603901987 },
            .{ 0.6, 0.3616253527 },
            .{ 0.8, 0.6409320886 },
            .{ 1, 1 },
        } },
        .{ .name = "easeOutQuad", .samples = .{
            .{ 0, 0 },
            .{ 0.2, 0.3590679114 },
            .{ 0.4, 0.6383746473 },
            .{ 0.6, 0.8396098013 },
            .{ 0.8, 0.9617685287 },
            .{ 1, 1 },
        } },
        .{ .name = "easeInOutQuad", .samples = .{
            .{ 0, 0 },
            .{ 0.2, 0.0748051029 },
            .{ 0.4, 0.3238025096 },
            .{ 0.6, 0.6761974904 },
            .{ 0.8, 0.9251948971 },
            .{ 1, 1 },
        } },
        .{ .name = "easeInCubic", .samples = .{
            .{ 0, 0 },
            .{ 0.2, 0.0085958583 },
            .{ 0.4, 0.0663127042 },
            .{ 0.6, 0.2185663107 },
            .{ 0.8, 0.512 },
            .{ 1, 1 },
        } },
        .{ .name = "easeOutCubic", .samples = .{
            .{ 0, 0 },
            .{ 0.2, 0.488 },
            .{ 0.4, 0.7814336893 },
            .{ 0.6, 0.9336872958 },
            .{ 0.8, 0.9914041417 },
            .{ 1, 1 },
        } },
        .{ .name = "easeInOutCubic", .samples = .{
            .{ 0, 0 },
            .{ 0.2, 0.0415354835 },
            .{ 0.4, 0.2521159875 },
            .{ 0.6, 0.7478840125 },
            .{ 0.8, 0.9584645165 },
            .{ 1, 1 },
        } },
        .{ .name = "easeInExpo", .samples = .{
            .{ 0, 0 },
            .{ 0.2, 0.0011087818 },
            .{ 0.4, 0.0120350883 },
            .{ 0.6, 0.0602443969 },
            .{ 0.8, 0.2478739283 },
            .{ 1, 1 },
        } },
        .{ .name = "easeOutExpo", .samples = .{
            .{ 0, 0 },
            .{ 0.2, 0.7521260717 },
            .{ 0.4, 0.9397556031 },
            .{ 0.6, 0.9879649117 },
            .{ 0.8, 0.9988912182 },
            .{ 1, 1 },
        } },
        .{ .name = "easeInOutExpo", .samples = .{
            .{ 0, 0 },
            .{ 0.2, 0.0233525063 },
            .{ 0.4, 0.1549362925 },
            .{ 0.6, 0.8450637075 },
            .{ 0.8, 0.9766474937 },
            .{ 1, 1 },
        } },
        .{ .name = "easeInCirc", .samples = .{
            .{ 0, 0 },
            .{ 0.2, 0.0202295041 },
            .{ 0.4, 0.083973807 },
            .{ 0.6, 0.2013399483 },
            .{ 0.8, 0.4017806233 },
            .{ 1, 1 },
        } },
        .{ .name = "easeOutCirc", .samples = .{
            .{ 0, 0 },
            .{ 0.2, 0.5982193767 },
            .{ 0.4, 0.7986600517 },
            .{ 0.6, 0.916026193 },
            .{ 0.8, 0.9797704959 },
            .{ 1, 1 },
        } },
        .{ .name = "easeInOutCirc", .samples = .{
            .{ 0, 0 },
            .{ 0.2, 0.0245033001 },
            .{ 0.4, 0.1629553201 },
            .{ 0.6, 0.8370446799 },
            .{ 0.8, 0.9754966999 },
            .{ 1, 1 },
        } },
        .{ .name = "sharp", .samples = .{
            .{ 0, 0 },
            .{ 0.2, 0.0864972418 },
            .{ 0.4, 0.3369323879 },
            .{ 0.6, 0.6630676121 },
            .{ 0.8, 0.9135027582 },
            .{ 1, 1 },
        } },
        .{ .name = "decelerate", .samples = .{
            .{ 0, 0 },
            .{ 0.2, 0.5 },
            .{ 0.4, 0.7552628175 },
            .{ 0.6, 0.9021108962 },
            .{ 0.8, 0.9775593329 },
            .{ 1, 1 },
        } },
        .{ .name = "accelerate", .samples = .{
            .{ 0, 0 },
            .{ 0.2, 0.0661513741 },
            .{ 0.4, 0.2231667866 },
            .{ 0.6, 0.4388214826 },
            .{ 0.8, 0.6988430744 },
            .{ 1, 1 },
        } },
        .{ .name = "swift", .samples = .{
            .{ 0, 0 },
            .{ 0.2, 0.0715995012 },
            .{ 0.4, 0.6014665691 },
            .{ 0.6, 0.8937241478 },
            .{ 0.8, 0.9799316385 },
            .{ 1, 1 },
        } },
    };

    for (test_cases) |case| {
        for (case.samples) |sample| {
            std.testing.expectApproxEqAbs(
                sample[1],
                getPreset(case.name).?.eval(sample[0]),
                TEST_TOLERANCE,
            ) catch |e| {
                std.debug.print("Failed test case: {s} at x={d}\n", .{ case.name, sample[0] });
                return e;
            };
        }
    }
}

pub fn parse(str: []const u8) !Self {
    if (getPreset(str)) |p| return p;

    var parts = std.mem.splitScalar(u8, str, ',');
    const x1 = try parseSingleNum(&parts);
    const y1 = try parseSingleNum(&parts);
    const x2 = try parseSingleNum(&parts);
    const y2 = try parseSingleNum(&parts);

    if (parts.next() != null) return error.InvalidBezierString;

    return Self{ .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2 };
}

fn parseSingleNum(parts: *std.mem.SplitIterator(u8, .scalar)) !f32 {
    const part = parts.next() orelse return error.InvalidBezierString;
    return std.fmt.parseFloat(f32, part) catch return error.InvalidBezierString;
}

test "CubicBezier parse preset" {
    try std.testing.expectEqual(PRESETS.linear, try parse("linear"));
    try std.testing.expectEqual(PRESETS.ease, try parse("ease"));
    try std.testing.expectEqual(PRESETS.easeInOut, try parse("easeInOut"));
    try std.testing.expectEqual(PRESETS.sharp, try parse("sharp"));
}

test "CubicBezier parse custom" {
    {
        const custom = try parse("0.25,0.1,0.25,1.0");
        try std.testing.expectApproxEqAbs(0.25, custom.x1, TEST_TOLERANCE);
        try std.testing.expectApproxEqAbs(0.1, custom.y1, TEST_TOLERANCE);
        try std.testing.expectApproxEqAbs(0.25, custom.x2, TEST_TOLERANCE);
        try std.testing.expectApproxEqAbs(1.0, custom.y2, TEST_TOLERANCE);
    }
    {
        const custom = try parse("-0.5,0.1,1.2,0.9");
        try std.testing.expectApproxEqAbs(-0.5, custom.x1, TEST_TOLERANCE);
        try std.testing.expectApproxEqAbs(0.1, custom.y1, TEST_TOLERANCE);
        try std.testing.expectApproxEqAbs(1.2, custom.x2, TEST_TOLERANCE);
        try std.testing.expectApproxEqAbs(0.9, custom.y2, TEST_TOLERANCE);
    }
}

test "CubicBezier parse invalid" {
    try std.testing.expectError(error.InvalidBezierString, parse("0.25, 0.1, 0.25, 1.0"));
    try std.testing.expectError(error.InvalidBezierString, parse("0.25,0.1,0.25"));
    try std.testing.expectError(error.InvalidBezierString, parse("0.25,0.1,0.25,1.0,0.5"));
    try std.testing.expectError(error.InvalidBezierString, parse("0.25,foo,0.25,1.0"));
    try std.testing.expectError(error.InvalidBezierString, parse(""));
    try std.testing.expectError(error.InvalidBezierString, parse("unknown"));
}
