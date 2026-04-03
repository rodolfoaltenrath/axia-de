const std = @import("std");
const c = @import("client_wl").c;
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

pub fn cardRect(index: usize) Rect {
    const col = index % 2;
    const row = index / 2;
    return .{
        .x = 28 + @as(f64, @floatFromInt(col)) * 252,
        .y = 92 + @as(f64, @floatFromInt(row)) * 118,
        .width = 224,
        .height = 94,
    };
}

pub fn hitTest(x: f64, y: f64) ?usize {
    for (catalog.entries, 0..) |_, index| {
        if (cardRect(index).contains(x, y)) return index;
    }
    return null;
}

pub fn draw(cr: *c.cairo_t, width: u32, height: u32, hovered: ?usize) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);

    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
    c.cairo_set_source_rgba(cr, 0.09, 0.095, 0.115, 1.0);
    c.cairo_paint(cr);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);

    drawLabel(cr, 28, 42, 28, "Aplicativos", 0.97, 0.98, 0.99);
    drawLabel(cr, 28, 66, 15, "Base inicial de apps do Axia-DE", 0.70, 0.73, 0.78);

    for (catalog.entries, 0..) |entry, index| {
        const rect = cardRect(index);
        const is_hovered = hovered != null and hovered.? == index;
        drawRoundedRect(cr, rect, 18);
        c.cairo_set_source_rgba(cr, 1, 1, 1, if (is_hovered) 0.09 else 0.05);
        c.cairo_fill_preserve(cr);
        c.cairo_set_source_rgba(cr, 1, 1, 1, if (is_hovered) 0.07 else 0.04);
        c.cairo_set_line_width(cr, 1);
        c.cairo_stroke(cr);

        drawRoundedRect(cr, .{ .x = rect.x + 18, .y = rect.y + 18, .width = 42, .height = 42 }, 12);
        c.cairo_set_source_rgba(cr, entry.accent[0], entry.accent[1], entry.accent[2], 0.22);
        c.cairo_fill(cr);

        drawCenteredLabel(cr, .{ .x = rect.x + 18, .y = rect.y + 18, .width = 42, .height = 42 }, if (entry.monogram.len > 1) 14 else 18, entry.monogram, 0.98, 0.99, 1.0);
        drawLabel(cr, rect.x + 76, rect.y + 38, 17, entry.label, 0.96, 0.97, 0.99);
        drawLabel(cr, rect.x + 76, rect.y + 62, 14, "Abrir aplicativo", 0.73, 0.75, 0.79);
    }

    c.cairo_rectangle(cr, 24, @as(f64, @floatFromInt(height)) - 48, @as(f64, @floatFromInt(width - 48)), 1);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.08);
    c.cairo_fill(cr);
    drawLabel(cr, 28, @as(f64, @floatFromInt(height)) - 18, 14, "Use esta janela como base para os apps nativos do Axia-DE.", 0.74, 0.76, 0.80);
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

fn drawLabel(cr: *c.cairo_t, x: f64, y: f64, size: f64, text: []const u8, r: f64, g: f64, b: f64) void {
    var text_buf: [256]u8 = undefined;
    const c_text = toCString(&text_buf, text);
    c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
    c.cairo_set_font_size(cr, size);
    c.cairo_set_source_rgb(cr, r, g, b);
    c.cairo_move_to(cr, x, y);
    c.cairo_show_text(cr, c_text.ptr);
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
