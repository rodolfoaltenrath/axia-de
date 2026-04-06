const std = @import("std");
const c = @import("wl.zig").c;
const calendar = @import("calendar.zig");
const settings_model = @import("settings_model");

pub const Rect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,

    pub fn contains(self: Rect, px: f64, py: f64) bool {
        return px >= self.x and px <= self.x + self.width and py >= self.y and py <= self.y + self.height;
    }
};

pub const PanelMetrics = struct {
    workspaces: Rect,
    apps: Rect,
    clock: Rect,
};

pub const PopupMetrics = struct {
    prev_month: Rect,
    next_month: Rect,
};

pub const HoverTarget = enum {
    none,
    workspaces,
    apps,
    clock,
};

pub fn computePanelMetrics(width: u32, height: u32) PanelMetrics {
    const h = @as(f64, @floatFromInt(height));
    const center_x = @as(f64, @floatFromInt(width)) / 2.0;

    return .{
        .workspaces = .{ .x = 18, .y = 4, .width = 160, .height = h - 8 },
        .apps = .{ .x = 184, .y = 4, .width = 120, .height = h - 8 },
        .clock = .{ .x = center_x - 124, .y = 4, .width = 248, .height = h - 8 },
    };
}

pub fn popupMetrics(width: u32, _: u32) PopupMetrics {
    return .{
        .prev_month = .{ .x = @as(f64, @floatFromInt(width)) - 98, .y = 28, .width = 28, .height = 28 },
        .next_month = .{ .x = @as(f64, @floatFromInt(width)) - 58, .y = 28, .width = 28, .height = 28 },
    };
}

pub fn panelHoverAt(width: u32, height: u32, x: f64, y: f64) HoverTarget {
    const metrics = computePanelMetrics(width, height);
    if (metrics.clock.contains(x, y)) return .clock;
    if (metrics.apps.contains(x, y)) return .apps;
    if (metrics.workspaces.contains(x, y)) return .workspaces;
    return .none;
}

pub fn drawPanel(
    cr: *c.cairo_t,
    width: u32,
    height: u32,
    now: calendar.DateTime,
    hovered: HoverTarget,
    preferences: settings_model.PreferencesState,
) void {
    const metrics = computePanelMetrics(width, height);
    const bar_rect = Rect{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(width),
        .height = @floatFromInt(height),
    };

    c.cairo_save(cr);
    defer c.cairo_restore(cr);

    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
    c.cairo_set_source_rgba(cr, 0, 0, 0, 0);
    c.cairo_paint(cr);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);

    drawGlassBar(cr, bar_rect, preferences);
    drawPanelLabel(cr, metrics.workspaces, "Áreas de Trabalho", hovered == .workspaces, preferences);
    drawPanelLabel(cr, metrics.apps, "Aplicativos", hovered == .apps, preferences);

    drawClockHover(cr, metrics.clock, hovered == .clock, preferences);

    var label_buf: [64]u8 = undefined;
    const label = calendar.formatTimestamp(&label_buf, now, preferences.panel_show_date, preferences.panel_show_seconds);
    drawCenteredLabel(cr, metrics.clock, 16, label, 0.97, 0.98, 0.99);
}

pub fn drawCalendarPopup(
    cr: *c.cairo_t,
    width: u32,
    height: u32,
    cursor: calendar.MonthCursor,
    today: calendar.DateTime,
    preferences: settings_model.PreferencesState,
) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);

    c.cairo_set_source_rgba(cr, 0, 0, 0, 0);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
    c.cairo_paint(cr);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);

    drawRoundedRect(cr, .{ .x = 0, .y = 0, .width = @floatFromInt(width), .height = @floatFromInt(height) }, 14);
    c.cairo_set_source_rgba(cr, 0.10, 0.10, 0.11, 0.98);
    c.cairo_fill_preserve(cr);
    const accent = settings_model.accentSpec(preferences.accent).primary;
    c.cairo_set_source_rgba(cr, accent[0], accent[1], accent[2], 0.45);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);

    var long_buf: [64]u8 = undefined;
    const long_date = calendar.longDate(&long_buf, cursor, today.day());
    drawLabel(cr, 22, 38, 20, long_date, 0.96, 0.96, 0.97);
    drawLabel(cr, 22, 62, 16, calendar.weekdayLong(calendar.weekdayOf(today.year(), today.month(), today.day())), 0.82, 0.82, 0.84);

    const metrics = popupMetrics(width, height);
    drawArrowButton(cr, metrics.prev_month, "<");
    drawArrowButton(cr, metrics.next_month, ">");

    for (0..7) |col| {
        const x = 24 + @as(f64, @floatFromInt(col)) * 48;
        drawLabel(cr, x, 98, 14, calendar.weekdayShort(col), 0.70, 0.70, 0.72);
    }

    const grid = calendar.buildMonthGrid(cursor, today);
    for (0..6) |row| {
        for (0..7) |col| {
            const index = row * 7 + col;
            const cell = grid.cells[index];
            const x = 24 + @as(f64, @floatFromInt(col)) * 48;
            const y = 118 + @as(f64, @floatFromInt(row)) * 46;

            if (cell.is_today and cell.in_current_month) {
                drawRoundedRect(cr, .{ .x = x - 6, .y = y - 22, .width = 44, .height = 44 }, 10);
                c.cairo_set_source_rgb(cr, 0.41, 0.84, 0.94);
                c.cairo_fill(cr);
            }

            const brightness: f64 = if (cell.in_current_month) 0.84 else 0.44;
            const day_buf = std.fmt.bufPrint(&long_buf, "{d}", .{cell.day}) catch "";
            drawLabel(cr, x + 6, y, 18, day_buf, brightness, brightness, brightness + 0.03);
        }
    }

    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.10);
    c.cairo_rectangle(cr, 20, @as(f64, @floatFromInt(height)) - 54, @as(f64, @floatFromInt(width - 40)), 1);
    c.cairo_fill(cr);
    drawLabel(cr, 22, @as(f64, @floatFromInt(height)) - 22, 16, "Configurações de data, hora e calendário...", 0.82, 0.82, 0.84);
}

fn drawArrowButton(cr: *c.cairo_t, rect: Rect, label: []const u8) void {
    drawRoundedRect(cr, rect, 8);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.05);
    c.cairo_fill(cr);
    drawCenteredLabel(cr, rect, 18, label, 0.95, 0.95, 0.97);
}

fn drawGlassBar(cr: *c.cairo_t, rect: Rect, preferences: settings_model.PreferencesState) void {
    const accent = settings_model.accentSpec(preferences.accent).primary;
    c.cairo_rectangle(cr, rect.x, rect.y, rect.width, rect.height);
    c.cairo_set_source_rgba(cr, 0.092, 0.098, 0.122, if (preferences.reduce_transparency) 0.96 else 0.74);
    c.cairo_fill(cr);

    c.cairo_rectangle(cr, rect.x, rect.y, rect.width, 1);
    c.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.16);
    c.cairo_fill(cr);

    c.cairo_rectangle(cr, rect.x, rect.y + rect.height - 1, rect.width, 1);
    c.cairo_set_source_rgba(cr, accent[0], accent[1], accent[2], 0.38);
    c.cairo_fill(cr);

    c.cairo_rectangle(cr, rect.x, rect.y, rect.width, rect.height);
    c.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.018);
    c.cairo_fill(cr);
}

fn drawPanelLabel(cr: *c.cairo_t, rect: Rect, label: []const u8, hovered: bool, preferences: settings_model.PreferencesState) void {
    const text_x = rect.x + 12;
    const text_y = rect.y + rect.height / 2.0 + 6;

    if (hovered) {
        var text_buf: [256]u8 = undefined;
        const c_text = toCString(&text_buf, label);
        var extents: c.cairo_text_extents_t = undefined;
        c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
        c.cairo_set_font_size(cr, 15);
        c.cairo_text_extents(cr, c_text.ptr, &extents);

        const hover_rect = Rect{
            .x = text_x - 10,
            .y = rect.y,
            .width = extents.width + 24,
            .height = rect.height,
        };
        drawHoverCapsule(cr, hover_rect, preferences);
    }

    drawLabel(
        cr,
        text_x,
        text_y,
        15,
        label,
        if (hovered) 0.985 else 0.95,
        if (hovered) 0.99 else 0.96,
        if (hovered) 0.995 else 0.97,
    );
}

fn drawClockHover(cr: *c.cairo_t, rect: Rect, hovered: bool, preferences: settings_model.PreferencesState) void {
    if (!hovered) return;
    drawHoverCapsule(cr, rect, preferences);
}

fn drawHoverCapsule(cr: *c.cairo_t, rect: Rect, preferences: settings_model.PreferencesState) void {
    const accent = settings_model.accentSpec(preferences.accent).primary;
    drawRoundedRect(cr, rect, 9);
    c.cairo_set_source_rgba(cr, accent[0], accent[1], accent[2], 0.13);
    c.cairo_fill_preserve(cr);

    c.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.05);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);

    drawRoundedRect(
        cr,
        .{
            .x = rect.x + 1,
            .y = rect.y + 1,
            .width = rect.width - 2,
            .height = rect.height * 0.48,
        },
        8,
    );
    c.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.032);
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
    var text_buf: [256]u8 = undefined;
    const c_text = toCString(&text_buf, text);
    var extents: c.cairo_text_extents_t = undefined;
    var font_extents: c.cairo_font_extents_t = undefined;
    c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
    c.cairo_set_font_size(cr, size);
    c.cairo_text_extents(cr, c_text.ptr, &extents);
    c.cairo_font_extents(cr, &font_extents);

    const x = rect.x + (rect.width - extents.width) / 2.0 - extents.x_bearing;
    const y = rect.y + (rect.height - font_extents.height) / 2.0 + font_extents.ascent;
    drawLabel(cr, x, y, size, text, r, g, b);
}

fn toCString(buffer: []u8, text: []const u8) [:0]u8 {
    const max_len = @min(text.len, buffer.len - 1);
    @memcpy(buffer[0..max_len], text[0..max_len]);
    buffer[max_len] = 0;
    return buffer[0..max_len :0];
}
