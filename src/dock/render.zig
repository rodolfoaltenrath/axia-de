const std = @import("std");
const c = @import("wl.zig").c;
const catalog = @import("apps_catalog");

pub const Rect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,

    pub fn contains(self: Rect, px: f64, py: f64) bool {
        return px >= self.x and px <= self.x + self.width and py >= self.y and py <= self.y + self.height;
    }
};

pub const surface_height: u32 = 74;

const item_size: f64 = 44;
const item_gap: f64 = 10;
const dock_padding_x: f64 = 14;
const dock_padding_y: f64 = 8;

pub fn containerRect(width: u32, height: u32) Rect {
    const total_items_width = @as(f64, @floatFromInt(catalog.entries.len)) * item_size;
    const total_gap_width = @as(f64, @floatFromInt(@max(catalog.entries.len, 1) - 1)) * item_gap;
    const dock_width = dock_padding_x * 2.0 + total_items_width + total_gap_width;
    const dock_height = item_size + dock_padding_y * 2.0;
    return .{
        .x = (@as(f64, @floatFromInt(width)) - dock_width) / 2.0,
        .y = @as(f64, @floatFromInt(height)) - dock_height - 10,
        .width = dock_width,
        .height = dock_height,
    };
}

pub fn itemRect(width: u32, height: u32, index: usize) Rect {
    const container = containerRect(width, height);
    return .{
        .x = container.x + dock_padding_x + @as(f64, @floatFromInt(index)) * (item_size + item_gap),
        .y = container.y + dock_padding_y,
        .width = item_size,
        .height = item_size,
    };
}

pub fn hitTest(width: u32, height: u32, x: f64, y: f64) ?usize {
    for (catalog.entries, 0..) |_, index| {
        if (itemRect(width, height, index).contains(x, y)) return index;
    }
    return null;
}

pub fn drawDock(cr: *c.cairo_t, width: u32, height: u32, hovered_index: ?usize) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);

    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
    c.cairo_set_source_rgba(cr, 0, 0, 0, 0);
    c.cairo_paint(cr);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);

    const container = containerRect(width, height);
    const shadow_rect = Rect{
        .x = container.x,
        .y = container.y + 6,
        .width = container.width,
        .height = container.height,
    };
    drawRoundedRect(cr, shadow_rect, 18);
    c.cairo_set_source_rgba(cr, 0.02, 0.03, 0.05, 0.20);
    c.cairo_fill(cr);

    drawRoundedRect(cr, container, 18);
    c.cairo_set_source_rgba(cr, 0.096, 0.102, 0.128, 0.78);
    c.cairo_fill_preserve(cr);
    c.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.10);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);

    c.cairo_rectangle(cr, container.x, container.y, container.width, container.height);
    c.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.014);
    c.cairo_fill(cr);

    c.cairo_rectangle(cr, container.x + 10, container.y + container.height - 2, container.width - 20, 1);
    c.cairo_set_source_rgba(cr, 0.55, 0.84, 0.98, 0.18);
    c.cairo_fill(cr);

    for (catalog.entries, 0..) |entry, index| {
        const rect = itemRect(width, height, index);
        const hovered = hovered_index != null and hovered_index.? == index;
        _ = entry.accent;
        drawDockItem(cr, rect, entry.monogram, hovered, hovered_index, index);
    }
}

fn drawDockItem(
    cr: *c.cairo_t,
    rect: Rect,
    monogram: []const u8,
    hovered: bool,
    hovered_index: ?usize,
    index: usize,
) void {
    const is_neighbor = hovered_index != null and
        (hovered_index.? + 1 == index or (hovered_index.? > 0 and hovered_index.? - 1 == index));

    if (hovered) {
        const hover_rect = Rect{
            .x = rect.x - 1,
            .y = rect.y - 1,
            .width = rect.width + 2,
            .height = rect.height + 2,
        };
        drawHoverCapsule(cr, hover_rect);
    }

    const tile_size: f64 = if (hovered)
        40.0
    else if (is_neighbor)
        36.0
    else
        32.0;
    const hover_lift: f64 = if (hovered) 2.0 else 0.0;
    const tile_rect = Rect{
        .x = rect.x + (rect.width - tile_size) / 2.0,
        .y = rect.y + (rect.height - tile_size) / 2.0 - hover_lift,
        .width = tile_size,
        .height = tile_size,
    };

    drawCenteredLabel(
        cr,
        tile_rect,
        if (monogram.len > 1) 14 else 18,
        monogram,
        if (hovered) 1.0 else if (is_neighbor) 0.97 else 0.94,
        if (hovered) 1.0 else if (is_neighbor) 0.98 else 0.95,
        if (hovered) 1.0 else if (is_neighbor) 0.99 else 0.96,
    );
}

fn drawHoverCapsule(cr: *c.cairo_t, rect: Rect) void {
    drawRoundedRect(cr, rect, 12);
    c.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.09);
    c.cairo_fill_preserve(cr);
    c.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.055);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);

    drawRoundedRect(
        cr,
        .{
            .x = rect.x + 1,
            .y = rect.y + 1,
            .width = rect.width - 2,
            .height = rect.height * 0.44,
        },
        11,
    );
    c.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.034);
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
