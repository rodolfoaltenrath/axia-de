const std = @import("std");
const c = @import("wl.zig").c;
const notification = @import("notification_model");
const settings_model = @import("settings_model");
const popup_style = @import("popup_style.zig");

// Layout visual do centro de notificacoes: ajuste largura, alturas, espacamento e cores neste arquivo.

pub const popup_width: u32 = 360;
pub const popup_height: u32 = 360;

const header_height = 64.0;
const card_height = 72.0;
const card_gap = 10.0;

pub const Hit = enum {
    none,
    do_not_disturb,
};

const Rect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,

    fn contains(self: Rect, px: f64, py: f64) bool {
        return px >= self.x and px <= self.x + self.width and py >= self.y and py <= self.y + self.height;
    }
};

pub fn hitTest(x: f64, y: f64) Hit {
    if (toggleRect().contains(x, y)) return .do_not_disturb;
    return .none;
}

pub fn drawPopup(
    cr: *c.cairo_t,
    width: u32,
    height: u32,
    state: notification.State,
    preferences: settings_model.PreferencesState,
) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);

    popup_style.beginPanelPopup(cr, width, height, preferences);
    const accent = settings_model.accentSpec(preferences.accent).primary;

    drawLabel(cr, 20, 40, 16, "Não Perturbe", 0.95, 0.96, 0.98);
    drawToggle(cr, toggleRect(), state.do_not_disturb, accent);

    c.cairo_rectangle(cr, 16, header_height, @as(f64, @floatFromInt(width)) - 32, 1);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.10);
    c.cairo_fill(cr);

    const list_top = header_height + 16;
    const list_height = @as(f64, @floatFromInt(height)) - list_top - 16;
    if (state.count == 0) {
        drawEmptyState(cr, Rect{ .x = 0, .y = list_top, .width = @floatFromInt(width), .height = list_height });
        return;
    }

    const visible_slots = @max(1, @as(usize, @intFromFloat(@floor((list_height + card_gap) / (card_height + card_gap)))));
    const visible_count = @min(state.count, visible_slots);
    const start_index = state.count - visible_count;

    var row: usize = 0;
    var index: usize = state.count;
    while (index > start_index) {
        index -= 1;
        const item = state.items[index];
        const rect = Rect{
            .x = 14,
            .y = list_top + @as(f64, @floatFromInt(row)) * (card_height + card_gap),
            .width = @as(f64, @floatFromInt(width)) - 28,
            .height = card_height,
        };
        drawNotificationCard(cr, rect, item, preferences);
        row += 1;
    }

    const hidden = state.count - visible_count;
    if (hidden > 0) {
        var count_buf: [48]u8 = undefined;
        const label = std.fmt.bufPrint(&count_buf, "+{} notificações mais antigas", .{hidden}) catch "";
        drawLabel(cr, 20, @as(f64, @floatFromInt(height)) - 12, 13, label, 0.62, 0.65, 0.70);
    }
}

fn toggleRect() Rect {
    return .{ .x = popup_width - 72, .y = 18, .width = 52, .height = 28 };
}

fn drawNotificationCard(cr: *c.cairo_t, rect: Rect, item: notification.Notification, preferences: settings_model.PreferencesState) void {
    const accent = colorForLevel(item.level, preferences);

    drawRoundedRect(cr, rect, 14);
    c.cairo_set_source_rgba(cr, 0.13, 0.14, 0.16, if (preferences.reduce_transparency) 0.99 else 0.93);
    c.cairo_fill_preserve(cr);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.05);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);

    c.cairo_arc(cr, rect.x + 16, rect.y + 20, 4, 0, std.math.pi * 2.0);
    c.cairo_set_source_rgba(cr, accent[0], accent[1], accent[2], 0.95);
    c.cairo_fill(cr);

    drawLabel(cr, rect.x + 28, rect.y + 25, 14, titleForLevel(item.level), 0.95, 0.96, 0.98);
    drawLabel(cr, rect.x + 28, rect.y + 48, 14, item.messageText(), 0.82, 0.84, 0.88);

    const age = formatAge(item.created_ms);
    drawLabel(cr, rect.x + rect.width - age.width, rect.y + 25, 13, age.text, 0.60, 0.64, 0.70);
}

fn drawEmptyState(cr: *c.cairo_t, rect: Rect) void {
    drawBubbleGlyph(cr, rect.x + rect.width / 2.0, rect.y + rect.height / 2.0 - 24, 34);
    drawCenteredLabel(cr, .{ .x = rect.x, .y = rect.y + rect.height / 2.0 - 2, .width = rect.width, .height = 28 }, 16, "Sem notificações", 0.94, 0.95, 0.97);
}

fn drawBubbleGlyph(cr: *c.cairo_t, cx: f64, cy: f64, size: f64) void {
    const w = size;
    const h = size * 0.78;
    const rect = Rect{ .x = cx - w / 2.0, .y = cy - h / 2.0, .width = w, .height = h };
    drawRoundedRect(cr, rect, 6);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.92);
    c.cairo_fill(cr);

    c.cairo_move_to(cr, cx + 4, rect.y + rect.height - 1);
    c.cairo_line_to(cr, cx - 1, rect.y + rect.height + 9);
    c.cairo_line_to(cr, cx - 8, rect.y + rect.height - 1);
    c.cairo_close_path(cr);
    c.cairo_fill(cr);
}

fn drawToggle(cr: *c.cairo_t, rect: Rect, enabled: bool, accent: [3]f64) void {
    drawRoundedRect(cr, rect, 10);
    if (enabled) {
        c.cairo_set_source_rgba(cr, accent[0], accent[1], accent[2], 0.92);
    } else {
        c.cairo_set_source_rgba(cr, 1, 1, 1, 0.10);
    }
    c.cairo_fill(cr);

    const knob_x = if (enabled) rect.x + 28 else rect.x + 4;
    drawRoundedRect(cr, .{ .x = knob_x, .y = rect.y + 4, .width = 20, .height = 20 }, 10);
    c.cairo_set_source_rgba(cr, 0.98, 0.99, 1.0, 0.96);
    c.cairo_fill(cr);
}

fn titleForLevel(level: notification.Level) []const u8 {
    return switch (level) {
        .info => "Informação",
        .success => "Concluído",
        .warning => "Atenção",
        .failure => "Erro",
    };
}

fn colorForLevel(level: notification.Level, preferences: settings_model.PreferencesState) [3]f64 {
    return switch (level) {
        .info => settings_model.accentSpec(preferences.accent).primary,
        .success => .{ 0.44, 0.88, 0.58 },
        .warning => .{ 0.98, 0.78, 0.30 },
        .failure => .{ 0.96, 0.38, 0.42 },
    };
}

const AgeLabel = struct {
    text: []const u8,
    width: f64,
};

fn formatAge(created_ms: i64) AgeLabel {
    var buffer: [32]u8 = undefined;
    const elapsed_ms = @max(0, std.time.milliTimestamp() - created_ms);
    const minutes = @divFloor(elapsed_ms, 60 * 1000);
    const text = if (minutes < 1)
        std.fmt.bufPrint(&buffer, "agora", .{}) catch ""
    else if (minutes < 60)
        std.fmt.bufPrint(&buffer, "{} min", .{minutes}) catch ""
    else if (minutes < 24 * 60)
        std.fmt.bufPrint(&buffer, "{} h", .{@divFloor(minutes, 60)}) catch ""
    else
        std.fmt.bufPrint(&buffer, "{} d", .{@divFloor(minutes, 24 * 60)}) catch "";

    return .{ .text = text, .width = estimateTextWidth(13, text) };
}

fn estimateTextWidth(size: f64, text: []const u8) f64 {
    return @as(f64, @floatFromInt(text.len)) * (size * 0.56);
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

fn drawCenteredLabel(cr: *c.cairo_t, rect: Rect, size: f64, text: []const u8, r: f64, g: f64, b: f64) void {
    var text_buf: [256]u8 = undefined;
    const max_len = @min(text.len, text_buf.len - 1);
    @memcpy(text_buf[0..max_len], text[0..max_len]);
    text_buf[max_len] = 0;
    var extents: c.cairo_text_extents_t = undefined;
    var font_extents: c.cairo_font_extents_t = undefined;
    c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
    c.cairo_set_font_size(cr, size);
    c.cairo_text_extents(cr, text_buf[0..max_len :0].ptr, &extents);
    c.cairo_font_extents(cr, &font_extents);

    const x = rect.x + (rect.width - extents.width) / 2.0 - extents.x_bearing;
    const y = rect.y + (rect.height - font_extents.height) / 2.0 + font_extents.ascent;
    drawLabel(cr, x, y, size, text, r, g, b);
}
