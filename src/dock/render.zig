const std = @import("std");
const c = @import("wl.zig").c;
const dock_icons = @import("icons.zig");
const dock_ipc = @import("ipc.zig");
const dock_style = @import("style.zig");
const runtime_catalog = @import("runtime_catalog");

pub const Rect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,

    pub fn contains(self: Rect, px: f64, py: f64) bool {
        return px >= self.x and px <= self.x + self.width and py >= self.y and py <= self.y + self.height;
    }
};

pub fn containerRect(width: u32, height: u32, entries: []const runtime_catalog.AppEntry, style: dock_style.Style, offset_y: f64) Rect {
    const count = @max(entries.len, 1);
    const total_items_width = @as(f64, @floatFromInt(entries.len)) * style.item_size;
    const total_gap_width = @as(f64, @floatFromInt(count - 1)) * style.item_gap;
    const dock_width = style.padding_x * 2.0 + total_items_width + total_gap_width;
    const dock_height = style.dockHeight();
    return .{
        .x = (@as(f64, @floatFromInt(width)) - dock_width) / 2.0,
        .y = @as(f64, @floatFromInt(height)) - dock_height - style.bottom_margin + offset_y,
        .width = dock_width,
        .height = dock_height,
    };
}

pub fn itemRect(width: u32, height: u32, entries: []const runtime_catalog.AppEntry, style: dock_style.Style, offset_y: f64, index: usize) Rect {
    const container = containerRect(width, height, entries, style, offset_y);
    return .{
        .x = container.x + style.padding_x + @as(f64, @floatFromInt(index)) * (style.item_size + style.item_gap),
        .y = container.y + style.padding_y,
        .width = style.item_size,
        .height = style.item_size,
    };
}

pub fn hitTest(width: u32, height: u32, x: f64, y: f64, entries: []const runtime_catalog.AppEntry, style: dock_style.Style, offset_y: f64) ?usize {
    for (entries, 0..) |_, index| {
        if (itemRect(width, height, entries, style, offset_y, index).contains(x, y)) return index;
    }
    return null;
}

pub fn visibleContainerRect(width: u32, height: u32, entries: []const runtime_catalog.AppEntry, style: dock_style.Style, offset_y: f64) ?Rect {
    const rect = containerRect(width, height, entries, style, offset_y);
    const bounds = Rect{ .x = 0, .y = 0, .width = @floatFromInt(width), .height = @floatFromInt(height) };
    const x1 = @max(rect.x, bounds.x);
    const y1 = @max(rect.y, bounds.y);
    const x2 = @min(rect.x + rect.width, bounds.x + bounds.width);
    const y2 = @min(rect.y + rect.height, bounds.y + bounds.height);
    if (x2 <= x1 or y2 <= y1) return null;
    return .{
        .x = x1,
        .y = y1,
        .width = x2 - x1,
        .height = y2 - y1,
    };
}

pub fn drawDock(
    cr: *c.cairo_t,
    width: u32,
    height: u32,
    entries: []const runtime_catalog.AppEntry,
    open_apps: []const dock_ipc.OpenAppInfo,
    icons: *const dock_icons.IconCache,
    hovered_index: ?usize,
    style: dock_style.Style,
    offset_y: f64,
) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);

    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
    c.cairo_set_source_rgba(cr, 0, 0, 0, 0);
    c.cairo_paint(cr);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);

    const container = containerRect(width, height, entries, style, offset_y);
    const reveal = revealAmount(style, offset_y);
    const shadow_rect = Rect{
        .x = container.x + 2,
        .y = container.y + 4,
        .width = container.width - 4,
        .height = container.height,
    };
    if (reveal > 0.06) {
        drawRoundedRect(cr, shadow_rect, style.corner_radius);
        c.cairo_set_source_rgba(cr, 0.02, 0.03, 0.05, style.shadow_alpha * reveal * reveal);
        c.cairo_fill(cr);
    }

    drawRoundedRect(cr, container, style.corner_radius);
    c.cairo_set_source_rgba(cr, 0.096, 0.102, 0.128, lerp(style.shell_fill_alpha * 0.22, style.shell_fill_alpha, reveal));
    c.cairo_fill_preserve(cr);
    if (reveal > 0.18) {
        c.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.12 * reveal);
        c.cairo_set_line_width(cr, 1);
        c.cairo_stroke(cr);
    } else {
        c.cairo_new_path(cr);
    }

    if (reveal > 0.12) {
        drawRoundedRect(cr, container, style.corner_radius);
        c.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, style.shell_highlight_alpha * reveal);
        c.cairo_fill(cr);
    }

    for (entries, 0..) |entry, index| {
        const rect = itemRect(width, height, entries, style, offset_y, index);
        const hovered = hovered_index != null and hovered_index.? == index;
        const open_app = if (index < open_apps.len) open_apps[index] else dock_ipc.OpenAppInfo{};
        _ = entry.accent;
        drawDockItem(
            cr,
            rect,
            entry.monogram,
            icons.surfaceFor(index),
            hovered,
            open_app.id_len > 0,
            open_app.focused,
            style,
        );
    }
}

fn revealAmount(style: dock_style.Style, offset_y: f64) f64 {
    const max_offset = @max(style.hiddenOffset(), 0.001);
    const progress = std.math.clamp(offset_y / max_offset, 0.0, 1.0);
    return 1.0 - progress;
}

fn lerp(a: f64, b: f64, t: f64) f64 {
    return a + (b - a) * t;
}

fn drawDockItem(
    cr: *c.cairo_t,
    rect: Rect,
    monogram: []const u8,
    icon_surface: ?*c.cairo_surface_t,
    hovered: bool,
    is_open: bool,
    is_focused: bool,
    style: dock_style.Style,
) void {
    if (hovered or is_focused) {
        drawHoverButton(cr, .{
            .x = rect.x + 2.0,
            .y = rect.y + 1.5,
            .width = rect.width - 4.0,
            .height = rect.height - 3.0,
        }, hovered, is_focused, style);
    }

    const tile_size: f64 = style.icon_tile_size;
    const tile_rect = Rect{
        .x = rect.x + (rect.width - tile_size) / 2.0,
        .y = rect.y + (rect.height - tile_size) / 2.0,
        .width = tile_size,
        .height = tile_size,
    };

    if (icon_surface) |surface| {
        drawDockIcon(cr, tile_rect, surface, if (hovered or is_focused) 1.0 else 0.94);
        drawOpenIndicator(cr, rect, is_open, is_focused);
        return;
    }

    drawCenteredLabel(
        cr,
        tile_rect,
        if (monogram.len > 1) 14 else 18,
        monogram,
        if (hovered or is_focused) 1.0 else 0.94,
        if (hovered or is_focused) 1.0 else 0.95,
        if (hovered or is_focused) 1.0 else 0.96,
    );
    drawOpenIndicator(cr, rect, is_open, is_focused);
}

fn drawDockIcon(cr: *c.cairo_t, rect: Rect, surface: *c.cairo_surface_t, alpha: f64) void {
    const src_w = @as(f64, @floatFromInt(c.cairo_image_surface_get_width(surface)));
    const src_h = @as(f64, @floatFromInt(c.cairo_image_surface_get_height(surface)));
    if (src_w <= 0 or src_h <= 0) return;

    const scale = @min(rect.width / src_w, rect.height / src_h);
    const dest_w = src_w * scale;
    const dest_h = src_h * scale;
    const dest_x = rect.x + (rect.width - dest_w) / 2.0;
    const dest_y = rect.y + (rect.height - dest_h) / 2.0;

    c.cairo_save(cr);
    defer c.cairo_restore(cr);

    c.cairo_translate(cr, dest_x, dest_y);
    c.cairo_scale(cr, scale, scale);
    _ = c.cairo_set_source_surface(cr, surface, 0, 0);
    c.cairo_paint_with_alpha(cr, alpha);
}

fn drawHoverButton(cr: *c.cairo_t, rect: Rect, hovered: bool, is_focused: bool, style: dock_style.Style) void {
    drawRoundedRect(cr, rect, 8);
    if (is_focused and !hovered) {
        c.cairo_set_source_rgba(cr, 0.34, 0.23, 0.62, if (style.strong_hover) 0.14 else 0.08);
    } else {
        c.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, if (style.strong_hover) 0.045 else 0.024);
    }
    c.cairo_fill_preserve(cr);
    c.cairo_set_line_width(cr, 1);
    if (is_focused) {
        c.cairo_set_source_rgba(cr, 0.64, 0.49, 0.98, if (style.strong_hover) 0.24 else 0.16);
    } else {
        c.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, if (style.strong_hover) 0.042 else 0.026);
    }
    c.cairo_stroke(cr);
}

fn drawOpenIndicator(cr: *c.cairo_t, rect: Rect, is_open: bool, is_focused: bool) void {
    if (!is_open) return;

    if (is_focused) {
        c.cairo_arc(cr, rect.x + rect.width / 2.0, rect.y + rect.height - 4.8, 2.2, 0, std.math.tau);
        c.cairo_set_source_rgba(cr, 0.67, 0.49, 0.98, 0.98);
        c.cairo_fill(cr);
        return;
    }

    const line_width = rect.width - 14.0;
    const line_height = 3.0;
    const line_rect = Rect{
        .x = rect.x + (rect.width - line_width) / 2.0,
        .y = rect.y + rect.height - 5.6,
        .width = line_width,
        .height = line_height,
    };
    drawRoundedRect(cr, line_rect, 1.5);
    c.cairo_set_source_rgba(cr, 0.67, 0.49, 0.98, 0.64);
    c.cairo_fill(cr);
}

fn drawRoundedRect(cr: *c.cairo_t, rect: Rect, radius: f64) void {
    const right = rect.x + rect.width;
    const bottom = rect.y + rect.height;

    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, right - radius, rect.y + radius, radius, -std.math.pi / 2.0, 0);
    c.cairo_arc(cr, right - radius, bottom - radius, radius, 0, std.math.pi / 2.0);
    c.cairo_arc(cr, rect.x + radius, bottom - radius, radius, std.math.pi / 2.0, std.math.pi);
    c.cairo_arc(cr, rect.x + radius, rect.y + radius, radius, std.math.pi, 3.0 * std.math.pi / 2.0);
    c.cairo_close_path(cr);
}

fn drawCenteredLabel(cr: *c.cairo_t, rect: Rect, size: f64, text: []const u8, r: f64, g: f64, b: f64) void {
    var text_buf: [64]u8 = undefined;
    const c_text = toCString(&text_buf, text);
    var extents: c.cairo_text_extents_t = undefined;
    var font_extents: c.cairo_font_extents_t = undefined;
    c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_BOLD);
    c.cairo_set_font_size(cr, size);
    c.cairo_text_extents(cr, c_text.ptr, &extents);
    c.cairo_font_extents(cr, &font_extents);
    c.cairo_set_source_rgb(cr, r, g, b);
    c.cairo_move_to(
        cr,
        rect.x + (rect.width - extents.width) / 2.0 - extents.x_bearing,
        rect.y + (rect.height - font_extents.height) / 2.0 + font_extents.ascent,
    );
    c.cairo_show_text(cr, c_text.ptr);
}

fn toCString(buffer: []u8, text: []const u8) [:0]u8 {
    const max_len = @min(text.len, buffer.len - 1);
    @memcpy(buffer[0..max_len], text[0..max_len]);
    buffer[max_len] = 0;
    return buffer[0..max_len :0];
}
