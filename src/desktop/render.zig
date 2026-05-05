const std = @import("std");
const c = @import("../wl.zig").c;
const actions = @import("actions.zig");

pub const menu_width: u32 = 312;
pub const menu_height: u32 = 216;
const header_height: f64 = 6;
const row_height: f64 = 40;
const item_gap: f64 = 6;
const outer_padding: f64 = 14;

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

    drawOuterShadow(cr);

    const body = Rect{
        .x = 8,
        .y = 8,
        .width = @as(f64, @floatFromInt(menu_width)) - 16,
        .height = @as(f64, @floatFromInt(menu_height)) - 16,
    };
    drawGlassPanel(cr, body);

    for (spec.items, 0..) |item, index| {
        const rect = itemRect(spec.items, index);
        switch (item.kind) {
            .separator => {
                c.cairo_set_source_rgba(cr, 0.82, 0.94, 1.0, 0.16);
                c.cairo_rectangle(cr, rect.x, rect.y, rect.width, rect.height);
                c.cairo_fill(cr);
            },
            .action, .navigate, .back, .disabled => {
                drawRoundedRect(cr, rect, 10);
                if (hovered_index != null and hovered_index.? == index and item.kind != .disabled) {
                    c.cairo_set_source_rgba(cr, 0.86, 0.95, 1.0, 0.20);
                } else {
                    c.cairo_set_source_rgba(cr, 0.92, 0.97, 1.0, 0.075);
                }
                c.cairo_fill_preserve(cr);
                c.cairo_set_source_rgba(cr, 0.92, 0.98, 1.0, if (hovered_index != null and hovered_index.? == index and item.kind != .disabled) 0.12 else 0.035);
                c.cairo_set_line_width(cr, 1.0);
                c.cairo_stroke(cr);

                const text_color = if (item.kind == .disabled)
                    [3]f64{ 0.62, 0.68, 0.76 }
                else
                    [3]f64{ 0.96, 0.98, 1.0 };
                drawItemIcon(cr, rect, item);

                drawLabel(
                    cr,
                    rect.x + 44,
                    rect.y + 25,
                    15,
                    item.label,
                    text_color[0],
                    text_color[1],
                    text_color[2],
                    c.CAIRO_FONT_WEIGHT_NORMAL,
                );
            },
        }
    }
}

fn drawOuterShadow(cr: *c.cairo_t) void {
    const body = Rect{
        .x = 8,
        .y = 8,
        .width = @as(f64, @floatFromInt(menu_width)) - 16,
        .height = @as(f64, @floatFromInt(menu_height)) - 16,
    };

    const shadow = Rect{
        .x = body.x - 3,
        .y = body.y + 6,
        .width = body.width + 6,
        .height = body.height + 5,
    };
    drawRoundedRect(cr, shadow, 21);
    const gradient = c.cairo_pattern_create_linear(0, shadow.y, 0, shadow.y + shadow.height);
    defer c.cairo_pattern_destroy(gradient);
    c.cairo_pattern_add_color_stop_rgba(gradient, 0.0, 0.02, 0.05, 0.14, 0.030);
    c.cairo_pattern_add_color_stop_rgba(gradient, 0.58, 0.02, 0.05, 0.14, 0.090);
    c.cairo_pattern_add_color_stop_rgba(gradient, 1.0, 0.02, 0.05, 0.14, 0.0);
    c.cairo_set_source(cr, gradient);
    c.cairo_fill(cr);
}

fn drawGlassPanel(cr: *c.cairo_t, rect: Rect) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);

    drawRoundedRect(cr, rect, 18);
    const base = c.cairo_pattern_create_linear(rect.x, rect.y, rect.x + rect.width, rect.y + rect.height);
    defer c.cairo_pattern_destroy(base);
    c.cairo_pattern_add_color_stop_rgba(base, 0.0, 0.46, 0.61, 0.88, 0.50);
    c.cairo_pattern_add_color_stop_rgba(base, 0.54, 0.40, 0.52, 0.78, 0.47);
    c.cairo_pattern_add_color_stop_rgba(base, 1.0, 0.34, 0.45, 0.70, 0.45);
    c.cairo_set_source(cr, base);
    c.cairo_fill_preserve(cr);
    c.cairo_set_source_rgba(cr, 0.82, 0.94, 1.0, 0.30);
    c.cairo_set_line_width(cr, 1.0);
    c.cairo_stroke(cr);

    drawRoundedRect(cr, .{
        .x = rect.x + 1,
        .y = rect.y + 1,
        .width = rect.width - 2,
        .height = rect.height - 2,
    }, 17);
    const sheen = c.cairo_pattern_create_linear(0, rect.y, 0, rect.y + rect.height);
    defer c.cairo_pattern_destroy(sheen);
    c.cairo_pattern_add_color_stop_rgba(sheen, 0.0, 0.94, 0.98, 1.0, 0.12);
    c.cairo_pattern_add_color_stop_rgba(sheen, 0.46, 0.94, 0.98, 1.0, 0.030);
    c.cairo_pattern_add_color_stop_rgba(sheen, 1.0, 0.08, 0.14, 0.30, 0.055);
    c.cairo_set_source(cr, sheen);
    c.cairo_fill(cr);
}

fn drawItemIcon(cr: *c.cairo_t, rect: Rect, item: actions.Item) void {
    const icon = Rect{ .x = rect.x + 13, .y = rect.y + 10, .width = 20, .height = 20 };
    const disabled = item.kind == .disabled;
    const alpha: f64 = if (disabled) 0.48 else 0.94;

    c.cairo_save(cr);
    defer c.cairo_restore(cr);

    switch (item.kind) {
        .back => drawBackIcon(cr, icon, alpha),
        .navigate => {
            if (item.target == .personalization) {
                drawPersonalizationIcon(cr, icon, alpha);
            } else if (item.target == .system) {
                drawSystemIcon(cr, icon, alpha);
            } else {
                drawWindowsIcon(cr, icon, alpha);
            }
        },
        .action => {
            if (item.action == .wallpapers) {
                drawWallpaperIcon(cr, icon, alpha);
            } else if (item.action == .appearance) {
                drawPersonalizationIcon(cr, icon, alpha);
            } else if (item.action == .panel) {
                drawPanelIcon(cr, icon, alpha);
            } else if (item.action == .displays) {
                drawDisplayIcon(cr, icon, alpha);
            } else if (item.action == .workspaces) {
                drawWorkspacesIcon(cr, icon, alpha);
            } else {
                drawInfoIcon(cr, icon, alpha);
            }
        },
        .disabled => drawWindowsIcon(cr, icon, alpha),
        .separator => {},
    }
}

fn drawIconStroke(cr: *c.cairo_t, alpha: f64) void {
    c.cairo_set_source_rgba(cr, 0.94, 0.98, 1.0, alpha);
    c.cairo_set_line_width(cr, 1.7);
    c.cairo_set_line_cap(cr, c.CAIRO_LINE_CAP_ROUND);
    c.cairo_set_line_join(cr, c.CAIRO_LINE_JOIN_ROUND);
    c.cairo_stroke(cr);
}

fn drawPersonalizationIcon(cr: *c.cairo_t, rect: Rect, alpha: f64) void {
    c.cairo_arc(cr, rect.x + 10, rect.y + 10, 7.2, 0, pi * 2.0);
    drawIconStroke(cr, alpha);
    c.cairo_arc(cr, rect.x + 7.2, rect.y + 8.0, 1.1, 0, pi * 2.0);
    c.cairo_arc(cr, rect.x + 11.8, rect.y + 7.1, 1.1, 0, pi * 2.0);
    c.cairo_arc(cr, rect.x + 9.2, rect.y + 12.8, 1.1, 0, pi * 2.0);
    c.cairo_set_source_rgba(cr, 0.94, 0.98, 1.0, alpha);
    c.cairo_fill(cr);
}

fn drawSystemIcon(cr: *c.cairo_t, rect: Rect, alpha: f64) void {
    c.cairo_arc(cr, rect.x + 10, rect.y + 10, 4.2, 0, pi * 2.0);
    drawIconStroke(cr, alpha);
    for (0..8) |i| {
        const angle = @as(f64, @floatFromInt(i)) * pi / 4.0;
        const sx = rect.x + 10 + @cos(angle) * 7.0;
        const sy = rect.y + 10 + @sin(angle) * 7.0;
        const ex = rect.x + 10 + @cos(angle) * 8.8;
        const ey = rect.y + 10 + @sin(angle) * 8.8;
        c.cairo_move_to(cr, sx, sy);
        c.cairo_line_to(cr, ex, ey);
    }
    drawIconStroke(cr, alpha);
}

fn drawWindowsIcon(cr: *c.cairo_t, rect: Rect, alpha: f64) void {
    drawRoundedRect(cr, .{ .x = rect.x + 3, .y = rect.y + 4, .width = 9, .height = 8 }, 2);
    drawRoundedRect(cr, .{ .x = rect.x + 8, .y = rect.y + 8, .width = 9, .height = 8 }, 2);
    drawIconStroke(cr, alpha);
}

fn drawBackIcon(cr: *c.cairo_t, rect: Rect, alpha: f64) void {
    c.cairo_move_to(cr, rect.x + 12.5, rect.y + 5);
    c.cairo_line_to(cr, rect.x + 7.5, rect.y + 10);
    c.cairo_line_to(cr, rect.x + 12.5, rect.y + 15);
    drawIconStroke(cr, alpha);
}

fn drawWallpaperIcon(cr: *c.cairo_t, rect: Rect, alpha: f64) void {
    drawRoundedRect(cr, .{ .x = rect.x + 3, .y = rect.y + 4, .width = 14, .height = 12 }, 3);
    drawIconStroke(cr, alpha);
    c.cairo_move_to(cr, rect.x + 4.5, rect.y + 14.5);
    c.cairo_line_to(cr, rect.x + 8.5, rect.y + 10.5);
    c.cairo_line_to(cr, rect.x + 11.0, rect.y + 13.0);
    c.cairo_line_to(cr, rect.x + 14.5, rect.y + 9.0);
    drawIconStroke(cr, alpha * 0.88);
}

fn drawPanelIcon(cr: *c.cairo_t, rect: Rect, alpha: f64) void {
    drawRoundedRect(cr, .{ .x = rect.x + 3, .y = rect.y + 5, .width = 14, .height = 10 }, 3);
    drawIconStroke(cr, alpha);
    c.cairo_move_to(cr, rect.x + 5, rect.y + 8);
    c.cairo_line_to(cr, rect.x + 15, rect.y + 8);
    drawIconStroke(cr, alpha * 0.82);
}

fn drawDisplayIcon(cr: *c.cairo_t, rect: Rect, alpha: f64) void {
    drawRoundedRect(cr, .{ .x = rect.x + 3, .y = rect.y + 4, .width = 14, .height = 10, }, 2.5);
    drawIconStroke(cr, alpha);
    c.cairo_move_to(cr, rect.x + 8, rect.y + 16);
    c.cairo_line_to(cr, rect.x + 12, rect.y + 16);
    c.cairo_move_to(cr, rect.x + 10, rect.y + 14);
    c.cairo_line_to(cr, rect.x + 10, rect.y + 16);
    drawIconStroke(cr, alpha);
}

fn drawWorkspacesIcon(cr: *c.cairo_t, rect: Rect, alpha: f64) void {
    drawRoundedRect(cr, .{ .x = rect.x + 3, .y = rect.y + 4, .width = 6, .height = 5 }, 1.5);
    drawRoundedRect(cr, .{ .x = rect.x + 11, .y = rect.y + 4, .width = 6, .height = 5 }, 1.5);
    drawRoundedRect(cr, .{ .x = rect.x + 3, .y = rect.y + 11, .width = 6, .height = 5 }, 1.5);
    drawRoundedRect(cr, .{ .x = rect.x + 11, .y = rect.y + 11, .width = 6, .height = 5 }, 1.5);
    drawIconStroke(cr, alpha);
}

fn drawInfoIcon(cr: *c.cairo_t, rect: Rect, alpha: f64) void {
    c.cairo_arc(cr, rect.x + 10, rect.y + 10, 7.2, 0, pi * 2.0);
    drawIconStroke(cr, alpha);
    c.cairo_arc(cr, rect.x + 10, rect.y + 6.8, 0.9, 0, pi * 2.0);
    c.cairo_set_source_rgba(cr, 0.94, 0.98, 1.0, alpha);
    c.cairo_fill(cr);
    c.cairo_move_to(cr, rect.x + 10, rect.y + 10);
    c.cairo_line_to(cr, rect.x + 10, rect.y + 14);
    drawIconStroke(cr, alpha);
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
