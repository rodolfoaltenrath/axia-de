const std = @import("std");
const c = @import("wl.zig").c;
const bluetooth = @import("bluetooth.zig");
const Rect = @import("render.zig").Rect;
const settings_model = @import("settings_model");

pub const popup_width: u32 = 380;
pub const popup_height: u32 = 332;

pub const Target = union(enum) {
    power_toggle,
    device: usize,
};

pub fn hitTest(state: bluetooth.State, x: f64, y: f64) ?Target {
    if (powerButtonRect().contains(x, y)) return .power_toggle;
    for (0..state.devices.count) |index| {
        if (deviceRect(index).contains(x, y)) return .{ .device = index };
    }
    return null;
}

pub fn drawPopup(
    cr: *c.cairo_t,
    width: u32,
    height: u32,
    state: bluetooth.State,
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

    if (!state.available) {
        drawLabel(cr, 22, 38, 18, "Bluetooth", 0.96, 0.96, 0.97);
        drawLabel(cr, 22, 72, 14, "Nenhum adaptador Bluetooth foi encontrado.", 0.76, 0.76, 0.80);
        return;
    }

    drawBluetoothIcon(cr, .{ .x = 22, .y = 20, .width = 28, .height = 28 }, state.powered, 0.94);
    drawLabel(cr, 60, 39, 18, "Bluetooth", 0.96, 0.96, 0.97);
    drawLabel(cr, 60, 60, 13, stateLine(state), 0.74, 0.74, 0.79);
    drawPowerButton(cr, powerButtonRect(), state.powered, accent);

    c.cairo_rectangle(cr, 20, 88, @as(f64, @floatFromInt(width)) - 40, 1);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.10);
    c.cairo_fill(cr);

    drawLabel(cr, 22, 116, 15, "Dispositivos", 0.92, 0.92, 0.95);
    if (state.devices.count == 0) {
        drawLabel(cr, 22, 146, 13, "Nenhum dispositivo conhecido ainda.", 0.72, 0.72, 0.76);
        if (!state.powered) {
            drawLabel(cr, 22, 168, 13, "Ligue o Bluetooth para procurar e conectar depois.", 0.66, 0.66, 0.70);
        }
        return;
    }

    for (state.devices.items[0..state.devices.count], 0..) |device, index| {
        const rect = deviceRect(index);
        drawRoundedRect(cr, rect, 10);
        if (device.connected) {
            c.cairo_set_source_rgba(cr, accent[0], accent[1], accent[2], 0.17);
        } else {
            c.cairo_set_source_rgba(cr, 1, 1, 1, 0.05);
        }
        c.cairo_fill_preserve(cr);
        c.cairo_set_source_rgba(cr, 1, 1, 1, if (device.connected) 0.12 else 0.05);
        c.cairo_set_line_width(cr, 1);
        c.cairo_stroke(cr);

        if (device.connected) {
            c.cairo_arc(cr, rect.x + 14, rect.y + rect.height / 2.0, 4, 0, 2.0 * pi);
            c.cairo_set_source_rgba(cr, accent[0], accent[1], accent[2], 0.96);
            c.cairo_fill(cr);
        }

        drawLabel(cr, rect.x + 26, rect.y + 21, 13.5, truncate(device.nameText(), 32), 0.91, 0.91, 0.94);
        drawLabel(cr, rect.x + 26, rect.y + 39, 11.5, deviceStatusLine(device), 0.72, 0.72, 0.76);
    }
}

fn powerButtonRect() Rect {
    return .{ .x = @as(f64, @floatFromInt(popup_width)) - 78, .y = 26, .width = 52, .height = 28 };
}

fn deviceRect(index: usize) Rect {
    return .{
        .x = 20,
        .y = 130 + @as(f64, @floatFromInt(index)) * 56,
        .width = @as(f64, @floatFromInt(popup_width)) - 40,
        .height = 46,
    };
}

fn drawPowerButton(cr: *c.cairo_t, rect: Rect, powered: bool, accent: [3]f64) void {
    drawRoundedRect(cr, rect, 10);
    if (powered) {
        c.cairo_set_source_rgba(cr, accent[0], accent[1], accent[2], 0.92);
    } else {
        c.cairo_set_source_rgba(cr, 1, 1, 1, 0.10);
    }
    c.cairo_fill(cr);

    const knob_x = if (powered) rect.x + 28 else rect.x + 4;
    drawRoundedRect(cr, .{ .x = knob_x, .y = rect.y + 4, .width = 20, .height = 20 }, 10);
    c.cairo_set_source_rgba(cr, 0.98, 0.99, 1.0, 0.96);
    c.cairo_fill(cr);
}

fn stateLine(state: bluetooth.State) []const u8 {
    if (state.hard_blocked) return "Bloqueado por hardware";
    if (state.soft_blocked) return "Bloqueado no sistema";
    if (!state.powered) return "Desligado";
    if (state.discovering) return "Procurando dispositivos";
    return "Ligado";
}

fn deviceStatusLine(device: bluetooth.DeviceState) []const u8 {
    if (device.connected) return "Conectado";
    if (device.paired and device.trusted) return "Pareado e confiavel";
    if (device.paired) return "Pareado";
    return "Disponivel";
}

fn drawBluetoothIcon(cr: *c.cairo_t, rect: Rect, powered: bool, alpha: f64) void {
    const cx = rect.x + rect.width / 2.0;
    const cy = rect.y + rect.height / 2.0;
    c.cairo_save(cr);
    defer c.cairo_restore(cr);

    c.cairo_set_line_width(cr, 1.9);
    c.cairo_set_line_cap(cr, c.CAIRO_LINE_CAP_ROUND);
    c.cairo_set_line_join(cr, c.CAIRO_LINE_JOIN_ROUND);
    c.cairo_set_source_rgba(cr, 0.94, 0.95, 0.97, alpha);

    c.cairo_move_to(cr, cx, cy - 10);
    c.cairo_line_to(cr, cx, cy + 10);
    c.cairo_move_to(cr, cx, cy - 10);
    c.cairo_line_to(cr, cx + 7, cy - 3.5);
    c.cairo_line_to(cr, cx - 2, cy + 1);
    c.cairo_line_to(cr, cx + 7, cy + 7.5);
    c.cairo_line_to(cr, cx, cy + 10);
    c.cairo_move_to(cr, cx, cy - 10);
    c.cairo_line_to(cr, cx - 7, cy - 3.5);
    c.cairo_line_to(cr, cx + 2, cy + 1);
    c.cairo_line_to(cr, cx - 7, cy + 7.5);
    c.cairo_line_to(cr, cx, cy + 10);
    c.cairo_stroke(cr);

    if (!powered) {
        c.cairo_move_to(cr, cx - 9, cy - 10);
        c.cairo_line_to(cr, cx + 9, cy + 10);
        c.cairo_stroke(cr);
    }
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
    var text_buf: [160]u8 = undefined;
    const c_text = toCString(&text_buf, text);
    c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
    c.cairo_set_font_size(cr, size);
    c.cairo_set_source_rgb(cr, r, g, b);
    c.cairo_move_to(cr, x, y);
    c.cairo_show_text(cr, c_text.ptr);
}

fn drawCenteredLabel(cr: *c.cairo_t, rect: Rect, size: f64, text: []const u8, r: f64, g: f64, b: f64) void {
    var text_buf: [96]u8 = undefined;
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

fn truncate(text: []const u8, max_len: usize) []const u8 {
    if (text.len <= max_len) return text;
    return text[0..max_len];
}

fn toCString(buffer: []u8, text: []const u8) [:0]u8 {
    const max_len = @min(text.len, buffer.len - 1);
    @memcpy(buffer[0..max_len], text[0..max_len]);
    buffer[max_len] = 0;
    return buffer[0..max_len :0];
}

const pi = std.math.pi;
