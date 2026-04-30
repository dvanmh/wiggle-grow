const std = @import("std");
const c = @import("c");

pub fn resize(src: *c.XcursorImage, dst: *c.XcursorImage) void {
    const upscaling_x = dst.width > src.width;
    const upscaling_y = dst.height > src.height;
    if (upscaling_x or upscaling_y) {
        upscale(src, dst);
    } else {
        downscale(src, dst);
    }
}

/// Downscale src into dst using area averaging (box filter)
fn downscale(src: *c.XcursorImage, dst: *c.XcursorImage) void {
    const scale_x = @as(f32, @floatFromInt(src.width)) / @as(f32, @floatFromInt(dst.width));
    const scale_y = @as(f32, @floatFromInt(src.height)) / @as(f32, @floatFromInt(dst.height));

    for (0..dst.height) |out_y| {
        const src_y0 = @as(f32, @floatFromInt(out_y)) * scale_y;
        const src_y1 = @as(f32, @floatFromInt(out_y + 1)) * scale_y;
        const iy0: u32 = @intFromFloat(src_y0);
        const iy1: u32 = @min(@as(u32, @ceil(src_y1)), src.height);

        for (0..dst.width) |out_x| {
            const src_x0 = @as(f32, @floatFromInt(out_x)) * scale_x;
            const src_x1 = @as(f32, @floatFromInt(out_x + 1)) * scale_x;
            const ix0: u32 = @intFromFloat(src_x0);
            const ix1: u32 = @min(@as(u32, @ceil(src_x1)), src.width);

            var sum_a: f32 = 0;
            var sum_r: f32 = 0;
            var sum_g: f32 = 0;
            var sum_b: f32 = 0;
            var total_weight: f32 = 0;
            for (iy0..iy1) |sy| {
                const wy = @min(@as(f32, @floatFromInt(sy + 1)), src_y1) - @max(@as(f32, @floatFromInt(sy)), src_y0);
                for (ix0..ix1) |sx| {
                    const wx = @min(@as(f32, @floatFromInt(sx + 1)), src_x1) - @max(@as(f32, @floatFromInt(sx)), src_x0);
                    const w = wx * wy;

                    const px = getPixel(src, @intCast(sx), @intCast(sy));
                    sum_a += @as(f32, @floatFromInt((px >> 24) & 0xFF)) * w;
                    sum_r += @as(f32, @floatFromInt((px >> 16) & 0xFF)) * w;
                    sum_g += @as(f32, @floatFromInt((px >> 8) & 0xFF)) * w;
                    sum_b += @as(f32, @floatFromInt((px >> 0) & 0xFF)) * w;
                    total_weight += w;
                }
            }

            const a: u32 = @round(sum_a / total_weight);
            const r: u32 = @round(sum_r / total_weight);
            const g: u32 = @round(sum_g / total_weight);
            const b: u32 = @round(sum_b / total_weight);
            setPixel(dst, @intCast(out_x), @intCast(out_y), (a << 24) | (r << 16) | (g << 8) | b);
        }
    }
}

/// Upscale src into dst using bicubic interpolation
fn upscale(src: *c.XcursorImage, dst: *c.XcursorImage) void {
    const scale_x = @as(f32, @floatFromInt(src.width)) / @as(f32, @floatFromInt(dst.width));
    const scale_y = @as(f32, @floatFromInt(src.height)) / @as(f32, @floatFromInt(dst.height));

    for (0..dst.height) |out_y| {
        const sy = (@as(f32, @floatFromInt(out_y)) + 0.5) * scale_y - 0.5;
        for (0..dst.width) |out_x| {
            const sx = (@as(f32, @floatFromInt(out_x)) + 0.5) * scale_x - 0.5;
            setPixel(dst, @intCast(out_x), @intCast(out_y), sampleBicubic(src, sx, sy));
        }
    }
}

fn sampleBicubic(src: *c.XcursorImage, sx: f32, sy: f32) u32 {
    const x = @floor(sx);
    const y = @floor(sy);
    const fx = sx - x;
    const fy = sy - y;

    var sum_a: f32 = 0;
    var sum_r: f32 = 0;
    var sum_g: f32 = 0;
    var sum_b: f32 = 0;
    var total_weight: f32 = 0;
    for (0..4) |j| {
        const ky = cubicWeight(@abs(fy - @as(f32, @floatFromInt(j)) + 1.0));
        if (ky == 0) continue;

        const py: u32 = @intCast(std.math.clamp(
            @as(i64, @intFromFloat(y)) + @as(i64, @intCast(j)) - 1,
            0,
            @as(i64, @intCast(src.height - 1)),
        ));

        for (0..4) |i| {
            const kx = cubicWeight(@abs(fx - @as(f32, @floatFromInt(i)) + 1.0));
            if (kx == 0) continue;

            const px: u32 = @intCast(std.math.clamp(
                @as(i64, @intFromFloat(x)) + @as(i64, @intCast(i)) - 1,
                0,
                @as(i64, @intCast(src.width - 1)),
            ));

            const w = kx * ky;
            const pixel = getPixel(src, px, py);

            sum_a += @as(f32, @floatFromInt((pixel >> 24) & 0xFF)) * w;
            sum_r += @as(f32, @floatFromInt((pixel >> 16) & 0xFF)) * w;
            sum_g += @as(f32, @floatFromInt((pixel >> 8) & 0xFF)) * w;
            sum_b += @as(f32, @floatFromInt((pixel >> 0) & 0xFF)) * w;
            total_weight += w;
        }
    }

    // bicubic can produce out-of-range values at sharp edges
    const a: u32 = @round(std.math.clamp(sum_a / total_weight, 0, 255));
    const r: u32 = @round(std.math.clamp(sum_r / total_weight, 0, 255));
    const g: u32 = @round(std.math.clamp(sum_g / total_weight, 0, 255));
    const b: u32 = @round(std.math.clamp(sum_b / total_weight, 0, 255));

    return (a << 24) | (r << 16) | (g << 8) | b;
}

/// Cubic kernel (Catmull-Rom: b=0, c=0.5)
fn cubicWeight(t: f32) f32 {
    const a = -0.5;
    const t2 = t * t;
    const t3 = t2 * t;
    if (t < 1.0) {
        return (a + 2.0) * t3 - (a + 3.0) * t2 + 1.0;
    } else if (t < 2.0) {
        return a * t3 - 5.0 * a * t2 + 8.0 * a * t - 4.0 * a;
    }
    return 0.0;
}

fn getPixel(bmp: *c.XcursorImage, x: u32, y: u32) u32 {
    return bmp.pixels[y * bmp.width + x];
}

fn setPixel(bmp: *c.XcursorImage, x: u32, y: u32, color: u32) void {
    bmp.pixels[y * bmp.width + x] = color;
}
