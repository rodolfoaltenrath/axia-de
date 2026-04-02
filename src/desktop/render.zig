const std = @import("std");
const c = @import("../wl.zig").c;
const actions = @import("actions.zig");

pub const menu_width: u32 = 312;
pub const menu_height: u32 = 260;
const header_height: f64 = 52;
const row_height: f64 = 34;
const item_gap: f64 = 4;
const outer_padding: f64 = 12;

pub const Rect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,

    pub fn contains(self: Rect, px: f64, py: f64) bool {
        return px >= self.x and px <= self.x + self.width and py >= self.y and py <= self.y + self.height;
    }
};

pub fn itemRect(items: []const actions.Item, index: usize) Rect {
    var y = header_height + outer_padding;
    for (items[0..index]) |item| {
        y += switch (item.kind) {
            .separator => 14,
            else => row_height + item_gap,
        };
    }

    return switch (items[index].kind) {
        .separator => .{
            .x = outer_padding + 8,
            .y = y + 6,
            .width = @as(f64, @floatFromInt(menu_width)) - (outer_padding + 8) * 2,
            .height = 1,
        },
        else => .{
            .x = outer_padding,
            .y = y,
            .width = @as(f64, @floatFromInt(menu_width)) - outer_padding * 2,
            .height = row_height,
        },
    };
}

pub fn hitTest(items: []const actions.Item, x: f64, y: f64) ?usize {
    for (items, 0..) |item, index| {
        if (item.kind == .separator) continue;
        if (itemRect(items, index).contains(x, y)) return index;
    }
    return null;
}

pub fn drawMenu(cr: *c.cairo_t, page: actions.Page, hovered_index: ?usize) void {
    const spec = actions.specFor(page);

    c.cairo_save(cr);
    defer c.cairo_restore(cr);

    c.cairo_set_source_rgba(cr, 0, 0, 0, 0);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
    c.cairo_paint(cr);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);

    drawShadow(cr);

    const body = Rect{
        .x = 8,
        .y = 8,
        .width = @as(f64, @floatFromInt(menu_width)) - 16,
        .height = @as(f64, @floatFromInt(menu_height)) - 16,
    };
    drawRoundedRect(cr, body, 16);
    c.cairo_set_source_rgba(cr, 0.09, 0.095, 0.105, 0.98);
    c.cairo_fill_preserve(cr);
    c.cairo_set_source_rgba(cr, 0.40, 0.82, 0.98, 0.28);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);

    drawLabel(cr, 24, 34, 18, spec.title, 0.96, 0.97, 0.98, c.CAIRO_FONT_WEIGHT_BOLD);
    drawLabel(cr, 24, 50, 12, spec.subtitle, 0.68, 0.71, 0.75, c.CAIRO_FONT_WEIGHT_NORMAL);

    for (spec.items, 0..) |item, index| {
        const rect = itemRect(spec.items, index);
        switch (item.kind) {
            .separator => {
                c.cairo_set_source_rgba(cr, 1, 1, 1, 0.08);
                c.cairo_rectangle(cr, rect.x, rect.y, rect.width, rect.height);
                c.cairo_fill(cr);
            },
            .action, .navigate, .back, .disabled => {
                drawRoundedRect(cr, rect, 10);
                if (hovered_index != null and hovered_index.? == index and item.kind != .disabled) {
                    c.cairo_set_source_rgba(cr, 0.26, 0.60, 0.76, 0.92);
                } else {
                    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.045);
                }
                c.cairo_fill(cr);

                const text_color = if (item.kind == .disabled)
                    [3]f64{ 0.54, 0.56, 0.60 }
                else
                    [3]f64{ 0.92, 0.93, 0.95 };
                const prefix = switch (item.kind) {
                    .navigate => "> ",
                    .back => "< ",
                    else => "",
                };
                var label_buf: [192]u8 = undefined;
                const label = if (prefix.len > 0)
                    std.fmt.bufPrint(&label_buf, "{s}{s}", .{ prefix, item.label }) catch item.label
                else
                    item.label;

                drawLabel(
                    cr,
                    rect.x + 14,
                    rect.y + 22,
                    15,
                    label,
                    text_color[0],
                    text_color[1],
                    text_color[2],
                    c.CAIRO_FONT_WEIGHT_NORMAL,
                );
            },
        }
    }
}

fn drawShadow(cr: *c.cairo_t) void {
    drawRoundedRect(cr, .{ .x = 12, .y = 16, .width = @as(f64, @floatFromInt(menu_width)) - 24, .height = @as(f64, @floatFromInt(menu_height)) - 20 }, 18);
    c.cairo_set_source_rgba(cr, 0.0, 0.0, 0.0, 0.26);
    c.cairo_fill(cr);
}

fn drawRoundedRect(cr: *c.cairo_t, rect: Rect, radius: f64) void {
    const right = rect.x + rect.width;
    const bottom = rect.y + rect.height;

    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, right - radius, rect.y + radius, radius, -pi / 2.0, 0);
    c.cairo_arc(cr, right - radius, bottom - radius, radius, 0, pi / 2.0);
    c.cairo_arc(cr, rect.x + radius, bottom - radius, radius, pi / 2.0, pi);
    c.cairo_arc(cr, rect.x + radius, rect.y + radius, radius, pi, 3.0 * pi / 2.0);
    c.cairo_close_path(cr);
}

fn drawLabel(
    cr: *c.cairo_t,
    x: f64,
    y: f64,
    size: f64,
    text: []const u8,
    r: f64,
    g: f64,
    b: f64,
    weight: u32,
) void {
    var text_buf: [160]u8 = undefined;
    const max_len = @min(text.len, text_buf.len - 1);
    @memcpy(text_buf[0..max_len], text[0..max_len]);
    text_buf[max_len] = 0;

    c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, weight);
    c.cairo_set_font_size(cr, size);
    c.cairo_set_source_rgb(cr, r, g, b);
    c.cairo_move_to(cr, x, y);
    c.cairo_show_text(cr, text_buf[0..max_len :0].ptr);
}

const pi = std.math.pi;
