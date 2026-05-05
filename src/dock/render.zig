const std = @import("std");
const c = @import("wl.zig").c;
const dock_icons = @import("icons.zig");
const dock_ipc = @import("ipc.zig");
const dock_style = @import("style.zig");
const runtime_catalog = @import("runtime_catalog");

const dock_separator_width = 1.25;
const dock_separator_gap_multiplier = 1.25;

pub const Rect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,

    pub fn contains(self: Rect, px: f64, py: f64) bool {
        return px >= self.x and px <= self.x + self.width and py >= self.y and py <= self.y + self.height;
    }
};

pub const HitTarget = union(enum) {
    none,
    app: usize,
    all_apps,
};

pub const ContextMenuAction = enum {
    none,
    toggle_pin,
};

pub const ContextMenu = struct {
    item_index: usize,
    pinned: bool,
};

pub fn containerRect(width: u32, height: u32, item_count: usize, style: dock_style.Style, offset_y: f64) Rect {
    const count = @max(item_count, 1);
    const total_items_width = @as(f64, @floatFromInt(item_count)) * style.item_size;
    const total_gap_width = @as(f64, @floatFromInt(count - 1)) * style.item_gap;
    const dock_width = style.padding_x * 2.0 + total_items_width + total_gap_width + separatorExtraWidth(item_count, style);
    const dock_height = style.dockHeight();
    return .{
        .x = (@as(f64, @floatFromInt(width)) - dock_width) / 2.0,
        .y = @as(f64, @floatFromInt(height)) - dock_height - style.bottom_margin + offset_y,
        .width = dock_width,
        .height = dock_height,
    };
}

pub fn itemRect(width: u32, height: u32, item_count: usize, style: dock_style.Style, offset_y: f64, index: usize) Rect {
    const container = containerRect(width, height, item_count, style, offset_y);
    const separator_offset = if (isAllAppsIndex(item_count, index)) separatorExtraWidth(item_count, style) else 0.0;
    return .{
        .x = container.x + style.padding_x + @as(f64, @floatFromInt(index)) * (style.item_size + style.item_gap) + separator_offset,
        .y = container.y + style.padding_y,
        .width = style.item_size,
        .height = style.item_size,
    };
}

pub fn hitTest(width: u32, height: u32, x: f64, y: f64, entries: []const runtime_catalog.AppEntry, style: dock_style.Style, offset_y: f64) HitTarget {
    const total_items = entries.len + 1;
    for (entries, 0..) |_, index| {
        if (itemRect(width, height, total_items, style, offset_y, index).contains(x, y)) return .{ .app = index };
    }
    if (itemRect(width, height, total_items, style, offset_y, entries.len).contains(x, y)) return .all_apps;
    return .none;
}

pub fn visibleContainerRect(width: u32, height: u32, item_count: usize, style: dock_style.Style, offset_y: f64) ?Rect {
    const rect = containerRect(width, height, item_count, style, offset_y);
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
    all_apps_hovered: bool,
    all_apps_open: bool,
    style: dock_style.Style,
    offset_y: f64,
    context_menu: ?ContextMenu,
    drag_insert_index: ?usize,
    favorite_count: usize,
) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);

    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
    c.cairo_set_source_rgba(cr, 0, 0, 0, 0);
    c.cairo_paint(cr);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);

    const total_items = entries.len + 1;

    for (entries, 0..) |entry, index| {
        const rect = itemRect(width, height, total_items, style, offset_y, index);
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

    if (drag_insert_index) |insert_index| {
        drawInsertionMarker(cr, width, height, total_items, style, offset_y, insert_index);
    }

    drawDockSeparator(cr, width, height, total_items, style, offset_y);

    drawAllAppsButton(
        cr,
        itemRect(width, height, total_items, style, offset_y, entries.len),
        all_apps_hovered,
        all_apps_open,
        style,
    );

    if (context_menu) |menu| {
        drawContextMenu(cr, width, height, total_items, style, offset_y, menu, favorite_count);
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

fn isAllAppsIndex(item_count: usize, index: usize) bool {
    return item_count > 1 and index == item_count - 1;
}

fn separatorExtraWidth(item_count: usize, style: dock_style.Style) f64 {
    if (item_count <= 1) return 0.0;
    return style.item_gap * dock_separator_gap_multiplier * 2.0 + dock_separator_width;
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
        drawHoverButton(cr, hoverButtonRect(rect, style), hovered, is_focused, style);
    }

    const tile_size: f64 = style.icon_tile_size;
    const tile_rect = Rect{
        .x = rect.x + (rect.width - tile_size) / 2.0,
        .y = rect.y + (rect.height - tile_size) / 2.0,
        .width = tile_size,
        .height = tile_size,
    };

    if (icon_surface) |surface| {
        drawDockIcon(cr, tile_rect, surface, if (hovered or is_focused) 1.0 else 0.97);
        drawOpenIndicator(cr, rect, is_open, is_focused);
        return;
    }

    drawFallbackMonogram(cr, tile_rect, monogram);
    drawOpenIndicator(cr, rect, is_open, is_focused);
}

pub fn drawFallbackMonogram(cr: *c.cairo_t, rect: Rect, monogram: []const u8) void {
    drawCenteredLabel(cr, rect, if (monogram.len > 1) 14 else 18, monogram, 0.94, 0.95, 0.96);
}

fn drawAllAppsButton(cr: *c.cairo_t, rect: Rect, hovered: bool, open: bool, style: dock_style.Style) void {
    if (hovered or open) {
        drawHoverButton(cr, hoverButtonRect(rect, style), hovered, open, style);
    }

    const dot_color = if (hovered or open)
        [4]f64{ 0.98, 0.99, 1.0, 0.98 }
    else
        [4]f64{ 0.94, 0.95, 0.97, 0.92 };
    const dot_gap = 7.9;
    const dot_radius = 2.1;
    const start_x = rect.x + rect.width / 2.0 - dot_gap;
    const start_y = rect.y + rect.height / 2.0 - dot_gap;
    for (0..3) |row| {
        for (0..3) |col| {
            c.cairo_arc(
                cr,
                start_x + @as(f64, @floatFromInt(col)) * dot_gap,
                start_y + @as(f64, @floatFromInt(row)) * dot_gap,
                dot_radius,
                0,
                std.math.tau,
            );
            c.cairo_set_source_rgba(cr, dot_color[0], dot_color[1], dot_color[2], dot_color[3]);
            c.cairo_fill(cr);
        }
    }
}

fn drawDockSeparator(cr: *c.cairo_t, width: u32, height: u32, item_count: usize, style: dock_style.Style, offset_y: f64) void {
    if (item_count <= 1) return;

    const before = itemRect(width, height, item_count, style, offset_y, item_count - 2);
    const after = itemRect(width, height, item_count, style, offset_y, item_count - 1);
    const x = (before.x + before.width + after.x) / 2.0;
    const line_height = @min(style.item_size * 0.64, 30.0);
    const y = before.y + (before.height - line_height) / 2.0;

    c.cairo_save(cr);
    defer c.cairo_restore(cr);

    c.cairo_set_line_width(cr, dock_separator_width);
    c.cairo_set_line_cap(cr, c.CAIRO_LINE_CAP_ROUND);
    c.cairo_move_to(cr, x, y);
    c.cairo_line_to(cr, x, y + line_height);
    c.cairo_set_source_rgba(cr, 0.05, 0.08, 0.18, 0.34);
    c.cairo_stroke(cr);

    c.cairo_set_line_width(cr, 0.75);
    c.cairo_move_to(cr, x + 1.25, y + 1.0);
    c.cairo_line_to(cr, x + 1.25, y + line_height - 1.0);
    c.cairo_set_source_rgba(cr, 0.88, 0.96, 1.0, 0.16);
    c.cairo_stroke(cr);
}

pub fn contextMenuRect(width: u32, height: u32, item_count: usize, style: dock_style.Style, offset_y: f64, item_index: usize) Rect {
    const anchor = itemRect(width, height, item_count, style, offset_y, item_index);
    const menu_width = 170.0;
    const menu_height = 42.0;
    const container = containerRect(width, height, item_count, style, offset_y);
    const desired_x = anchor.x + anchor.width / 2.0 - menu_width / 2.0;
    return .{
        .x = std.math.clamp(desired_x, container.x, container.x + container.width - menu_width),
        .y = anchor.y - menu_height - 10.0,
        .width = menu_width,
        .height = menu_height,
    };
}

pub fn contextMenuActionAt(width: u32, height: u32, style: dock_style.Style, offset_y: f64, entries: []const runtime_catalog.AppEntry, menu: ContextMenu, x: f64, y: f64) ContextMenuAction {
    const rect = contextMenuRect(width, height, entries.len + 1, style, offset_y, menu.item_index);
    if (rect.contains(x, y)) return .toggle_pin;
    return .none;
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
    drawRoundedRect(cr, rect, 9.0);
    if (is_focused and !hovered) {
        c.cairo_set_source_rgba(cr, 0.45, 0.34, 0.72, if (style.strong_hover) 0.18 else 0.12);
    } else {
        c.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, if (style.strong_hover) 0.13 else 0.085);
    }
    c.cairo_fill(cr);
}

fn hoverButtonRect(rect: Rect, style: dock_style.Style) Rect {
    const size = @min(rect.width - 4.0, style.icon_tile_size + 8.0);
    return .{
        .x = rect.x + (rect.width - size) / 2.0,
        .y = rect.y + (rect.height - size) / 2.0,
        .width = size,
        .height = size,
    };
}

fn drawOpenIndicator(cr: *c.cairo_t, rect: Rect, is_open: bool, is_focused: bool) void {
    if (!is_open) return;

    const line_width = if (is_focused) @min(rect.width - 13.0, 19.0) else @min(rect.width - 18.0, 13.0);
    const line_height: f64 = if (is_focused) 3.4 else 2.8;
    const gap_below_button: f64 = 1.4;
    const line_rect = Rect{
        .x = rect.x + (rect.width - line_width) / 2.0,
        .y = rect.y + rect.height + gap_below_button,
        .width = line_width,
        .height = line_height,
    };

    drawRoundedRect(cr, .{
        .x = line_rect.x,
        .y = line_rect.y + 0.9,
        .width = line_rect.width,
        .height = line_rect.height,
    }, line_height / 2.0);
    c.cairo_set_source_rgba(cr, 0.0, 0.0, 0.0, 0.30);
    c.cairo_fill(cr);

    drawRoundedRect(cr, line_rect, line_height / 2.0);
    if (is_focused) {
        c.cairo_set_source_rgba(cr, 0.36, 0.92, 1.0, 0.96);
    } else {
        c.cairo_set_source_rgba(cr, 0.82, 0.75, 1.0, 0.78);
    }
    c.cairo_fill(cr);
}

fn drawInsertionMarker(cr: *c.cairo_t, width: u32, height: u32, item_count: usize, style: dock_style.Style, offset_y: f64, insert_index: usize) void {
    const container = containerRect(width, height, item_count, style, offset_y);
    const marker_x = if (insert_index == 0)
        container.x + style.padding_x - style.item_gap / 2.0
    else if (insert_index >= item_count - 1)
        itemRect(width, height, item_count, style, offset_y, item_count - 2).x + style.item_size + style.item_gap / 2.0
    else
        itemRect(width, height, item_count, style, offset_y, insert_index).x - style.item_gap / 2.0;

    const marker_rect = Rect{
        .x = marker_x - 2.0,
        .y = container.y + 9.0,
        .width = 4.0,
        .height = container.height - 18.0,
    };
    drawRoundedRect(cr, marker_rect, 2.0);
    c.cairo_set_source_rgba(cr, 0.40, 0.95, 1.0, 0.88);
    c.cairo_fill(cr);
}

fn drawContextMenu(cr: *c.cairo_t, width: u32, height: u32, item_count: usize, style: dock_style.Style, offset_y: f64, menu: ContextMenu, favorite_count: usize) void {
    _ = favorite_count;
    const rect = contextMenuRect(width, height, item_count, style, offset_y, menu.item_index);
    drawRoundedRect(cr, rect, 12.0);
    c.cairo_set_source_rgba(cr, 0.105, 0.11, 0.128, 0.98);
    c.cairo_fill_preserve(cr);
    c.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.08);
    c.cairo_set_line_width(cr, 1.0);
    c.cairo_stroke(cr);

    const label = if (menu.pinned) "Desafixar da dock" else "Fixar na dock";
    drawLabel(cr, rect.x + 16.0, rect.y + 25.0, 14.0, label, 0.95, 0.96, 0.98);
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

fn drawLabel(cr: *c.cairo_t, x: f64, y: f64, size: f64, text: []const u8, r: f64, g: f64, b: f64) void {
    var text_buf: [160]u8 = undefined;
    const c_text = toCString(&text_buf, text);
    c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
    c.cairo_set_font_size(cr, size);
    c.cairo_set_source_rgb(cr, r, g, b);
    c.cairo_move_to(cr, x, y);
    c.cairo_show_text(cr, c_text.ptr);
}

fn toCString(buffer: []u8, text: []const u8) [:0]u8 {
    const max_len = @min(text.len, buffer.len - 1);
    @memcpy(buffer[0..max_len], text[0..max_len]);
    buffer[max_len] = 0;
    return buffer[0..max_len :0];
}
