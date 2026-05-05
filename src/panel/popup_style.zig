const std = @import("std");
const c = @import("wl.zig").c;
const settings_model = @import("settings_model");

pub fn beginPanelPopup(
    cr: *c.cairo_t,
    width: u32,
    height: u32,
    preferences: settings_model.PreferencesState,
) void {
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
    c.cairo_set_source_rgba(cr, 0, 0, 0, 0);
    c.cairo_paint(cr);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);

    const w = @as(f64, @floatFromInt(width));
    const h = @as(f64, @floatFromInt(height));
    const panel = Rect{ .x = 4, .y = 4, .width = @max(1.0, w - 8), .height = @max(1.0, h - 8) };
    const radius = 18.0;
    drawRoundedRect(cr, panel, radius);
    c.cairo_set_source_rgba(cr, 0.90, 0.97, 1.0, if (preferences.reduce_transparency) 0.24 else 0.030);
    c.cairo_fill(cr);

    drawRoundedRect(cr, .{ .x = panel.x + 1.0, .y = panel.y + 1.0, .width = panel.width - 2.0, .height = panel.height * 0.48 }, radius - 1.0);
    const shine = c.cairo_pattern_create_linear(0, panel.y, 0, panel.y + panel.height * 0.54) orelse return;
    defer c.cairo_pattern_destroy(shine);
    _ = c.cairo_pattern_add_color_stop_rgba(shine, 0.0, 1.0, 1.0, 1.0, 0.045);
    _ = c.cairo_pattern_add_color_stop_rgba(shine, 1.0, 1.0, 1.0, 1.0, 0.00);
    c.cairo_set_source(cr, shine);
    c.cairo_fill(cr);

    drawRoundedRect(cr, .{ .x = panel.x + 0.5, .y = panel.y + 0.5, .width = panel.width - 1.0, .height = panel.height - 1.0 }, radius - 0.5);
    c.cairo_set_source_rgba(cr, 0.95, 0.99, 1.0, 0.10);
    c.cairo_set_line_width(cr, 0.8);
    c.cairo_stroke(cr);
}

const Rect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

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
