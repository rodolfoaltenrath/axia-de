const std = @import("std");
const c = @import("wl.zig").c;
const battery = @import("battery.zig");
const Rect = @import("render.zig").Rect;
const settings_model = @import("settings_model");

pub const popup_width: u32 = 320;
pub const popup_height: u32 = 200;

pub fn drawPopup(
    cr: *c.cairo_t,
    width: u32,
    height: u32,
    state: battery.State,
    preferences: settings_model.PreferencesState,
) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);

    c.cairo_set_source_rgba(cr, 0, 0, 0, 0);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
    c.cairo_paint(cr);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);

    drawRoundedRect(cr, .{ .x = 0, .y = 0, .width = @floatFromInt(width), .height = @floatFromInt(height) }, 14);
    c.cairo_set_source_rgba(cr, 0.10, 0.10, 0.11, 0.985);
    c.cairo_fill_preserve(cr);
    const accent = settings_model.accentSpec(preferences.accent).primary;
    c.cairo_set_source_rgba(cr, accent[0], accent[1], accent[2], 0.36);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);

    drawBatteryIcon(cr, .{ .x = 22, .y = 22, .width = 26, .height = 26 }, state, 0.96);
    drawLabel(cr, 58, 40, 18, "Bateria", 0.96, 0.96, 0.97);

    var percent_buf: [16]u8 = undefined;
    const percent = std.fmt.bufPrint(&percent_buf, "{d}%", .{state.percentage}) catch "0%";
    drawLabel(cr, 22, 88, 34, percent, 0.95, 0.96, 0.97);
    drawLabel(cr, 22, 116, 14, stateStatusLabel(state), 0.76, 0.76, 0.80);

    drawRoundedRect(cr, .{ .x = 22, .y = 138, .width = @as(f64, @floatFromInt(width)) - 44, .height = 34 }, 12);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.05);
    c.cairo_fill_preserve(cr);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.05);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);
    drawLabel(cr, 36, 160, 12.5, stateTimeLabel(state), 0.74, 0.74, 0.79);
}

fn stateStatusLabel(state: battery.State) []const u8 {
    if (state.charging) return "Carregando";
    return "Em uso";
}

fn stateTimeLabel(state: battery.State) []const u8 {
    if (state.timeText().len > 0) return state.timeText();
    return "Sem estimativa de tempo no momento";
}

fn drawBatteryIcon(cr: *c.cairo_t, rect: Rect, state: battery.State, alpha: f64) void {
    const body = Rect{ .x = rect.x, .y = rect.y + 4, .width = rect.width - 4, .height = rect.height - 8 };
    const cap = Rect{ .x = rect.x + rect.width - 4, .y = rect.y + 10, .width = 4, .height = 8 };

    drawRoundedRect(cr, body, 4);
    c.cairo_set_source_rgba(cr, 0.94, 0.95, 0.97, alpha);
    c.cairo_set_line_width(cr, 1.8);
    c.cairo_stroke(cr);

    drawRoundedRect(cr, cap, 2);
    c.cairo_set_source_rgba(cr, 0.94, 0.95, 0.97, alpha);
    c.cairo_fill(cr);

    const fill_width = (body.width - 6) * (@as(f64, @floatFromInt(state.percentage)) / 100.0);
    drawRoundedRect(cr, .{ .x = body.x + 3, .y = body.y + 3, .width = fill_width, .height = body.height - 6 }, 2.5);
    c.cairo_set_source_rgba(cr, if (state.percentage > 20) 0.45 else 0.95, if (state.percentage > 20) 0.90 else 0.42, 0.94, 0.92);
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

fn drawLabel(cr: *c.cairo_t, x: f64, y: f64, size: f64, text: []const u8, r: f64, g: f64, b: f64) void {
    var text_buf: [128]u8 = undefined;
    const max_len = @min(text.len, text_buf.len - 1);
    @memcpy(text_buf[0..max_len], text[0..max_len]);
    text_buf[max_len] = 0;

    c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
    c.cairo_set_font_size(cr, size);
    c.cairo_set_source_rgb(cr, r, g, b);
    c.cairo_move_to(cr, x, y);
    c.cairo_show_text(cr, text_buf[0..max_len :0].ptr);
}

const pi = 3.141592653589793;
