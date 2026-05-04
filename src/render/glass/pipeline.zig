const std = @import("std");
const c = @import("../../wl.zig").c;
const CairoBuffer = @import("../cairo_buffer.zig").CairoBuffer;
const WallpaperAsset = @import("../wallpaper.zig").WallpaperAsset;
const GlassStyle = @import("style.zig").GlassStyle;

pub fn renderBackdrop(
    allocator: std.mem.Allocator,
    wallpaper: ?*WallpaperAsset,
    output_box: c.struct_wlr_box,
    region_box: c.struct_wlr_box,
    style: GlassStyle,
) !*CairoBuffer {
    const width: u32 = @intCast(@max(region_box.width, 1));
    const height: u32 = @intCast(@max(region_box.height, 1));
    const buffer = try CairoBuffer.init(allocator, width, height);
    errdefer buffer.deinit();

    clear(buffer, 0.0, 0.0, 0.0, 0.0);
    applyClip(buffer.cr, width, height, style.corner_radius);

    if (wallpaper) |asset| {
        try renderScaledRegion(buffer, asset, output_box, region_box, style.downsample_factor);
    } else {
        fillFallback(buffer, style);
    }

    return buffer;
}

fn applyClip(cr: *c.cairo_t, width: u32, height: u32, radius: f32) void {
    const r = @min(
        @as(f64, radius),
        @min(@as(f64, @floatFromInt(width)), @as(f64, @floatFromInt(height))) / 2.0,
    );
    if (r <= 0.0) {
        c.cairo_rectangle(cr, 0, 0, @floatFromInt(width), @floatFromInt(height));
    } else {
        roundedRect(cr, 0, 0, @floatFromInt(width), @floatFromInt(height), r);
    }
    c.cairo_clip(cr);
    c.cairo_new_path(cr);
}

fn renderScaledRegion(
    target: *CairoBuffer,
    wallpaper: *WallpaperAsset,
    output_box: c.struct_wlr_box,
    region_box: c.struct_wlr_box,
    downsample_factor: u8,
) !void {
    const source_surface = c.cairo_image_surface_create_for_data(
        @constCast(wallpaper.pixelData().ptr),
        c.CAIRO_FORMAT_ARGB32,
        @intCast(wallpaper.width()),
        @intCast(wallpaper.height()),
        @intCast(wallpaper.stride()),
    ) orelse return error.GlassSourceSurfaceCreateFailed;
    defer c.cairo_surface_destroy(source_surface);
    if (c.cairo_surface_status(source_surface) != c.CAIRO_STATUS_SUCCESS) {
        return error.GlassSourceSurfaceCreateFailed;
    }

    const small_width = @max(@divFloor(target.width, @as(u32, @max(downsample_factor, 1))), 1);
    const small_height = @max(@divFloor(target.height, @as(u32, @max(downsample_factor, 1))), 1);
    const small = try CairoBuffer.init(target.allocator, small_width, small_height);
    defer small.deinit();

    clear(small, 0.0, 0.0, 0.0, 0.0);
    paintWallpaperRegion(small.cr, source_surface, wallpaper, output_box, region_box, small.width, small.height);
    c.cairo_surface_flush(small.surface);

    const blur_radius = @max(@as(usize, @intFromFloat(@ceil(@as(f32, @floatFromInt(@max(target.width, target.height))) * 0.0))), 0);
    _ = blur_radius;
    const effective_radius = @max(@as(usize, @intFromFloat(@ceil(@as(f32, @floatFromInt(@max(1, @divFloor(@as(i32, @intCast(target.height)), @as(i32, @intCast(@max(downsample_factor, 1))))))) * 0.18))), 2);
    try boxBlurArgb(target.allocator, small.pixels, small.width, small.height, small.stride, effective_radius);

    c.cairo_save(target.cr);
    defer c.cairo_restore(target.cr);
    c.cairo_scale(
        target.cr,
        @as(f64, @floatFromInt(target.width)) / @as(f64, @floatFromInt(small.width)),
        @as(f64, @floatFromInt(target.height)) / @as(f64, @floatFromInt(small.height)),
    );
    _ = c.cairo_set_source_surface(target.cr, small.surface, 0, 0);
    c.cairo_pattern_set_filter(c.cairo_get_source(target.cr), c.CAIRO_FILTER_BILINEAR);
    _ = c.cairo_paint(target.cr);
    c.cairo_surface_flush(target.surface);
}

fn paintWallpaperRegion(
    cr: *c.cairo_t,
    source_surface: *c.cairo_surface_t,
    wallpaper: *WallpaperAsset,
    output_box: c.struct_wlr_box,
    region_box: c.struct_wlr_box,
    dest_width: u32,
    dest_height: u32,
) void {
    if (output_box.width <= 0 or output_box.height <= 0) return;

    const scale_x = @as(f64, @floatFromInt(dest_width)) / @as(f64, @floatFromInt(region_box.width));
    const scale_y = @as(f64, @floatFromInt(dest_height)) / @as(f64, @floatFromInt(region_box.height));
    const output_scale_x = @as(f64, @floatFromInt(output_box.width)) / @as(f64, @floatFromInt(wallpaper.width()));
    const output_scale_y = @as(f64, @floatFromInt(output_box.height)) / @as(f64, @floatFromInt(wallpaper.height()));

    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_scale(cr, scale_x * output_scale_x, scale_y * output_scale_y);
    const offset_x = -@as(f64, @floatFromInt(region_box.x - output_box.x)) / output_scale_x;
    const offset_y = -@as(f64, @floatFromInt(region_box.y - output_box.y)) / output_scale_y;
    _ = c.cairo_set_source_surface(cr, source_surface, offset_x, offset_y);
    c.cairo_pattern_set_filter(c.cairo_get_source(cr), c.CAIRO_FILTER_BILINEAR);
    _ = c.cairo_paint(cr);
}

fn fillFallback(buffer: *CairoBuffer, style: GlassStyle) void {
    c.cairo_set_source_rgba(
        buffer.cr,
        style.tint_rgba[0],
        style.tint_rgba[1],
        style.tint_rgba[2],
        style.tint_rgba[3],
    );
    c.cairo_paint(buffer.cr);
    c.cairo_surface_flush(buffer.surface);
}

fn clear(buffer: *CairoBuffer, r: f64, g: f64, b: f64, a: f64) void {
    c.cairo_set_operator(buffer.cr, c.CAIRO_OPERATOR_SOURCE);
    c.cairo_set_source_rgba(buffer.cr, r, g, b, a);
    c.cairo_paint(buffer.cr);
    c.cairo_set_operator(buffer.cr, c.CAIRO_OPERATOR_OVER);
    c.cairo_surface_flush(buffer.surface);
}

fn roundedRect(cr: *c.cairo_t, x: f64, y: f64, width: f64, height: f64, radius: f64) void {
    const pi = std.math.pi;
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, x + width - radius, y + radius, radius, -pi / 2.0, 0);
    c.cairo_arc(cr, x + width - radius, y + height - radius, radius, 0, pi / 2.0);
    c.cairo_arc(cr, x + radius, y + height - radius, radius, pi / 2.0, pi);
    c.cairo_arc(cr, x + radius, y + radius, radius, pi, pi * 1.5);
    c.cairo_close_path(cr);
}

fn boxBlurArgb(
    allocator: std.mem.Allocator,
    pixels: []u8,
    width: u32,
    height: u32,
    stride: usize,
    radius: usize,
) !void {
    if (radius == 0 or width == 0 or height == 0) return;
    const temp = try allocator.alloc(u8, pixels.len);
    defer allocator.free(temp);

    @memcpy(temp, pixels);
    horizontalPass(pixels, temp, width, height, stride, radius);
    @memcpy(temp, pixels);
    verticalPass(pixels, temp, width, height, stride, radius);
}

fn horizontalPass(dst: []u8, src: []const u8, width: u32, height: u32, stride: usize, radius: usize) void {
    for (0..height) |y| {
        const row_start = @as(usize, y) * stride;
        for (0..width) |x| {
            var sum_a: usize = 0;
            var sum_r: usize = 0;
            var sum_g: usize = 0;
            var sum_b: usize = 0;
            var count: usize = 0;

            const min_x = x -| radius;
            const max_x = @min(x + radius, width - 1);
            var sample_x = min_x;
            while (sample_x <= max_x) : (sample_x += 1) {
                const idx = row_start + @as(usize, sample_x) * 4;
                sum_b += src[idx + 0];
                sum_g += src[idx + 1];
                sum_r += src[idx + 2];
                sum_a += src[idx + 3];
                count += 1;
            }

            const dst_idx = row_start + @as(usize, x) * 4;
            dst[dst_idx + 0] = @intCast(sum_b / count);
            dst[dst_idx + 1] = @intCast(sum_g / count);
            dst[dst_idx + 2] = @intCast(sum_r / count);
            dst[dst_idx + 3] = @intCast(sum_a / count);
        }
    }
}

fn verticalPass(dst: []u8, src: []const u8, width: u32, height: u32, stride: usize, radius: usize) void {
    for (0..height) |y| {
        for (0..width) |x| {
            var sum_a: usize = 0;
            var sum_r: usize = 0;
            var sum_g: usize = 0;
            var sum_b: usize = 0;
            var count: usize = 0;

            const min_y = y -| radius;
            const max_y = @min(y + radius, height - 1);
            var sample_y = min_y;
            while (sample_y <= max_y) : (sample_y += 1) {
                const idx = @as(usize, sample_y) * stride + @as(usize, x) * 4;
                sum_b += src[idx + 0];
                sum_g += src[idx + 1];
                sum_r += src[idx + 2];
                sum_a += src[idx + 3];
                count += 1;
            }

            const dst_idx = @as(usize, y) * stride + @as(usize, x) * 4;
            dst[dst_idx + 0] = @intCast(sum_b / count);
            dst[dst_idx + 1] = @intCast(sum_g / count);
            dst[dst_idx + 2] = @intCast(sum_r / count);
            dst[dst_idx + 3] = @intCast(sum_a / count);
        }
    }
}
