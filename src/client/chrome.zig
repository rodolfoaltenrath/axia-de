const std = @import("std");
const c = @import("client_wl").c;

pub const window_margin = 4.0;
pub const window_radius = 16.0;
pub const titlebar_height = 46.0;
pub const attached_bottom_shadow = 10.0;

pub const Rect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,

    pub fn contains(self: Rect, px: f64, py: f64) bool {
        return px >= self.x and px <= self.x + self.width and py >= self.y and py <= self.y + self.height;
    }
};

pub const HoveredControl = enum {
    none,
    minimize,
    maximize,
    close,
};

const WindowControlKind = enum {
    minimize,
    maximize,
    close,
};

pub const TitlebarStyle = struct {
    title: []const u8,
    accent_glyph: []const u8 = "",
    accent_color: [3]f64 = .{ 0.40, 0.95, 1.0 },
    title_x: f64 = 54.0,
    attached_to_edges: bool = false,
};

pub fn rootRect(width: u32, height: u32) Rect {
    return rootRectStyled(width, height, false);
}

pub fn rootRectStyled(width: u32, height: u32, attached_to_edges: bool) Rect {
    if (attached_to_edges) {
        return .{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(width),
            .height = @max(1.0, @as(f64, @floatFromInt(height)) - attached_bottom_shadow),
        };
    }
    return .{
        .x = window_margin,
        .y = window_margin,
        .width = @as(f64, @floatFromInt(width)) - window_margin * 2.0,
        .height = @as(f64, @floatFromInt(height)) - window_margin * 2.0,
    };
}

pub fn titlebarRect(width: u32, height: u32) Rect {
    return titlebarRectStyled(width, height, false);
}

pub fn titlebarRectStyled(width: u32, height: u32, attached_to_edges: bool) Rect {
    const root = rootRectStyled(width, height, attached_to_edges);
    const inset = if (attached_to_edges) @as(f64, 0) else @as(f64, 1);
    return .{
        .x = root.x + inset,
        .y = root.y + inset,
        .width = root.width - inset * 2.0,
        .height = titlebar_height,
    };
}

pub fn contentRect(width: u32, height: u32, padding: f64) Rect {
    const root = rootRect(width, height);
    return .{
        .x = root.x + padding,
        .y = root.y + titlebar_height + padding,
        .width = root.width - padding * 2,
        .height = root.height - titlebar_height - padding * 2,
    };
}

pub fn titlebarDragRect(width: u32, height: u32, left_reserved: f64, right_reserved: f64) Rect {
    return titlebarDragRectStyled(width, height, left_reserved, right_reserved, false);
}

pub fn titlebarDragRectStyled(width: u32, height: u32, left_reserved: f64, right_reserved: f64, attached_to_edges: bool) Rect {
    const root = rootRectStyled(width, height, attached_to_edges);
    const drag_top_inset = if (attached_to_edges) @as(f64, 0) else @as(f64, 2);
    const drag_height_adjust = if (attached_to_edges) @as(f64, 0) else @as(f64, 4);
    return .{
        .x = root.x + left_reserved,
        .y = root.y + drag_top_inset,
        .width = root.width - left_reserved - right_reserved,
        .height = titlebar_height - drag_height_adjust,
    };
}

pub fn minimizeRect(width: u32) Rect {
    const right = @as(f64, @floatFromInt(width)) - 34;
    return .{ .x = right - 88, .y = 14, .width = 18, .height = 18 };
}

pub fn maximizeRect(width: u32) Rect {
    const right = @as(f64, @floatFromInt(width)) - 34;
    return .{ .x = right - 52, .y = 14, .width = 18, .height = 18 };
}

pub fn closeRect(width: u32) Rect {
    const right = @as(f64, @floatFromInt(width)) - 34;
    return .{ .x = right - 16, .y = 14, .width = 18, .height = 18 };
}

pub fn drawWindowShell(cr: *c.cairo_t, width: u32, height: u32, style: TitlebarStyle, hovered: HoveredControl) void {
    const root = rootRectStyled(width, height, style.attached_to_edges);
    if (style.attached_to_edges) {
        c.cairo_rectangle(cr, root.x, root.y, root.width, root.height);
        c.cairo_set_source_rgba(cr, 0.105, 0.105, 0.11, 0.99);
        c.cairo_fill(cr);
        drawAttachedBottomShadow(cr, width, height, root);
    } else {
        drawRoundedRect(cr, root, window_radius);
        c.cairo_set_source_rgba(cr, 0.105, 0.105, 0.11, 0.972);
        c.cairo_fill_preserve(cr);
        c.cairo_set_source_rgba(cr, 0.40, 0.95, 1.0, 0.95);
        c.cairo_set_line_width(cr, 2.0);
        c.cairo_stroke(cr);

        const inner = Rect{
            .x = root.x + 1.5,
            .y = root.y + 1.5,
            .width = root.width - 3.0,
            .height = root.height - 3.0,
        };
        drawRoundedRect(cr, inner, window_radius - 1.5);
        c.cairo_set_source_rgba(cr, 1, 1, 1, 0.04);
        c.cairo_set_line_width(cr, 1.0);
        c.cairo_stroke(cr);
    }

    const bar = titlebarRectStyled(width, height, style.attached_to_edges);
    if (style.attached_to_edges) {
        c.cairo_rectangle(cr, bar.x, bar.y, bar.width, bar.height);
    } else {
        drawTopRoundedRect(cr, bar, window_radius - 1.0);
    }
    c.cairo_set_source_rgba(cr, 0.11, 0.11, 0.115, 1.0);
    c.cairo_fill(cr);

    c.cairo_rectangle(cr, bar.x, bar.y + bar.height - 1, bar.width, 1);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.04);
    c.cairo_fill(cr);

    if (style.accent_glyph.len > 0) {
        drawAccentGlyph(cr, .{ .x = 26, .y = 17, .width = 18, .height = 18 }, style.accent_glyph, style.accent_color);
    }
    drawLabel(cr, style.title_x, 30, 15, style.title, 0.96, 0.97, 0.99, c.CAIRO_FONT_WEIGHT_BOLD);

    drawWindowControl(cr, minimizeRect(width), .minimize, hovered == .minimize);
    drawWindowControl(cr, maximizeRect(width), .maximize, hovered == .maximize);
    drawWindowControl(cr, closeRect(width), .close, hovered == .close);
}

fn drawAttachedBottomShadow(cr: *c.cairo_t, width: u32, height: u32, root: Rect) void {
    const surface_height = @as(f64, @floatFromInt(height));
    const shadow_top = root.y + root.height;
    const shadow_height = surface_height - shadow_top;
    if (shadow_height <= 0.5) return;

    const gradient = c.cairo_pattern_create_linear(0, shadow_top, 0, surface_height);
    defer c.cairo_pattern_destroy(gradient);
    c.cairo_pattern_add_color_stop_rgba(gradient, 0.0, 0.0, 0.0, 0.0, 0.34);
    c.cairo_pattern_add_color_stop_rgba(gradient, 0.42, 0.0, 0.0, 0.0, 0.18);
    c.cairo_pattern_add_color_stop_rgba(gradient, 1.0, 0.0, 0.0, 0.0, 0.0);
    c.cairo_rectangle(cr, 0, shadow_top, @floatFromInt(width), shadow_height);
    c.cairo_set_source(cr, gradient);
    c.cairo_fill(cr);
}

pub fn drawWindowControl(cr: *c.cairo_t, rect: Rect, kind: WindowControlKind, hovered: bool) void {
    if (hovered) {
        drawRoundedRect(cr, .{ .x = rect.x - 5, .y = rect.y - 4, .width = rect.width + 10, .height = rect.height + 8 }, 8);
        c.cairo_set_source_rgba(cr, if (kind == .close) 0.84 else 1.0, if (kind == .close) 0.30 else 1.0, if (kind == .close) 0.36 else 1.0, if (kind == .close) 0.14 else 0.065);
        c.cairo_fill_preserve(cr);
        c.cairo_set_line_width(cr, 1);
        c.cairo_set_source_rgba(cr, if (kind == .close) 0.96 else 1.0, if (kind == .close) 0.42 else 1.0, if (kind == .close) 0.48 else 1.0, if (kind == .close) 0.20 else 0.055);
        c.cairo_stroke(cr);
    }
    drawControlIcon(cr, rect, kind, hovered);
}

pub fn drawAccentGlyph(cr: *c.cairo_t, rect: Rect, glyph: []const u8, color: [3]f64) void {
    drawRoundedRect(cr, .{ .x = rect.x - 4, .y = rect.y - 4, .width = rect.width + 8, .height = rect.height + 8 }, 10);
    c.cairo_set_source_rgba(cr, color[0], color[1], color[2], 0.14);
    c.cairo_fill(cr);
    drawCenteredLabel(cr, rect, 13, glyph, color[0], color[1], color[2]);
}

pub fn drawRoundedRect(cr: *c.cairo_t, rect: Rect, radius: f64) void {
    const right = rect.x + rect.width;
    const bottom = rect.y + rect.height;
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, right - radius, rect.y + radius, radius, -std.math.pi / 2.0, 0);
    c.cairo_arc(cr, right - radius, bottom - radius, radius, 0, std.math.pi / 2.0);
    c.cairo_arc(cr, rect.x + radius, bottom - radius, radius, std.math.pi / 2.0, std.math.pi);
    c.cairo_arc(cr, rect.x + radius, rect.y + radius, radius, std.math.pi, 3.0 * std.math.pi / 2.0);
    c.cairo_close_path(cr);
}

pub fn drawTopRoundedRect(cr: *c.cairo_t, rect: Rect, radius: f64) void {
    const right = rect.x + rect.width;
    const bottom = rect.y + rect.height;
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, right - radius, rect.y + radius, radius, -std.math.pi / 2.0, 0);
    c.cairo_line_to(cr, right, bottom);
    c.cairo_line_to(cr, rect.x, bottom);
    c.cairo_line_to(cr, rect.x, rect.y + radius);
    c.cairo_arc(cr, rect.x + radius, rect.y + radius, radius, std.math.pi, 3.0 * std.math.pi / 2.0);
    c.cairo_close_path(cr);
}

fn drawControlIcon(cr: *c.cairo_t, rect: Rect, kind: WindowControlKind, hovered: bool) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);

    c.cairo_set_line_width(cr, if (kind == .minimize) 1.8 else 1.55);
    c.cairo_set_line_cap(cr, c.CAIRO_LINE_CAP_ROUND);
    c.cairo_set_line_join(cr, c.CAIRO_LINE_JOIN_ROUND);
    c.cairo_set_source_rgba(
        cr,
        if (kind == .close and hovered) 0.99 else 0.88,
        if (kind == .close and hovered) 0.94 else 0.90,
        if (kind == .close and hovered) 0.96 else 0.94,
        0.98,
    );

    const cx = rect.x + rect.width / 2.0;
    const cy = rect.y + rect.height / 2.0;
    switch (kind) {
        .minimize => {
            c.cairo_move_to(cr, cx - 4.5, cy + 3.0);
            c.cairo_line_to(cr, cx + 4.5, cy + 3.0);
            c.cairo_stroke(cr);
        },
        .maximize => {
            drawRoundedRect(cr, .{ .x = cx - 4.7, .y = cy - 4.2, .width = 9.4, .height = 8.4 }, 2.3);
            c.cairo_stroke(cr);
        },
        .close => {
            c.cairo_move_to(cr, cx - 4.0, cy - 4.0);
            c.cairo_line_to(cr, cx + 4.0, cy + 4.0);
            c.cairo_move_to(cr, cx + 4.0, cy - 4.0);
            c.cairo_line_to(cr, cx - 4.0, cy + 4.0);
            c.cairo_stroke(cr);
        },
    }
}

pub fn drawLabel(cr: *c.cairo_t, x: f64, y: f64, size: f64, text: []const u8, r: f64, g: f64, b: f64, weight: u32) void {
    var text_buf: [256]u8 = undefined;
    const max_len = @min(text.len, text_buf.len - 1);
    @memcpy(text_buf[0..max_len], text[0..max_len]);
    text_buf[max_len] = 0;
    c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, weight);
    c.cairo_set_font_size(cr, size);
    c.cairo_set_source_rgb(cr, r, g, b);
    c.cairo_move_to(cr, x, y);
    c.cairo_show_text(cr, text_buf[0..max_len :0].ptr);
}

pub fn drawCenteredLabel(cr: *c.cairo_t, rect: Rect, size: f64, text: []const u8, r: f64, g: f64, b: f64) void {
    var text_buf: [128]u8 = undefined;
    const max_len = @min(text.len, text_buf.len - 1);
    @memcpy(text_buf[0..max_len], text[0..max_len]);
    text_buf[max_len] = 0;

    var extents: c.cairo_text_extents_t = undefined;
    var font_extents: c.cairo_font_extents_t = undefined;
    c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
    c.cairo_set_font_size(cr, size);
    c.cairo_text_extents(cr, text_buf[0..max_len :0].ptr, &extents);
    c.cairo_font_extents(cr, &font_extents);
    c.cairo_set_source_rgb(cr, r, g, b);
    c.cairo_move_to(
        cr,
        rect.x + (rect.width - extents.width) / 2.0 - extents.x_bearing,
        rect.y + (rect.height - font_extents.height) / 2.0 + font_extents.ascent,
    );
    c.cairo_show_text(cr, text_buf[0..max_len :0].ptr);
}
