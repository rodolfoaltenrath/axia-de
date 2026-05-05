const c = @import("wl.zig").c;
const Rect = @import("render.zig").Rect;
const settings_model = @import("settings_model");
const popup_style = @import("popup_style.zig");

pub const popup_width: u32 = 340;
pub const popup_height: u32 = 244;

pub const Target = enum {
    settings,
    lock,
    logout,
    suspend_action,
    restart_action,
    poweroff_action,
};

pub fn hitTest(x: f64, y: f64) ?Target {
    if (settingsRect().contains(x, y)) return .settings;
    if (lockRect().contains(x, y)) return .lock;
    if (logoutRect().contains(x, y)) return .logout;
    if (actionRect(.suspend_action).contains(x, y)) return .suspend_action;
    if (actionRect(.restart_action).contains(x, y)) return .restart_action;
    if (actionRect(.poweroff_action).contains(x, y)) return .poweroff_action;
    return null;
}

pub fn drawPopup(cr: *c.cairo_t, width: u32, height: u32, preferences: settings_model.PreferencesState) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);

    popup_style.beginPanelPopup(cr, width, height, preferences);
    const accent = settings_model.accentSpec(preferences.accent).primary;

    drawMenuRow(cr, settingsRect(), "Configurações...", "", .settings, 0.92, 0.92, 0.95);
    drawDivider(cr, 18, 54, width);
    drawMenuRow(cr, lockRect(), "Bloquear Tela", "Super + Esc", .lock, 0.92, 0.92, 0.95);
    drawMenuRow(cr, logoutRect(), "Sair", "Super + Shift + Esc", .logout, 0.92, 0.92, 0.95);

    const actions = [_]Target{ .suspend_action, .restart_action, .poweroff_action };
    for (actions) |target| {
        const rect = actionRect(target);
        drawRoundedRect(cr, rect, 10);
        c.cairo_set_source_rgba(cr, 1, 1, 1, 0.06);
        c.cairo_fill(cr);
        drawActionIcon(cr, rect, target, accent);
    }
}

fn settingsRect() Rect {
    return .{ .x = 18, .y = 14, .width = @as(f64, @floatFromInt(popup_width)) - 36, .height = 28 };
}

fn lockRect() Rect {
    return .{ .x = 18, .y = 66, .width = @as(f64, @floatFromInt(popup_width)) - 36, .height = 28 };
}

fn logoutRect() Rect {
    return .{ .x = 18, .y = 102, .width = @as(f64, @floatFromInt(popup_width)) - 36, .height = 28 };
}

fn actionRect(target: Target) Rect {
        const index: usize = switch (target) {
        .suspend_action => 0,
        .restart_action => 1,
        .poweroff_action => 2,
        else => 0,
    };
    return .{
        .x = 24 + @as(f64, @floatFromInt(index)) * 104,
        .y = 158,
        .width = 88,
        .height = 68,
    };
}

fn drawMenuRow(cr: *c.cairo_t, rect: Rect, title: []const u8, shortcut: []const u8, icon: Target, r: f64, g: f64, b: f64) void {
    drawRowIcon(cr, .{ .x = rect.x, .y = rect.y + 2, .width = 24, .height = 24 }, icon);
    drawLabel(cr, rect.x + 34, rect.y + 18, 13.5, title, r, g, b);
    if (shortcut.len > 0) {
        drawLabel(cr, rect.x + rect.width - 100, rect.y + 18, 12.5, shortcut, 0.82, 0.82, 0.86);
    }
}

fn drawDivider(cr: *c.cairo_t, x: f64, y: f64, width: u32) void {
    c.cairo_rectangle(cr, x, y, @as(f64, @floatFromInt(width)) - x * 2.0, 1);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.10);
    c.cairo_fill(cr);
}

fn drawRowIcon(cr: *c.cairo_t, rect: Rect, target: Target) void {
    switch (target) {
        .settings => drawGearIcon(cr, rect),
        .lock => drawLockIcon(cr, rect),
        .logout => drawLogoutIcon(cr, rect),
        else => {},
    }
}

fn drawActionIcon(cr: *c.cairo_t, rect: Rect, target: Target, accent: [3]f64) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_set_source_rgba(cr, accent[0], accent[1], accent[2], 0.95);
    switch (target) {
        .suspend_action => drawMoonIcon(cr, rect),
        .restart_action => drawRestartIcon(cr, rect),
        .poweroff_action => drawPowerIcon(cr, rect),
        else => {},
    }
}

fn drawGearIcon(cr: *c.cairo_t, rect: Rect) void {
    const cx = rect.x + rect.width / 2.0;
    const cy = rect.y + rect.height / 2.0;
    c.cairo_set_line_width(cr, 1.7);
    c.cairo_set_source_rgba(cr, 0.92, 0.92, 0.95, 0.96);
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, cx, cy, 6, 0, 2.0 * pi);
    c.cairo_stroke(cr);
    for (0..6) |idx| {
        const angle = @as(f64, @floatFromInt(idx)) * (pi / 3.0);
        c.cairo_move_to(cr, cx + @cos(angle) * 8, cy + @sin(angle) * 8);
        c.cairo_line_to(cr, cx + @cos(angle) * 10.5, cy + @sin(angle) * 10.5);
        c.cairo_stroke(cr);
    }
}

fn drawLockIcon(cr: *c.cairo_t, rect: Rect) void {
    const x = rect.x + 6;
    const y = rect.y + 8;
    c.cairo_set_line_width(cr, 1.8);
    c.cairo_set_source_rgba(cr, 0.92, 0.92, 0.95, 0.96);
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, x + 6, y + 4, 4, pi, 0);
    c.cairo_stroke(cr);
    drawRoundedRect(cr, .{ .x = x, .y = y + 6, .width = 12, .height = 9 }, 2);
    c.cairo_stroke(cr);
}

fn drawLogoutIcon(cr: *c.cairo_t, rect: Rect) void {
    const cx = rect.x + rect.width / 2.0;
    const cy = rect.y + rect.height / 2.0;
    c.cairo_set_line_width(cr, 1.8);
    c.cairo_set_source_rgba(cr, 0.92, 0.92, 0.95, 0.96);
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, cx - 1, cy, 7, pi * 0.35, pi * 1.65);
    c.cairo_stroke(cr);
    c.cairo_move_to(cr, cx + 2, cy - 5);
    c.cairo_line_to(cr, cx + 8, cy);
    c.cairo_line_to(cr, cx + 2, cy + 5);
    c.cairo_stroke(cr);
}

fn drawMoonIcon(cr: *c.cairo_t, rect: Rect) void {
    const cx = rect.x + rect.width / 2.0;
    const cy = rect.y + rect.height / 2.0;
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, cx - 2, cy, 12, -pi / 2.0, pi / 2.0);
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, cx + 4, cy - 1, 10, pi / 2.0, -pi / 2.0);
    c.cairo_close_path(cr);
    c.cairo_fill(cr);
}

fn drawRestartIcon(cr: *c.cairo_t, rect: Rect) void {
    const cx = rect.x + rect.width / 2.0;
    const cy = rect.y + rect.height / 2.0;
    c.cairo_set_line_width(cr, 2.4);
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, cx, cy, 11, -pi * 0.1, pi * 1.1);
    c.cairo_stroke(cr);
    c.cairo_move_to(cr, cx - 3, cy - 13);
    c.cairo_line_to(cr, cx + 7, cy - 13);
    c.cairo_line_to(cr, cx + 2, cy - 5);
    c.cairo_stroke(cr);
}

fn drawPowerIcon(cr: *c.cairo_t, rect: Rect) void {
    const cx = rect.x + rect.width / 2.0;
    const cy = rect.y + rect.height / 2.0;
    c.cairo_set_line_width(cr, 2.6);
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, cx, cy, 12, -pi * 0.85, pi * 0.85);
    c.cairo_stroke(cr);
    c.cairo_move_to(cr, cx, cy - 16);
    c.cairo_line_to(cr, cx, cy - 1);
    c.cairo_stroke(cr);
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
