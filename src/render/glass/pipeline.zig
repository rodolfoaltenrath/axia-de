const std = @import("std");
const c = @import("../../wl.zig").c;
const CairoBuffer = @import("../cairo_buffer.zig").CairoBuffer;
const WallpaperAsset = @import("../wallpaper.zig").WallpaperAsset;
const GlassStyle = @import("style.zig").GlassStyle;

pub const SceneBackdropContext = struct {
    scene_output: [*c]c.struct_wlr_scene_output,
    bottom_root: [*c]c.struct_wlr_scene_tree,
    window_root: [*c]c.struct_wlr_scene_tree,
};

pub fn renderBackdrop(
    allocator: std.mem.Allocator,
    wallpaper: ?*WallpaperAsset,
    output_box: c.struct_wlr_box,
    region_box: c.struct_wlr_box,
    style: GlassStyle,
    scene_backdrop: ?SceneBackdropContext,
) !*CairoBuffer {
    const width: u32 = @intCast(@max(region_box.width, 1));
    const height: u32 = @intCast(@max(region_box.height, 1));
    const buffer = try CairoBuffer.init(allocator, width, height);
    errdefer buffer.deinit();

    clear(buffer, 0.0, 0.0, 0.0, 0.0);
    applyClip(buffer.cr, width, height, style.corner_radius);

    if (wallpaper) |asset| {
        try renderScaledRegion(buffer, asset, output_box, region_box, style, scene_backdrop);
    } else {
        fillFallback(buffer, style);
    }

    applyGlassFinish(buffer, style);
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
    style: GlassStyle,
    scene_backdrop: ?SceneBackdropContext,
) !void {
    const sample_box = expandedBackdropBox(output_box, region_box, style);
    const downsample_factor = style.downsample_factor;
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

    const sample_width: u32 = @intCast(@max(sample_box.width, 1));
    const sample_height: u32 = @intCast(@max(sample_box.height, 1));
    const small_width = @max(@divFloor(sample_width, @as(u32, @max(downsample_factor, 1))), 1);
    const small_height = @max(@divFloor(sample_height, @as(u32, @max(downsample_factor, 1))), 1);
    const small = try CairoBuffer.init(target.allocator, small_width, small_height);
    defer small.deinit();

    clear(small, 0.0, 0.0, 0.0, 0.0);
    paintWallpaperRegion(small.cr, source_surface, wallpaper, output_box, sample_box, small.width, small.height);
    if (scene_backdrop) |context| {
        try paintSceneBuffers(
            target.allocator,
            small,
            sample_box,
            context,
        );
    }
    c.cairo_surface_flush(small.surface);

    const effective_radius = @max(
        @as(usize, @intFromFloat(@ceil(style.blur_radius / @as(f32, @floatFromInt(@max(downsample_factor, 1)))))),
        2,
    );
    const blur_passes = std.math.clamp(
        @as(u8, @intFromFloat(@ceil(style.blur_radius / 28.0))),
        1,
        3,
    );
    var pass_index: u8 = 0;
    while (pass_index < blur_passes) : (pass_index += 1) {
        try boxBlurArgb(target.allocator, small.pixels, small.width, small.height, small.stride, effective_radius);
    }

    c.cairo_save(target.cr);
    defer c.cairo_restore(target.cr);

    const crop_x = @as(f64, @floatFromInt(region_box.x - sample_box.x)) *
        (@as(f64, @floatFromInt(small.width)) / @as(f64, @floatFromInt(@max(sample_box.width, 1))));
    const crop_y = @as(f64, @floatFromInt(region_box.y - sample_box.y)) *
        (@as(f64, @floatFromInt(small.height)) / @as(f64, @floatFromInt(@max(sample_box.height, 1))));
    const crop_width = @as(f64, @floatFromInt(region_box.width)) *
        (@as(f64, @floatFromInt(small.width)) / @as(f64, @floatFromInt(@max(sample_box.width, 1))));
    const crop_height = @as(f64, @floatFromInt(region_box.height)) *
        (@as(f64, @floatFromInt(small.height)) / @as(f64, @floatFromInt(@max(sample_box.height, 1))));

    c.cairo_scale(
        target.cr,
        @as(f64, @floatFromInt(target.width)) / @max(crop_width, 1.0),
        @as(f64, @floatFromInt(target.height)) / @max(crop_height, 1.0),
    );
    _ = c.cairo_set_source_surface(target.cr, small.surface, -crop_x, -crop_y);
    c.cairo_pattern_set_filter(c.cairo_get_source(target.cr), c.CAIRO_FILTER_BILINEAR);
    _ = c.cairo_paint(target.cr);
    c.cairo_surface_flush(target.surface);
}

const ScenePaintContext = struct {
    allocator: std.mem.Allocator,
    target: *CairoBuffer,
    sample_box: c.struct_wlr_box,
    backdrop: SceneBackdropContext,
    failed: ?anyerror = null,
};

fn paintSceneBuffers(
    allocator: std.mem.Allocator,
    target: *CairoBuffer,
    sample_box: c.struct_wlr_box,
    backdrop: SceneBackdropContext,
) !void {
    var context = ScenePaintContext{
        .allocator = allocator,
        .target = target,
        .sample_box = sample_box,
        .backdrop = backdrop,
    };
    c.wlr_scene_output_for_each_buffer(backdrop.scene_output, iterateSceneBuffer, &context);
    if (context.failed) |err| return err;
}

fn iterateSceneBuffer(
    scene_buffer: [*c]c.struct_wlr_scene_buffer,
    sx: c_int,
    sy: c_int,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const raw_context = user_data orelse return;
    const context: *ScenePaintContext = @ptrCast(@alignCast(raw_context));
    if (context.failed != null) return;

    if (!bufferBelongsToBackdropRoots(scene_buffer, context.backdrop)) return;

    paintSingleSceneBuffer(context, scene_buffer, sx, sy) catch |err| {
        context.failed = err;
    };
}

fn bufferBelongsToBackdropRoots(
    scene_buffer: [*c]c.struct_wlr_scene_buffer,
    backdrop: SceneBackdropContext,
) bool {
    var tree = scene_buffer.*.node.parent;
    while (tree != null) {
        if (tree == backdrop.bottom_root or tree == backdrop.window_root) return true;
        tree = tree.*.node.parent;
    }
    return false;
}

fn paintSingleSceneBuffer(
    context: *ScenePaintContext,
    scene_buffer: [*c]c.struct_wlr_scene_buffer,
    sx: c_int,
    sy: c_int,
) !void {
    if (scene_buffer.*.texture == null) return;
    if (scene_buffer.*.opacity <= 0.001) return;

    const scene_surface = c.wlr_scene_surface_try_from_buffer(scene_buffer);
    if (scene_surface != null and scene_surface.?.*.surface != null and !scene_surface.?.*.surface.*.mapped) {
        return;
    }

    const dest_width: i32 = if (scene_buffer.*.dst_width > 0)
        scene_buffer.*.dst_width
    else
        @intCast(scene_buffer.*.texture.*.width);
    const dest_height: i32 = if (scene_buffer.*.dst_height > 0)
        scene_buffer.*.dst_height
    else
        @intCast(scene_buffer.*.texture.*.height);
    if (dest_width <= 0 or dest_height <= 0) return;

    const dest_box = c.struct_wlr_box{
        .x = sx,
        .y = sy,
        .width = dest_width,
        .height = dest_height,
    };
    if (!boxesIntersect(dest_box, context.sample_box)) return;

    const tex_width: u32 = scene_buffer.*.texture.*.width;
    const tex_height: u32 = scene_buffer.*.texture.*.height;
    if (tex_width == 0 or tex_height == 0) return;

    const stride: u32 = tex_width * 4;
    const pixel_count: usize = @as(usize, stride) * @as(usize, tex_height);
    const pixels = try context.allocator.alloc(u8, pixel_count);
    defer context.allocator.free(pixels);

    const read_options = c.struct_wlr_texture_read_pixels_options{
        .data = pixels.ptr,
        .format = c.DRM_FORMAT_ARGB8888,
        .stride = stride,
        .dst_x = 0,
        .dst_y = 0,
        .src_box = std.mem.zeroes(c.struct_wlr_box),
    };
    if (!c.wlr_texture_read_pixels(scene_buffer.*.texture, &read_options)) return;

    const surface = c.cairo_image_surface_create_for_data(
        pixels.ptr,
        c.CAIRO_FORMAT_ARGB32,
        @intCast(tex_width),
        @intCast(tex_height),
        @intCast(stride),
    ) orelse return;
    defer c.cairo_surface_destroy(surface);
    if (c.cairo_surface_status(surface) != c.CAIRO_STATUS_SUCCESS) return;

    const scale_x = @as(f64, @floatFromInt(dest_width)) / @as(f64, @floatFromInt(tex_width));
    const scale_y = @as(f64, @floatFromInt(dest_height)) / @as(f64, @floatFromInt(tex_height));
    const offset_x = @as(f64, @floatFromInt(dest_box.x - context.sample_box.x));
    const offset_y = @as(f64, @floatFromInt(dest_box.y - context.sample_box.y));

    c.cairo_save(context.target.cr);
    defer c.cairo_restore(context.target.cr);
    c.cairo_translate(context.target.cr, offset_x, offset_y);
    c.cairo_scale(context.target.cr, scale_x, scale_y);
    _ = c.cairo_set_source_surface(context.target.cr, surface, 0, 0);
    c.cairo_pattern_set_filter(c.cairo_get_source(context.target.cr), c.CAIRO_FILTER_BILINEAR);
    c.cairo_paint_with_alpha(context.target.cr, @floatCast(scene_buffer.*.opacity));
}

fn boxesIntersect(a: c.struct_wlr_box, b: c.struct_wlr_box) bool {
    const ax2 = a.x + a.width;
    const ay2 = a.y + a.height;
    const bx2 = b.x + b.width;
    const by2 = b.y + b.height;
    return a.x < bx2 and ax2 > b.x and a.y < by2 and ay2 > b.y;
}

fn expandedBackdropBox(
    output_box: c.struct_wlr_box,
    region_box: c.struct_wlr_box,
    style: GlassStyle,
) c.struct_wlr_box {
    var expanded = c.struct_wlr_box{
        .x = region_box.x - style.backdrop_overscan_x_px,
        .y = region_box.y - style.backdrop_overscan_top_px,
        .width = region_box.width + style.backdrop_overscan_x_px * 2,
        .height = region_box.height + style.backdrop_overscan_top_px + style.backdrop_overscan_bottom_px,
    };

    const output_x2 = output_box.x + output_box.width;
    const output_y2 = output_box.y + output_box.height;
    const expanded_x2 = expanded.x + expanded.width;
    const expanded_y2 = expanded.y + expanded.height;

    expanded.x = @max(expanded.x, output_box.x);
    expanded.y = @max(expanded.y, output_box.y);
    const clamped_x2 = @min(expanded_x2, output_x2);
    const clamped_y2 = @min(expanded_y2, output_y2);
    expanded.width = @max(clamped_x2 - expanded.x, region_box.width);
    expanded.height = @max(clamped_y2 - expanded.y, region_box.height);

    return expanded;
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

fn applyGlassFinish(buffer: *CairoBuffer, style: GlassStyle) void {
    const width = @as(f64, @floatFromInt(buffer.width));
    const height = @as(f64, @floatFromInt(buffer.height));
    const radius = @min(@as(f64, style.corner_radius), @min(width, height) / 2.0);

    applySaturation(buffer, style.saturation_boost);

    c.cairo_set_source_rgba(
        buffer.cr,
        style.tint_rgba[0],
        style.tint_rgba[1],
        style.tint_rgba[2],
        style.tint_rgba[3],
    );
    c.cairo_paint(buffer.cr);

    const top_gloss = c.cairo_pattern_create_linear(0, 0, 0, height * 0.55) orelse return;
    defer c.cairo_pattern_destroy(top_gloss);
    c.cairo_pattern_add_color_stop_rgba(top_gloss, 0.0, 1.0, 1.0, 1.0, @as(f64, style.highlight_rgba[3]) * 0.34);
    c.cairo_pattern_add_color_stop_rgba(top_gloss, 0.20, 0.97, 0.988, 1.0, @as(f64, style.highlight_rgba[3]) * 0.16);
    c.cairo_pattern_add_color_stop_rgba(top_gloss, 0.55, 0.91, 0.95, 1.0, 0.008);
    c.cairo_pattern_add_color_stop_rgba(top_gloss, 1.0, 0.88, 0.93, 0.99, 0.0);
    roundedRect(buffer.cr, 0, 0, width, height, radius);
    _ = c.cairo_set_source(buffer.cr, top_gloss);
    c.cairo_fill(buffer.cr);

    if (style.bottom_tone_alpha > 0.0005) {
        const bottom_tone = c.cairo_pattern_create_linear(0, height * 0.52, 0, height) orelse return;
        defer c.cairo_pattern_destroy(bottom_tone);
        c.cairo_pattern_add_color_stop_rgba(bottom_tone, 0.0, 0.60, 0.72, 0.86, 0.0);
        c.cairo_pattern_add_color_stop_rgba(bottom_tone, 1.0, 0.56, 0.68, 0.82, style.bottom_tone_alpha);
        roundedRect(buffer.cr, 0, 0, width, height, radius);
        _ = c.cairo_set_source(buffer.cr, bottom_tone);
        c.cairo_fill(buffer.cr);
    }

    roundedRect(buffer.cr, 0.5, 0.5, width - 1.0, height - 1.0, @max(radius - 0.5, 1.0));
    c.cairo_set_line_width(buffer.cr, 1.0);
    c.cairo_set_source_rgba(
        buffer.cr,
        style.border_rgba[0],
        style.border_rgba[1],
        style.border_rgba[2],
        style.border_rgba[3],
    );
    c.cairo_stroke(buffer.cr);

    roundedRect(buffer.cr, 1.5, 1.5, width - 3.0, height - 3.0, @max(radius - 1.5, 1.0));
    c.cairo_set_line_width(buffer.cr, 1.0);
    c.cairo_set_source_rgba(buffer.cr, 1.0, 1.0, 1.0, 0.015);
    c.cairo_stroke(buffer.cr);

    applyNoise(buffer, style.noise_opacity);
    c.cairo_surface_flush(buffer.surface);
}

fn applySaturation(buffer: *CairoBuffer, boost: f32) void {
    if (boost <= 1.001) return;

    var i: usize = 0;
    while (i + 3 < buffer.pixels.len) : (i += 4) {
        const b = @as(f32, @floatFromInt(buffer.pixels[i + 0]));
        const g = @as(f32, @floatFromInt(buffer.pixels[i + 1]));
        const r = @as(f32, @floatFromInt(buffer.pixels[i + 2]));
        const a = buffer.pixels[i + 3];
        if (a == 0) continue;

        const avg = (r + g + b) / 3.0;
        buffer.pixels[i + 0] = clampChannel(@intFromFloat(avg + (b - avg) * boost));
        buffer.pixels[i + 1] = clampChannel(@intFromFloat(avg + (g - avg) * boost));
        buffer.pixels[i + 2] = clampChannel(@intFromFloat(avg + (r - avg) * boost));
    }
}

fn applyNoise(buffer: *CairoBuffer, opacity: f32) void {
    if (opacity <= 0) return;

    var seed: u32 = 0xA5C1_93D7;
    var i: usize = 0;
    while (i + 3 < buffer.pixels.len) : (i += 4) {
        seed = seed *% 1664525 +% 1013904223;
        const noise = @as(i32, @intCast((seed >> 28) & 0x0F)) - 8;
        const delta = @as(i32, @intFromFloat(@as(f32, @floatFromInt(noise)) * opacity * 2.2));

        buffer.pixels[i + 0] = clampChannel(@as(i32, buffer.pixels[i + 0]) + delta);
        buffer.pixels[i + 1] = clampChannel(@as(i32, buffer.pixels[i + 1]) + delta);
        buffer.pixels[i + 2] = clampChannel(@as(i32, buffer.pixels[i + 2]) + delta);
    }
}

fn clampChannel(value: i32) u8 {
    return @intCast(std.math.clamp(value, 0, 255));
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
