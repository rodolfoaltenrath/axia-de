const std = @import("std");
const c = @import("../wl.zig").c;
const model = @import("model.zig");

pub const panel_width: u32 = 760;
pub const panel_height: u32 = 500;

const card_width: f64 = 212;
const card_height: f64 = 154;
const grid_left: f64 = 36;
const grid_top: f64 = 138;
const grid_gap: f64 = 18;

pub const Rect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,

    pub fn contains(self: Rect, px: f64, py: f64) bool {
        return px >= self.x and px <= self.x + self.width and py >= self.y and py <= self.y + self.height;
    }
};

pub const Controls = struct {
    close: Rect,
};

pub const State = struct {
    page: model.Page,
    hovered_index: ?usize = null,
    current_wallpaper_path: ?[]const u8 = null,
};

pub fn controls() Controls {
    return .{
        .close = .{ .x = @as(f64, @floatFromInt(panel_width)) - 64, .y = 24, .width = 28, .height = 28 },
    };
}

pub fn wallpaperCardRect(index: usize) Rect {
    return .{
        .x = grid_left + @as(f64, @floatFromInt(index)) * (card_width + grid_gap),
        .y = grid_top,
        .width = card_width,
        .height = card_height,
    };
}

pub fn wallpaperHitTest(x: f64, y: f64) ?usize {
    for (model.wallpaper_presets, 0..) |_, index| {
        if (wallpaperCardRect(index).contains(x, y)) return index;
    }
    return null;
}

pub fn drawPanel(cr: *c.cairo_t, state: State) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);

    c.cairo_set_source_rgba(cr, 0, 0, 0, 0);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
    c.cairo_paint(cr);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);

    drawShadow(cr);

    const body = Rect{ .x = 12, .y = 12, .width = @as(f64, @floatFromInt(panel_width)) - 24, .height = @as(f64, @floatFromInt(panel_height)) - 24 };
    drawRoundedRect(cr, body, 22);
    c.cairo_set_source_rgba(cr, 0.08, 0.09, 0.10, 0.985);
    c.cairo_fill_preserve(cr);
    c.cairo_set_source_rgba(cr, 0.38, 0.82, 0.98, 0.30);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);

    const title, const subtitle = pageText(state.page);
    drawLabel(cr, 36, 50, 24, title, 0.97, 0.98, 0.99, c.CAIRO_FONT_WEIGHT_BOLD);
    drawLabel(cr, 36, 74, 14, subtitle, 0.70, 0.73, 0.78, c.CAIRO_FONT_WEIGHT_NORMAL);

    const close_rect = controls().close;
    drawRoundedRect(cr, close_rect, 8);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.06);
    c.cairo_fill(cr);
    drawCenteredLabel(cr, close_rect, 18, "×", 0.96, 0.96, 0.97);

    switch (state.page) {
        .wallpapers => drawWallpaperPage(cr, state),
        .appearance, .panel, .displays, .workspaces, .about => drawPlaceholderPage(cr, state.page),
    }
}

fn drawWallpaperPage(cr: *c.cairo_t, state: State) void {
    drawLabel(cr, 36, 108, 16, "Escolha um preset para aplicar imediatamente ao desktop.", 0.86, 0.87, 0.90, c.CAIRO_FONT_WEIGHT_NORMAL);

    for (model.wallpaper_presets, 0..) |preset, index| {
        const rect = wallpaperCardRect(index);
        const is_current = state.current_wallpaper_path != null and std.mem.eql(u8, state.current_wallpaper_path.?, preset.path);
        drawRoundedRect(cr, rect, 16);

        if (is_current) {
            c.cairo_set_source_rgba(cr, 0.17, 0.48, 0.62, 0.96);
        } else if (state.hovered_index != null and state.hovered_index.? == index) {
            c.cairo_set_source_rgba(cr, 1, 1, 1, 0.08);
        } else {
            c.cairo_set_source_rgba(cr, 1, 1, 1, 0.04);
        }
        c.cairo_fill_preserve(cr);
        c.cairo_set_source_rgba(cr, 1, 1, 1, if (is_current) 0.18 else 0.06);
        c.cairo_set_line_width(cr, 1);
        c.cairo_stroke(cr);

        const preview = Rect{ .x = rect.x + 14, .y = rect.y + 14, .width = rect.width - 28, .height = 86 };
        drawWallpaperPreview(cr, preview, preset.colors);

        drawLabel(cr, rect.x + 16, rect.y + 122, 16, preset.label, 0.95, 0.96, 0.97, c.CAIRO_FONT_WEIGHT_BOLD);
        drawLabel(cr, rect.x + 16, rect.y + 142, 12, preset.description, 0.74, 0.76, 0.80, c.CAIRO_FONT_WEIGHT_NORMAL);
    }
}

fn drawPlaceholderPage(cr: *c.cairo_t, page: model.Page) void {
    const rect = Rect{ .x = 36, .y = 138, .width = @as(f64, @floatFromInt(panel_width)) - 72, .height = 206 };
    drawRoundedRect(cr, rect, 18);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.045);
    c.cairo_fill(cr);

    const label = switch (page) {
        .appearance => "Esta tela será a próxima da fila.",
        .panel => "Aqui vamos configurar painel, relógio e launcher.",
        .displays => "Aqui vamos ajustar monitores e escala.",
        .workspaces => "Aqui vamos configurar áreas de trabalho.",
        .about => "Aqui vai entrar identidade e versão do Axia-DE.",
        else => "Em breve.",
    };
    drawLabel(cr, rect.x + 24, rect.y + 54, 18, "Em construção", 0.96, 0.97, 0.98, c.CAIRO_FONT_WEIGHT_BOLD);
    drawLabel(cr, rect.x + 24, rect.y + 84, 15, label, 0.78, 0.80, 0.84, c.CAIRO_FONT_WEIGHT_NORMAL);
}

fn pageText(page: model.Page) struct { []const u8, []const u8 } {
    return switch (page) {
        .wallpapers => .{ "Papel de Parede", "Biblioteca inicial de wallpapers do Axia-DE" },
        .appearance => .{ "Aparência", "Cores, contraste e polimento visual do desktop" },
        .panel => .{ "Painel Superior", "Organização, widgets e comportamento do topo" },
        .displays => .{ "Monitores", "Saídas, escala e posicionamento de telas" },
        .workspaces => .{ "Áreas de Trabalho", "Fluxo entre espaços e comportamento das janelas" },
        .about => .{ "Sobre o Axia-DE", "Informações da sessão e da identidade do projeto" },
    };
}

fn drawWallpaperPreview(cr: *c.cairo_t, rect: Rect, colors: [3][4]f64) void {
    drawRoundedRect(cr, rect, 12);
    c.cairo_clip(cr);

    const gradient = c.cairo_pattern_create_linear(rect.x, rect.y, rect.x + rect.width, rect.y + rect.height);
    defer c.cairo_pattern_destroy(gradient);
    c.cairo_pattern_add_color_stop_rgba(gradient, 0.0, colors[0][0], colors[0][1], colors[0][2], colors[0][3]);
    c.cairo_pattern_add_color_stop_rgba(gradient, 0.55, colors[1][0], colors[1][1], colors[1][2], colors[1][3]);
    c.cairo_pattern_add_color_stop_rgba(gradient, 1.0, colors[2][0], colors[2][1], colors[2][2], colors[2][3]);
    c.cairo_set_source(cr, gradient);
    c.cairo_rectangle(cr, rect.x, rect.y, rect.width, rect.height);
    c.cairo_fill(cr);

    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.08);
    c.cairo_rectangle(cr, rect.x, rect.y, rect.width, 18);
    c.cairo_fill(cr);

    c.cairo_set_source_rgba(cr, 0.45, 0.84, 0.98, 0.45);
    c.cairo_rectangle(cr, rect.x, rect.y + 28, rect.width, 2);
    c.cairo_fill(cr);

    c.cairo_reset_clip(cr);
}

fn drawShadow(cr: *c.cairo_t) void {
    drawRoundedRect(cr, .{ .x = 18, .y = 24, .width = @as(f64, @floatFromInt(panel_width)) - 36, .height = @as(f64, @floatFromInt(panel_height)) - 28 }, 24);
    c.cairo_set_source_rgba(cr, 0, 0, 0, 0.30);
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

fn drawLabel(
    cr: *c.cairo_t,
    x: f64,
    y: f64,
    size: f64,
    text: []const u8,
    r: f64,
    g: f64,
    b: f64,
    weight: u32,
) void {
    var text_buf: [192]u8 = undefined;
    const max_len = @min(text.len, text_buf.len - 1);
    @memcpy(text_buf[0..max_len], text[0..max_len]);
    text_buf[max_len] = 0;

    c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, weight);
    c.cairo_set_font_size(cr, size);
    c.cairo_set_source_rgb(cr, r, g, b);
    c.cairo_move_to(cr, x, y);
    c.cairo_show_text(cr, text_buf[0..max_len :0].ptr);
}

fn drawCenteredLabel(cr: *c.cairo_t, rect: Rect, size: f64, text: []const u8, r: f64, g: f64, b: f64) void {
    var text_buf: [64]u8 = undefined;
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
    drawLabel(cr, x, y, size, text, r, g, b, c.CAIRO_FONT_WEIGHT_NORMAL);
}
