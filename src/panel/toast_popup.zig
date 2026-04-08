const std = @import("std");
const c = @import("wl.zig").c;
const toast = @import("toast_model");
const settings_model = @import("settings_model");

// Layout visual dos toasts: ajuste largura, altura, espacamento e cores neste arquivo.

pub const popup_width: u32 = 360;
pub const popup_height: u32 = 260;

const toast_height = 68.0;
const toast_gap = 10.0;

pub fn drawPopup(
    cr: *c.cairo_t,
    width: u32,
    height: u32,
    state: toast.State,
    preferences: settings_model.PreferencesState,
) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);

    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
    c.cairo_set_source_rgba(cr, 0, 0, 0, 0);
    c.cairo_paint(cr);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);

    const accent = settings_model.accentSpec(preferences.accent).primary;
    _ = accent;
    _ = height;

    for (0..state.count) |index| {
        const item = state.items[index];
        const rect = Rect{
            .x = 0,
            .y = @as(f64, @floatFromInt(index)) * (toast_height + toast_gap),
            .width = @floatFromInt(width),
            .height = toast_height,
        };
        drawToastCard(cr, rect, item, preferences);
    }
}

const Rect = struct { x: f64, y: f64, width: f64, height: f64 };

fn drawToastCard(cr: *c.cairo_t, rect: Rect, item: toast.Toast, preferences: settings_model.PreferencesState) void {
    const accent = colorForLevel(item.level, preferences);

    drawRoundedRect(cr, .{
        .x = rect.x + 4,
        .y = rect.y + 6,
        .width = rect.width - 8,
        .height = rect.height - 8,
    }, 16);
    c.cairo_set_source_rgba(cr, 0.02, 0.03, 0.05, 0.24);
    c.cairo_fill(cr);

    drawRoundedRect(cr, .{
        .x = rect.x + 2,
        .y = rect.y + 2,
        .width = rect.width - 4,
        .height = rect.height - 4,
    }, 16);
    c.cairo_set_source_rgba(cr, 0.10, 0.11, 0.13, if (preferences.reduce_transparency) 0.98 else 0.90);
    c.cairo_fill_preserve(cr);
    c.cairo_set_source_rgba(cr, accent[0], accent[1], accent[2], 0.38);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);

    c.cairo_rectangle(cr, rect.x + 16, rect.y + 15, 4, rect.height - 30);
    c.cairo_set_source_rgba(cr, accent[0], accent[1], accent[2], 0.95);
    c.cairo_fill(cr);

    drawDot(cr, rect.x + 36, rect.y + rect.height / 2.0, 7.5, accent);

    drawLabel(cr, rect.x + 56, rect.y + 30, 14, titleForLevel(item.level), 0.96, 0.97, 0.99);
    drawLabel(cr, rect.x + 56, rect.y + 50, 14, item.messageText(), 0.80, 0.82, 0.86);
}

fn drawDot(cr: *c.cairo_t, cx: f64, cy: f64, radius: f64, color: [3]f64) void {
    c.cairo_arc(cr, cx, cy, radius, 0, std.math.pi * 2.0);
    c.cairo_set_source_rgba(cr, color[0], color[1], color[2], 0.96);
    c.cairo_fill(cr);
}

fn titleForLevel(level: toast.Level) []const u8 {
    return switch (level) {
        .info => "Informação",
        .success => "Concluído",
        .warning => "Atenção",
        .failure => "Erro",
    };
}

fn colorForLevel(level: toast.Level, preferences: settings_model.PreferencesState) [3]f64 {
    return switch (level) {
        .info => settings_model.accentSpec(preferences.accent).primary,
        .success => .{ 0.44, 0.88, 0.58 },
        .warning => .{ 0.98, 0.78, 0.30 },
        .failure => .{ 0.96, 0.38, 0.42 },
    };
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
    const max_len = @min(text.len, text_buf.len - 1);
    @memcpy(text_buf[0..max_len], text[0..max_len]);
    text_buf[max_len] = 0;
    c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
    c.cairo_set_font_size(cr, size);
    c.cairo_set_source_rgb(cr, r, g, b);
    c.cairo_move_to(cr, x, y);
    c.cairo_show_text(cr, text_buf[0..max_len :0].ptr);
}
