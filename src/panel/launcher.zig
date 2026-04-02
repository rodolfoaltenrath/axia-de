const c = @import("wl.zig").c;
const Rect = @import("render.zig").Rect;

pub const popup_width: u32 = 280;
pub const popup_height: u32 = 182;
const row_height: f64 = 44;

pub const AppEntry = struct {
    label: []const u8,
    command: []const u8,
};

pub const entries = [_]AppEntry{
    .{ .label = "Terminal", .command = "command -v cosmic-terminal >/dev/null 2>&1 && exec cosmic-terminal || exec alacritty" },
    .{ .label = "Firefox", .command = "firefox" },
    .{ .label = "Arquivos", .command = "command -v cosmic-files >/dev/null 2>&1 && exec cosmic-files || exec xdg-open \"$HOME\"" },
};

pub fn itemRect(index: usize) Rect {
    return .{
        .x = 16,
        .y = 20 + @as(f64, @floatFromInt(index)) * row_height,
        .width = @as(f64, @floatFromInt(popup_width)) - 32,
        .height = 34,
    };
}

pub fn hitTest(x: f64, y: f64) ?usize {
    for (entries, 0..) |_, index| {
        if (itemRect(index).contains(x, y)) return index;
    }
    return null;
}

pub fn drawPopup(cr: *c.cairo_t, width: u32, height: u32) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);

    c.cairo_set_source_rgba(cr, 0, 0, 0, 0);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
    c.cairo_paint(cr);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);

    drawRoundedRect(cr, .{ .x = 0, .y = 0, .width = @floatFromInt(width), .height = @floatFromInt(height) }, 14);
    c.cairo_set_source_rgba(cr, 0.10, 0.10, 0.11, 0.98);
    c.cairo_fill_preserve(cr);
    c.cairo_set_source_rgba(cr, 0.33, 0.75, 0.94, 0.35);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);

    drawLabel(cr, 18, 28, 18, "Aplicativos", 0.96, 0.96, 0.97);

    for (entries, 0..) |entry, index| {
        const rect = itemRect(index);
        drawRoundedRect(cr, rect, 10);
        c.cairo_set_source_rgba(cr, 1, 1, 1, 0.05);
        c.cairo_fill(cr);
        drawLabel(cr, rect.x + 14, rect.y + 22, 16, entry.label, 0.92, 0.92, 0.94);
    }
}

fn drawRoundedRect(cr: *c.cairo_t, rect: Rect, radius: f64) void {
    const right = rect.x + rect.width;
    const bottom = rect.y + rect.height;

    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, right - radius, rect.y + radius, radius, -std_math_pi / 2.0, 0);
    c.cairo_arc(cr, right - radius, bottom - radius, radius, 0, std_math_pi / 2.0);
    c.cairo_arc(cr, rect.x + radius, bottom - radius, radius, std_math_pi / 2.0, std_math_pi);
    c.cairo_arc(cr, rect.x + radius, rect.y + radius, radius, std_math_pi, 3.0 * std_math_pi / 2.0);
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

const std_math_pi = 3.141592653589793;
