const std = @import("std");
const c = @import("wl.zig").c;
const audio = @import("audio.zig");
const Rect = @import("render.zig").Rect;
const settings_model = @import("settings_model");
const popup_style = @import("popup_style.zig");

pub const popup_width: u32 = 380;
pub const popup_height: u32 = 360;

pub const Target = union(enum) {
    sink_icon,
    sink_slider,
    source_icon,
    source_slider,
    sink_device: usize,
    source_device: usize,
};

const content_left = 22.0;
const slider_left = 56.0;
const slider_width = 208.0;
const percent_left = 302.0;
const sink_row_y = 28.0;
const source_row_y = 86.0;
const list_row_height = 34.0;
const list_gap = 8.0;
const list_start_x = 20.0;
const list_width = @as(f64, @floatFromInt(popup_width)) - 40.0;

pub fn hitTest(state: audio.State, x: f64, y: f64) ?Target {
    if (iconRect(sink_row_y).contains(x, y)) return .sink_icon;
    if (sliderTrackRect(sink_row_y).contains(x, y)) return .sink_slider;
    if (iconRect(source_row_y).contains(x, y)) return .source_icon;
    if (sliderTrackRect(source_row_y).contains(x, y)) return .source_slider;
    for (0..state.sinks.count) |index| {
        if (deviceRect(.sink, state, index).contains(x, y)) return .{ .sink_device = index };
    }
    for (0..state.sources.count) |index| {
        if (deviceRect(.source, state, index).contains(x, y)) return .{ .source_device = index };
    }
    return null;
}

pub fn sliderValue(target: Target, x: f64) ?f64 {
    const rect = switch (target) {
        .sink_slider => sliderTrackRect(sink_row_y),
        .source_slider => sliderTrackRect(source_row_y),
        else => return null,
    };
    return std.math.clamp((x - rect.x) / rect.width, 0.0, 1.0);
}

pub fn drawPopup(
    cr: *c.cairo_t,
    width: u32,
    height: u32,
    state: audio.State,
    preferences: settings_model.PreferencesState,
) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);

    popup_style.beginPanelPopup(cr, width, height, preferences);
    const accent = settings_model.accentSpec(preferences.accent).primary;

    if (!state.available) {
        drawLabel(cr, content_left, 38, 18, "Audio", 0.96, 0.96, 0.97);
        drawLabel(cr, content_left, 72, 15, "Nenhum dispositivo de audio foi encontrado.", 0.76, 0.76, 0.80);
        return;
    }

    drawDeviceRow(cr, state.sink, sink_row_y, true, accent);
    drawDeviceRow(cr, state.source, source_row_y, false, accent);

    c.cairo_rectangle(cr, 20, 126, @as(f64, @floatFromInt(width)) - 40, 1);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.10);
    c.cairo_fill(cr);

    drawSection(cr, "Saida", state.sink.descriptionText(), 150);
    drawSection(cr, "Entrada", state.source.descriptionText(), 198);
    drawDeviceList(cr, .sink, state, accent);
    drawDeviceList(cr, .source, state, accent);
}

fn drawDeviceRow(cr: *c.cairo_t, device: audio.DeviceState, y: f64, is_output: bool, accent: [3]f64) void {
    const icon_rect = iconRect(y);
    drawRoundedRect(cr, icon_rect, 9);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.05);
    c.cairo_fill(cr);

    if (is_output) {
        drawSpeakerIcon(cr, icon_rect, device.muted, 0.92, 0.92, 0.95);
    } else {
        drawMicIcon(cr, icon_rect, device.muted, 0.92, 0.92, 0.95);
    }

    const slider_rect = sliderTrackRect(y);
    drawSlider(cr, slider_rect, device.volume, device.muted, accent);

    var percent_buf: [8]u8 = undefined;
    const percent = std.fmt.bufPrint(&percent_buf, "{d}", .{device.percent()}) catch "0";
    drawCenteredLabel(
        cr,
        .{ .x = percent_left, .y = y, .width = 56, .height = 28 },
        16,
        percent,
        0.92,
        0.92,
        0.95,
    );
}

fn drawSection(cr: *c.cairo_t, title: []const u8, body: []const u8, y: f64) void {
    drawLabel(cr, content_left, y, 15, title, 0.90, 0.90, 0.92);
    drawLabel(cr, content_left, y + 24, 13, truncate(body, 38), 0.76, 0.76, 0.80);
}

fn drawDeviceList(cr: *c.cairo_t, kind: DeviceKind, state: audio.State, accent: [3]f64) void {
    const devices = switch (kind) {
        .sink => state.sinks,
        .source => state.sources,
    };
    if (devices.count == 0) return;

    for (devices.items[0..devices.count], 0..) |device, index| {
        const rect = deviceRect(kind, state, index);
        drawRoundedRect(cr, rect, 10);
        if (device.current) {
            c.cairo_set_source_rgba(cr, accent[0], accent[1], accent[2], 0.18);
        } else {
            c.cairo_set_source_rgba(cr, 1, 1, 1, 0.05);
        }
        c.cairo_fill_preserve(cr);
        c.cairo_set_source_rgba(cr, 1, 1, 1, if (device.current) 0.11 else 0.05);
        c.cairo_set_line_width(cr, 1);
        c.cairo_stroke(cr);

        if (device.current) {
            c.cairo_arc(cr, rect.x + 12, rect.y + rect.height / 2.0, 4, 0, 2.0 * pi);
            c.cairo_set_source_rgba(cr, accent[0], accent[1], accent[2], 0.96);
            c.cairo_fill(cr);
        }

        drawLabel(
            cr,
            rect.x + 24,
            rect.y + 21,
            13,
            truncate(device.labelText(), 42),
            0.89,
            0.89,
            0.92,
        );
    }
}

fn drawSlider(cr: *c.cairo_t, rect: Rect, value: f64, muted: bool, accent: [3]f64) void {
    const clamped = std.math.clamp(value, 0.0, 1.0);
    drawRoundedRect(cr, .{ .x = rect.x, .y = rect.y + 4, .width = rect.width, .height = 4 }, 2);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.22);
    c.cairo_fill(cr);

    const active_width = rect.width * clamped;
    if (active_width > 0.0) {
        drawRoundedRect(cr, .{ .x = rect.x, .y = rect.y + 4, .width = active_width, .height = 4 }, 2);
        c.cairo_set_source_rgba(cr, accent[0], accent[1], accent[2], if (muted) 0.38 else 0.92);
        c.cairo_fill(cr);
    }

    const thumb_x = rect.x + active_width;
    c.cairo_arc(cr, thumb_x, rect.y + 6, 10, 0, 2.0 * pi);
    c.cairo_set_source_rgba(cr, accent[0], accent[1], accent[2], if (muted) 0.65 else 1.0);
    c.cairo_fill_preserve(cr);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.12);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);
}

fn iconRect(y: f64) Rect {
    return .{ .x = content_left, .y = y, .width = 28, .height = 28 };
}

fn sliderTrackRect(y: f64) Rect {
    return .{ .x = slider_left, .y = y + 8, .width = slider_width, .height = 12 };
}

fn deviceRect(kind: DeviceKind, state: audio.State, index: usize) Rect {
    const start_y = switch (kind) {
        .sink => 238.0,
        .source => 238.0 + deviceListHeight(state.sinks.count) + 26.0,
    };
    return .{
        .x = list_start_x,
        .y = start_y + @as(f64, @floatFromInt(index)) * (list_row_height + list_gap),
        .width = list_width,
        .height = list_row_height,
    };
}

fn deviceListHeight(count: usize) f64 {
    if (count == 0) return 0;
    return @as(f64, @floatFromInt(count)) * list_row_height +
        @as(f64, @floatFromInt(count - 1)) * list_gap;
}

fn drawSpeakerIcon(cr: *c.cairo_t, rect: Rect, muted: bool, r: f64, g: f64, b: f64) void {
    const cx = rect.x + rect.width / 2.0;
    const cy = rect.y + rect.height / 2.0;
    c.cairo_set_line_width(cr, 2.2);
    c.cairo_set_line_cap(cr, c.CAIRO_LINE_CAP_ROUND);
    c.cairo_set_line_join(cr, c.CAIRO_LINE_JOIN_ROUND);
    c.cairo_set_source_rgb(cr, r, g, b);

    c.cairo_move_to(cr, cx - 8, cy - 3);
    c.cairo_line_to(cr, cx - 4, cy - 3);
    c.cairo_line_to(cr, cx + 1, cy - 8);
    c.cairo_line_to(cr, cx + 1, cy + 8);
    c.cairo_line_to(cr, cx - 4, cy + 3);
    c.cairo_line_to(cr, cx - 8, cy + 3);
    c.cairo_close_path(cr);
    c.cairo_stroke(cr);

    if (!muted) {
        c.cairo_arc(cr, cx + 2, cy, 5, -0.7, 0.7);
        c.cairo_stroke(cr);
        c.cairo_arc(cr, cx + 4, cy, 8, -0.75, 0.75);
        c.cairo_stroke(cr);
    } else {
        c.cairo_move_to(cr, cx + 4, cy - 6);
        c.cairo_line_to(cr, cx + 11, cy + 6);
        c.cairo_move_to(cr, cx + 11, cy - 6);
        c.cairo_line_to(cr, cx + 4, cy + 6);
        c.cairo_stroke(cr);
    }
}

fn drawMicIcon(cr: *c.cairo_t, rect: Rect, muted: bool, r: f64, g: f64, b: f64) void {
    const cx = rect.x + rect.width / 2.0;
    const cy = rect.y + rect.height / 2.0 - 1;
    c.cairo_set_line_width(cr, 2.1);
    c.cairo_set_line_cap(cr, c.CAIRO_LINE_CAP_ROUND);
    c.cairo_set_line_join(cr, c.CAIRO_LINE_JOIN_ROUND);
    c.cairo_set_source_rgb(cr, r, g, b);

    drawRoundedRect(cr, .{ .x = cx - 4.5, .y = cy - 7, .width = 9, .height = 14 }, 4.5);
    c.cairo_stroke(cr);

    c.cairo_move_to(cr, cx - 8, cy + 2);
    c.cairo_curve_to(cr, cx - 8, cy + 9, cx + 8, cy + 9, cx + 8, cy + 2);
    c.cairo_stroke(cr);

    c.cairo_move_to(cr, cx, cy + 10);
    c.cairo_line_to(cr, cx, cy + 14);
    c.cairo_move_to(cr, cx - 5, cy + 14);
    c.cairo_line_to(cr, cx + 5, cy + 14);
    c.cairo_stroke(cr);

    if (muted) {
        c.cairo_move_to(cr, cx - 10, cy - 8);
        c.cairo_line_to(cr, cx + 10, cy + 12);
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
    var text_buf: [64]u8 = undefined;
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
    if (max_len == 0) return "";
    return text[0..max_len];
}

fn toCString(buffer: []u8, text: []const u8) [:0]u8 {
    const max_len = @min(text.len, buffer.len - 1);
    @memcpy(buffer[0..max_len], text[0..max_len]);
    buffer[max_len] = 0;
    return buffer[0..max_len :0];
}

const DeviceKind = enum {
    sink,
    source,
};

const pi = std.math.pi;
