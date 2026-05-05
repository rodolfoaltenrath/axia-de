const std = @import("std");
const c = @import("wl.zig").c;
const audio = @import("audio.zig");
const battery = @import("battery.zig");
const bluetooth = @import("bluetooth.zig");
const calendar = @import("calendar.zig");
const network = @import("network.zig");
const notification_model = @import("notification_model");
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
    notifications: Rect,
    power: Rect,
    battery: Rect,
    network: Rect,
    bluetooth: Rect,
    audio: Rect,
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
    notifications,
    power,
    battery,
    network,
    bluetooth,
    audio,
};

pub fn computePanelMetrics(width: u32, height: u32, show_battery: bool, show_network: bool, show_bluetooth: bool) PanelMetrics {
    const h = @as(f64, @floatFromInt(height));
    const center_x = @as(f64, @floatFromInt(width)) / 2.0;
    const power_x = @as(f64, @floatFromInt(width)) - 54;
    const audio_x = power_x - 42.0;
    const bluetooth_x = if (show_bluetooth) audio_x - 42 else audio_x;
    const network_x = if (show_network) bluetooth_x - 42.0 else bluetooth_x;
    const battery_x = if (show_battery) network_x - 46.0 else network_x;
    const notifications_x = battery_x - 42.0;

    return .{
        .workspaces = .{ .x = 18, .y = 4, .width = 160, .height = h - 8 },
        .apps = .{ .x = 184, .y = 4, .width = 120, .height = h - 8 },
        .clock = .{ .x = center_x - 124, .y = 4, .width = 248, .height = h - 8 },
        .notifications = .{ .x = notifications_x, .y = 4, .width = 36, .height = h - 8 },
        .power = .{ .x = power_x, .y = 4, .width = 36, .height = h - 8 },
        .battery = .{ .x = if (show_battery) battery_x else network_x, .y = 4, .width = if (show_battery) 40 else 0, .height = h - 8 },
        .network = .{ .x = if (show_network) network_x else bluetooth_x, .y = 4, .width = if (show_network) 36 else 0, .height = h - 8 },
        .bluetooth = .{ .x = bluetooth_x, .y = 4, .width = if (show_bluetooth) 36 else 0, .height = h - 8 },
        .audio = .{ .x = audio_x, .y = 4, .width = 36, .height = h - 8 },
    };
}

pub fn popupMetrics(width: u32, _: u32) PopupMetrics {
    return .{
        .prev_month = .{ .x = @as(f64, @floatFromInt(width)) - 98, .y = 28, .width = 28, .height = 28 },
        .next_month = .{ .x = @as(f64, @floatFromInt(width)) - 58, .y = 28, .width = 28, .height = 28 },
    };
}

pub fn panelHoverAt(width: u32, height: u32, show_battery: bool, show_network: bool, show_bluetooth: bool, x: f64, y: f64) HoverTarget {
    const metrics = computePanelMetrics(width, height, show_battery, show_network, show_bluetooth);
    if (metrics.power.contains(x, y)) return .power;
    if (metrics.audio.contains(x, y)) return .audio;
    if (metrics.notifications.contains(x, y)) return .notifications;
    if (show_battery and metrics.battery.contains(x, y)) return .battery;
    if (show_network and metrics.network.contains(x, y)) return .network;
    if (show_bluetooth and metrics.bluetooth.contains(x, y)) return .bluetooth;
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
    audio_state: audio.State,
    battery_state: battery.State,
    network_state: network.State,
    bluetooth_state: bluetooth.State,
    notification_state: notification_model.State,
    preferences: settings_model.PreferencesState,
) void {
    const metrics = computePanelMetrics(width, height, battery_state.available, network_state.available, bluetooth_state.available);
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
    drawPowerButton(cr, metrics.power, hovered == .power, preferences);
    drawNotificationsButton(cr, metrics.notifications, hovered == .notifications, notification_state.count > 0, preferences);
    if (battery_state.available) {
        drawBatteryButton(cr, metrics.battery, hovered == .battery, battery_state, preferences);
    }
    if (network_state.available) {
        drawNetworkButton(cr, metrics.network, hovered == .network, network_state, preferences);
    }
    if (bluetooth_state.available) {
        drawBluetoothButton(cr, metrics.bluetooth, hovered == .bluetooth, bluetooth_state.powered, preferences);
    }
    drawAudioButton(cr, metrics.audio, hovered == .audio, audio_state, preferences);

    var label_buf: [64]u8 = undefined;
    const label = calendar.formatTimestamp(&label_buf, now, preferences.panel_show_date, preferences.panel_show_seconds);
    drawCenteredLabel(cr, metrics.clock, 16, label, 0.97, 0.98, 0.99);
}

fn drawNotificationsButton(
    cr: *c.cairo_t,
    rect: Rect,
    hovered: bool,
    has_items: bool,
    preferences: settings_model.PreferencesState,
) void {
    if (hovered) drawHoverCapsule(cr, rect, preferences);
    drawNotificationGlyph(cr, rect, 0.94);

    if (has_items) {
        const accent = settings_model.accentSpec(preferences.accent).primary;
        c.cairo_arc(cr, rect.x + rect.width - 9, rect.y + 9, 3.2, 0, std.math.pi * 2.0);
        c.cairo_set_source_rgba(cr, accent[0], accent[1], accent[2], 0.95);
        c.cairo_fill(cr);
    }
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
    if (preferences.reduce_transparency) {
        c.cairo_rectangle(cr, rect.x, rect.y, rect.width, rect.height);
        c.cairo_set_source_rgba(cr, 0.22, 0.34, 0.58, 0.94);
        c.cairo_fill(cr);
    }

    c.cairo_rectangle(cr, rect.x, rect.y, rect.width, 1);
    c.cairo_set_source_rgba(cr, 0.86, 0.96, 1.0, 0.16);
    c.cairo_fill(cr);

    c.cairo_rectangle(cr, rect.x, rect.y + rect.height - 1, rect.width, 1);
    c.cairo_set_source_rgba(cr, 0.09, 0.16, 0.34, 0.20);
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

fn drawAudioButton(
    cr: *c.cairo_t,
    rect: Rect,
    hovered: bool,
    audio_state: audio.State,
    preferences: settings_model.PreferencesState,
) void {
    if (hovered) drawHoverCapsule(cr, rect, preferences);

    const muted = !audio_state.available or audio_state.sink.muted or audio_state.sink.volume <= 0.001;
    const alpha: f64 = if (audio_state.available) 0.96 else 0.55;
    drawSpeakerGlyph(cr, rect, muted, alpha);
}

fn drawBluetoothButton(
    cr: *c.cairo_t,
    rect: Rect,
    hovered: bool,
    powered: bool,
    preferences: settings_model.PreferencesState,
) void {
    if (hovered) drawHoverCapsule(cr, rect, preferences);
    drawBluetoothGlyph(cr, rect, powered, 0.94);
}

fn drawNetworkButton(
    cr: *c.cairo_t,
    rect: Rect,
    hovered: bool,
    state: network.State,
    preferences: settings_model.PreferencesState,
) void {
    if (hovered) drawHoverCapsule(cr, rect, preferences);
    if (state.ethernet_connected) {
        drawEthernetGlyph(cr, rect, 0.94);
    } else {
        drawWifiGlyph(cr, rect, if (state.wifi_connected) 82 else 0, state.wifi_enabled, 0.94);
    }
}

fn drawBatteryButton(
    cr: *c.cairo_t,
    rect: Rect,
    hovered: bool,
    state: battery.State,
    preferences: settings_model.PreferencesState,
) void {
    if (hovered) drawHoverCapsule(cr, rect, preferences);
    drawBatteryGlyph(cr, rect, state, 0.94);
}

fn drawPowerButton(cr: *c.cairo_t, rect: Rect, hovered: bool, preferences: settings_model.PreferencesState) void {
    if (hovered) drawHoverCapsule(cr, rect, preferences);
    drawPowerGlyph(cr, rect, 0.94);
}

fn drawNotificationGlyph(cr: *c.cairo_t, rect: Rect, alpha: f64) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    const cx = rect.x + rect.width / 2.0;
    const cy = rect.y + rect.height / 2.0 - 0.2;
    const bubble = Rect{ .x = cx - 7.8, .y = cy - 6.2, .width = 15.6, .height = 11.6 };

    c.cairo_set_source_rgba(cr, 0.94, 0.95, 0.97, alpha);
    drawRoundedRect(cr, bubble, 3.8);
    c.cairo_fill(cr);

    c.cairo_new_path(cr);
    c.cairo_move_to(cr, cx + 1.6, bubble.y + bubble.height - 0.8);
    c.cairo_line_to(cr, cx - 0.5, bubble.y + bubble.height + 3.8);
    c.cairo_line_to(cr, cx - 4.2, bubble.y + bubble.height - 0.8);
    c.cairo_close_path(cr);
    c.cairo_fill(cr);
}

fn drawHoverCapsule(cr: *c.cairo_t, rect: Rect, preferences: settings_model.PreferencesState) void {
    _ = preferences;
    drawRoundedRect(cr, rect, 9);
    c.cairo_set_source_rgba(cr, 0.86, 0.95, 1.0, 0.13);
    c.cairo_fill_preserve(cr);

    c.cairo_set_source_rgba(cr, 0.92, 0.98, 1.0, 0.08);
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
    c.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.040);
    c.cairo_fill(cr);
}

fn drawSpeakerGlyph(cr: *c.cairo_t, rect: Rect, muted: bool, alpha: f64) void {
    const cx = rect.x + rect.width / 2.0;
    const cy = rect.y + rect.height / 2.0;
    c.cairo_save(cr);
    defer c.cairo_restore(cr);

    c.cairo_set_line_width(cr, 1.8);
    c.cairo_set_line_cap(cr, c.CAIRO_LINE_CAP_ROUND);
    c.cairo_set_line_join(cr, c.CAIRO_LINE_JOIN_ROUND);
    c.cairo_set_source_rgba(cr, 0.94, 0.95, 0.97, alpha);

    c.cairo_new_path(cr);
    c.cairo_move_to(cr, cx - 7.6, cy - 2.8);
    c.cairo_line_to(cr, cx - 4.3, cy - 2.8);
    c.cairo_line_to(cr, cx - 0.2, cy - 6.6);
    c.cairo_line_to(cr, cx - 0.2, cy + 6.6);
    c.cairo_line_to(cr, cx - 4.3, cy + 2.8);
    c.cairo_line_to(cr, cx - 7.6, cy + 2.8);
    c.cairo_close_path(cr);
    c.cairo_stroke(cr);

    if (muted) {
        c.cairo_new_path(cr);
        c.cairo_move_to(cr, cx + 3.2, cy - 4.8);
        c.cairo_line_to(cr, cx + 8.0, cy + 4.8);
        c.cairo_move_to(cr, cx + 8.0, cy - 4.8);
        c.cairo_line_to(cr, cx + 3.2, cy + 4.8);
        c.cairo_stroke(cr);
        return;
    }

    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, cx + 1.4, cy, 3.6, -0.78, 0.78);
    c.cairo_stroke(cr);
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, cx + 2.2, cy, 5.8, -0.86, 0.86);
    c.cairo_stroke(cr);
}

fn drawBluetoothGlyph(cr: *c.cairo_t, rect: Rect, powered: bool, alpha: f64) void {
    const cx = rect.x + rect.width / 2.0;
    const cy = rect.y + rect.height / 2.0;
    c.cairo_save(cr);
    defer c.cairo_restore(cr);

    c.cairo_set_line_width(cr, 1.7);
    c.cairo_set_line_cap(cr, c.CAIRO_LINE_CAP_ROUND);
    c.cairo_set_line_join(cr, c.CAIRO_LINE_JOIN_ROUND);
    c.cairo_set_source_rgba(cr, 0.94, 0.95, 0.97, if (powered) alpha else 0.62);

    c.cairo_new_path(cr);
    c.cairo_move_to(cr, cx, cy - 8.4);
    c.cairo_line_to(cr, cx, cy + 8.4);
    c.cairo_move_to(cr, cx, cy - 8.4);
    c.cairo_line_to(cr, cx + 5.8, cy - 3.3);
    c.cairo_line_to(cr, cx - 0.9, cy + 0.1);
    c.cairo_line_to(cr, cx + 5.8, cy + 5.2);
    c.cairo_line_to(cr, cx, cy + 8.4);
    c.cairo_move_to(cr, cx, cy - 8.4);
    c.cairo_line_to(cr, cx - 5.8, cy - 3.3);
    c.cairo_line_to(cr, cx + 0.9, cy + 0.1);
    c.cairo_line_to(cr, cx - 5.8, cy + 5.2);
    c.cairo_line_to(cr, cx, cy + 8.4);
    c.cairo_stroke(cr);

    if (!powered) {
        c.cairo_new_path(cr);
        c.cairo_move_to(cr, cx - 8, cy - 8);
        c.cairo_line_to(cr, cx + 8, cy + 8);
        c.cairo_stroke(cr);
    }
}

fn drawWifiGlyph(cr: *c.cairo_t, rect: Rect, signal: u8, enabled: bool, alpha: f64) void {
    const cx = rect.x + rect.width / 2.0;
    const cy = rect.y + rect.height / 2.0 + 2;
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_set_line_width(cr, 1.8);
    c.cairo_set_line_cap(cr, c.CAIRO_LINE_CAP_ROUND);
    c.cairo_set_source_rgba(cr, 0.94, 0.95, 0.97, if (enabled) alpha else 0.55);

    if (enabled and signal > 20) {
        c.cairo_new_sub_path(cr);
        c.cairo_arc(cr, cx, cy, 8.5, -2.35, -0.8);
        c.cairo_stroke(cr);
    }
    if (enabled and signal > 45) {
        c.cairo_new_sub_path(cr);
        c.cairo_arc(cr, cx, cy, 6.0, -2.28, -0.86);
        c.cairo_stroke(cr);
    }
    if (enabled and signal > 70) {
        c.cairo_new_sub_path(cr);
        c.cairo_arc(cr, cx, cy, 3.5, -2.16, -0.98);
        c.cairo_stroke(cr);
    }
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, cx, cy + 1, 1.7, 0, 2.0 * pi);
    c.cairo_fill(cr);

    if (!enabled) {
        c.cairo_move_to(cr, cx - 8, cy - 8);
        c.cairo_line_to(cr, cx + 8, cy + 8);
        c.cairo_stroke(cr);
    }
}

fn drawEthernetGlyph(cr: *c.cairo_t, rect: Rect, alpha: f64) void {
    const x = rect.x + 10;
    const y = rect.y + 7;
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_set_line_width(cr, 1.8);
    c.cairo_set_line_cap(cr, c.CAIRO_LINE_CAP_ROUND);
    c.cairo_set_line_join(cr, c.CAIRO_LINE_JOIN_ROUND);
    c.cairo_set_source_rgba(cr, 0.94, 0.95, 0.97, alpha);

    c.cairo_new_path(cr);
    drawRoundedRect(cr, .{ .x = x, .y = y, .width = 16, .height = 12 }, 3);
    c.cairo_stroke(cr);
    c.cairo_move_to(cr, x + 5, y + 12);
    c.cairo_line_to(cr, x + 5, y + 16);
    c.cairo_move_to(cr, x + 11, y + 12);
    c.cairo_line_to(cr, x + 11, y + 16);
    c.cairo_move_to(cr, x + 8, y + 16);
    c.cairo_line_to(cr, x + 8, y + 20);
    c.cairo_stroke(cr);
}

fn drawBatteryGlyph(cr: *c.cairo_t, rect: Rect, state: battery.State, alpha: f64) void {
    const body = Rect{ .x = rect.x + 8, .y = rect.y + 8, .width = 18, .height = 12 };
    const cap = Rect{ .x = body.x + body.width, .y = body.y + 3, .width = 3, .height = 6 };

    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_new_path(cr);
    drawRoundedRect(cr, body, 2.5);
    c.cairo_set_source_rgba(cr, 0.94, 0.95, 0.97, alpha);
    c.cairo_set_line_width(cr, 1.5);
    c.cairo_stroke(cr);

    drawRoundedRect(cr, cap, 1.5);
    c.cairo_set_source_rgba(cr, 0.94, 0.95, 0.97, alpha);
    c.cairo_fill(cr);

    const fill_width = (body.width - 4) * (@as(f64, @floatFromInt(state.percentage)) / 100.0);
    drawRoundedRect(cr, .{ .x = body.x + 2, .y = body.y + 2, .width = fill_width, .height = body.height - 4 }, 1.5);
    c.cairo_set_source_rgba(cr, if (state.percentage > 20) 0.45 else 0.95, if (state.percentage > 20) 0.90 else 0.42, 0.94, 0.92);
    c.cairo_fill(cr);
}

fn drawPowerGlyph(cr: *c.cairo_t, rect: Rect, alpha: f64) void {
    const cx = rect.x + rect.width / 2.0;
    const cy = rect.y + rect.height / 2.0 + 0.4;
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_set_line_width(cr, 1.9);
    c.cairo_set_line_cap(cr, c.CAIRO_LINE_CAP_ROUND);
    c.cairo_set_source_rgba(cr, 0.94, 0.95, 0.97, alpha);
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, cx, cy, 8.0, -pi * 0.84, pi * 0.84);
    c.cairo_stroke(cr);
    c.cairo_new_path(cr);
    c.cairo_move_to(cr, cx, cy - 11);
    c.cairo_line_to(cr, cx, cy - 1.5);
    c.cairo_stroke(cr);
}

const pi = std.math.pi;

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
