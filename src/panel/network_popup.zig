const std = @import("std");
const c = @import("wl.zig").c;
const network = @import("network.zig");
const Rect = @import("render.zig").Rect;
const settings_model = @import("settings_model");
const popup_style = @import("popup_style.zig");

pub const popup_width: u32 = 380;
pub const popup_height: u32 = 360;

pub const Target = union(enum) {
    wifi_toggle,
    network: usize,
};

pub fn hitTest(state: network.State, x: f64, y: f64) ?Target {
    if (toggleRect().contains(x, y)) return .wifi_toggle;
    for (0..state.networks.count) |index| {
        if (networkRect(index).contains(x, y)) return .{ .network = index };
    }
    return null;
}

pub fn drawPopup(
    cr: *c.cairo_t,
    width: u32,
    height: u32,
    state: network.State,
    preferences: settings_model.PreferencesState,
) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);

    popup_style.beginPanelPopup(cr, width, height, preferences);
    const accent = settings_model.accentSpec(preferences.accent).primary;

    drawNetworkIcon(cr, .{ .x = 22, .y = 20, .width = 28, .height = 28 }, state, 0.94);
    drawLabel(cr, 60, 39, 18, "Rede", 0.96, 0.96, 0.97);
    drawLabel(cr, 60, 60, 13, stateLine(state), 0.74, 0.74, 0.79);
    drawToggle(cr, toggleRect(), state.wifi_enabled and state.wifi_supported, accent);

    c.cairo_rectangle(cr, 20, 88, @as(f64, @floatFromInt(width)) - 40, 1);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.10);
    c.cairo_fill(cr);

    drawLabel(cr, 22, 116, 15, "Conexao atual", 0.92, 0.92, 0.95);
    drawStatusCard(cr, .{ .x = 20, .y = 126, .width = @as(f64, @floatFromInt(width)) - 40, .height = 58 }, state, accent);

    drawLabel(cr, 22, 208, 15, "Wi-Fi", 0.92, 0.92, 0.95);
    if (!state.wifi_supported) {
        drawLabel(cr, 22, 238, 13, "Este equipamento nao tem Wi-Fi.", 0.72, 0.72, 0.76);
        return;
    }
    if (!state.wifi_enabled) {
        drawLabel(cr, 22, 238, 13, "Ative o Wi-Fi para ver redes disponiveis.", 0.72, 0.72, 0.76);
        return;
    }
    if (state.networks.count == 0) {
        drawLabel(cr, 22, 238, 13, "Nenhuma rede encontrada agora.", 0.72, 0.72, 0.76);
        return;
    }

    for (state.networks.items[0..state.networks.count], 0..) |item, index| {
        const rect = networkRect(index);
        drawRoundedRect(cr, rect, 10);
        if (item.active) {
            c.cairo_set_source_rgba(cr, accent[0], accent[1], accent[2], 0.17);
        } else {
            c.cairo_set_source_rgba(cr, 1, 1, 1, 0.05);
        }
        c.cairo_fill_preserve(cr);
        c.cairo_set_source_rgba(cr, 1, 1, 1, if (item.active) 0.12 else 0.05);
        c.cairo_set_line_width(cr, 1);
        c.cairo_stroke(cr);

        if (item.active) {
            c.cairo_arc(cr, rect.x + 14, rect.y + rect.height / 2.0, 4, 0, 2.0 * pi);
            c.cairo_set_source_rgba(cr, accent[0], accent[1], accent[2], 0.96);
            c.cairo_fill(cr);
        }

        drawLabel(cr, rect.x + 26, rect.y + 20, 13.5, truncate(item.ssidText(), 30), 0.91, 0.91, 0.94);
        var meta_buf: [32]u8 = undefined;
        const meta = std.fmt.bufPrint(&meta_buf, "{d}%{s}", .{ item.signal, if (item.secure) " • protegido" else "" }) catch "";
        drawLabel(cr, rect.x + 26, rect.y + 38, 11.5, meta, 0.72, 0.72, 0.76);
        drawWifiBars(cr, .{ .x = rect.x + rect.width - 28, .y = rect.y + 14, .width = 16, .height = 18 }, item.signal, 0.82);
    }
}

fn stateLine(state: network.State) []const u8 {
    if (state.ethernet_connected) return "Ethernet conectada";
    if (state.wifi_connected) return "Wi-Fi conectado";
    if (state.wifi_enabled) return "Sem conexao ativa";
    return "Wi-Fi desligado";
}

fn toggleRect() Rect {
    return .{ .x = @as(f64, @floatFromInt(popup_width)) - 78, .y = 26, .width = 52, .height = 28 };
}

fn networkRect(index: usize) Rect {
    return .{
        .x = 20,
        .y = 218 + @as(f64, @floatFromInt(index)) * 54,
        .width = @as(f64, @floatFromInt(popup_width)) - 40,
        .height = 44,
    };
}

fn drawStatusCard(cr: *c.cairo_t, rect: Rect, state: network.State, accent: [3]f64) void {
    drawRoundedRect(cr, rect, 12);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.05);
    c.cairo_fill_preserve(cr);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.05);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);

    if (state.ethernet_connected) {
        drawLabel(cr, rect.x + 16, rect.y + 22, 13.5, "Ethernet", accent[0], accent[1], accent[2]);
        drawLabel(cr, rect.x + 16, rect.y + 42, 12, truncate(state.ethernetConnection(), 34), 0.76, 0.76, 0.80);
    } else if (state.wifi_connected) {
        drawLabel(cr, rect.x + 16, rect.y + 22, 13.5, "Wi-Fi", accent[0], accent[1], accent[2]);
        drawLabel(cr, rect.x + 16, rect.y + 42, 12, truncate(state.activeConnection(), 34), 0.76, 0.76, 0.80);
    } else {
        drawLabel(cr, rect.x + 16, rect.y + 22, 13.5, "Nenhuma conexao ativa", 0.90, 0.90, 0.93);
        drawLabel(cr, rect.x + 16, rect.y + 42, 12, "Use o Wi-Fi ou conecte um cabo de rede.", 0.72, 0.72, 0.76);
    }
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

fn drawNetworkIcon(cr: *c.cairo_t, rect: Rect, state: network.State, alpha: f64) void {
    if (state.ethernet_connected) {
        drawEthernetIcon(cr, rect, alpha);
        return;
    }
    drawWifiIcon(cr, rect, if (state.wifi_connected) 82 else 0, state.wifi_enabled, alpha);
}

fn drawWifiIcon(cr: *c.cairo_t, rect: Rect, signal: u8, enabled: bool, alpha: f64) void {
    const cx = rect.x + rect.width / 2.0;
    const cy = rect.y + rect.height / 2.0 + 2;
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_set_line_width(cr, 1.8);
    c.cairo_set_line_cap(cr, c.CAIRO_LINE_CAP_ROUND);
    c.cairo_set_source_rgba(cr, 0.94, 0.95, 0.97, if (enabled) alpha else 0.55);

    if (enabled and signal > 20) {
        c.cairo_arc(cr, cx, cy, 8.5, -2.35, -0.8);
        c.cairo_stroke(cr);
    }
    if (enabled and signal > 45) {
        c.cairo_arc(cr, cx, cy, 6.0, -2.28, -0.86);
        c.cairo_stroke(cr);
    }
    if (enabled and signal > 70) {
        c.cairo_arc(cr, cx, cy, 3.5, -2.16, -0.98);
        c.cairo_stroke(cr);
    }
    c.cairo_arc(cr, cx, cy + 1, 1.7, 0, 2.0 * pi);
    c.cairo_fill(cr);

    if (!enabled) {
        c.cairo_move_to(cr, cx - 9, cy - 8);
        c.cairo_line_to(cr, cx + 9, cy + 8);
        c.cairo_stroke(cr);
    }
}

fn drawEthernetIcon(cr: *c.cairo_t, rect: Rect, alpha: f64) void {
    const x = rect.x + 6;
    const y = rect.y + 7;
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_set_line_width(cr, 1.8);
    c.cairo_set_line_cap(cr, c.CAIRO_LINE_CAP_ROUND);
    c.cairo_set_line_join(cr, c.CAIRO_LINE_JOIN_ROUND);
    c.cairo_set_source_rgba(cr, 0.94, 0.95, 0.97, alpha);

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

fn drawWifiBars(cr: *c.cairo_t, rect: Rect, signal: u8, alpha: f64) void {
    const base_y = rect.y + rect.height;
    const thresholds = [_]u8{ 20, 40, 60, 80 };
    for (thresholds, 0..) |threshold, index| {
        const height = 4.0 + @as(f64, @floatFromInt(index)) * 3.0;
        const x = rect.x + @as(f64, @floatFromInt(index)) * 4.0;
        drawRoundedRect(cr, .{ .x = x, .y = base_y - height, .width = 3, .height = height }, 1.5);
        c.cairo_set_source_rgba(cr, 0.94, 0.95, 0.97, if (signal >= threshold) alpha else 0.20);
        c.cairo_fill(cr);
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
