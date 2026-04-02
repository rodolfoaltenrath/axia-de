const std = @import("std");
const c = @import("wl.zig").c;
const Rect = @import("render.zig").Rect;
const IpcWorkspaceState = @import("ipc.zig").WorkspaceState;
const IpcWorkspaceSummary = @import("ipc.zig").WorkspaceSummary;

pub const popup_width: u32 = 344;
pub const popup_height: u32 = 304;

const grid_top: f64 = 52;
const grid_left: f64 = 16;
const grid_gap: f64 = 12;
const card_width: f64 = 150;
const card_height: f64 = 96;

pub fn itemRect(index: usize) Rect {
    const col = index % 2;
    const row = index / 2;
    return .{
        .x = grid_left + @as(f64, @floatFromInt(col)) * (card_width + grid_gap),
        .y = grid_top + @as(f64, @floatFromInt(row)) * (card_height + grid_gap),
        .width = card_width,
        .height = card_height,
    };
}

pub fn hitTest(x: f64, y: f64, count: usize) ?usize {
    for (0..count) |index| {
        if (itemRect(index).contains(x, y)) return index;
    }
    return null;
}

pub fn drawPopup(cr: *c.cairo_t, width: u32, height: u32, state: IpcWorkspaceState) void {
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

    drawLabel(cr, 18, 28, 18, "Áreas de Trabalho", 0.96, 0.96, 0.97);
    drawLabel(cr, 18, 44, 12, "Clique para trocar. Botão do meio move a janela focada.", 0.72, 0.72, 0.75);

    for (0..state.count) |index| {
        drawWorkspaceCard(cr, itemRect(index), index, state.current, state.summaries[index]);
    }

    drawLabel(cr, 18, @as(f64, @floatFromInt(height)) - 16, 12, "Workspaces ativos mostram foco e preview da primeira janela.", 0.68, 0.68, 0.71);
}

fn drawWorkspaceCard(
    cr: *c.cairo_t,
    rect: Rect,
    index: usize,
    current: usize,
    summary: IpcWorkspaceSummary,
) void {
    drawRoundedRect(cr, rect, 12);
    if (index == current) {
        c.cairo_set_source_rgba(cr, 0.18, 0.56, 0.72, 0.92);
    } else {
        c.cairo_set_source_rgba(cr, 1, 1, 1, 0.05);
    }
    c.cairo_fill_preserve(cr);

    if (summary.focused) {
        c.cairo_set_source_rgba(cr, 0.58, 0.93, 1.0, 0.95);
    } else {
        c.cairo_set_source_rgba(cr, 1, 1, 1, 0.06);
    }
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);

    var title_buf: [32]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "Workspace {}", .{index + 1}) catch "Workspace";
    drawLabel(cr, rect.x + 12, rect.y + 18, 14, title, 0.95, 0.95, 0.97);

    var count_buf: [24]u8 = undefined;
    const count_label = std.fmt.bufPrint(&count_buf, "{d}", .{summary.window_count}) catch "0";
    drawBadge(cr, .{ .x = rect.x + rect.width - 28, .y = rect.y + 8, .width = 18, .height = 18 }, count_label);

    const preview_rect = Rect{
        .x = rect.x + 10,
        .y = rect.y + 26,
        .width = rect.width - 20,
        .height = 42,
    };
    drawMiniPreview(cr, preview_rect, summary);

    const preview_text = truncate(summary.previewText(), 22);
    const label = if (preview_text.len > 0) preview_text else "sem janelas";
    drawLabel(cr, rect.x + 12, rect.y + rect.height - 12, 11.5, label, 0.80, 0.80, 0.83);
}

fn drawMiniPreview(cr: *c.cairo_t, rect: Rect, summary: IpcWorkspaceSummary) void {
    drawRoundedRect(cr, rect, 10);
    c.cairo_set_source_rgba(cr, 0.06, 0.06, 0.07, 0.80);
    c.cairo_fill(cr);

    drawRoundedRect(cr, .{
        .x = rect.x + 6,
        .y = rect.y + 6,
        .width = rect.width - 12,
        .height = 9,
    }, 4);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.06);
    c.cairo_fill(cr);

    if (summary.window_count == 0) {
        drawLabel(cr, rect.x + 12, rect.y + 29, 11, "vazio", 0.48, 0.48, 0.52);
        return;
    }

    const window_count = @min(summary.window_count, 3);
    for (0..window_count) |window_index| {
        const offset = @as(f64, @floatFromInt(window_index)) * 9.0;
        const window_rect = Rect{
            .x = rect.x + 12 + offset,
            .y = rect.y + 18 + offset * 0.35,
            .width = rect.width - 32 - offset,
            .height = rect.height - 28 - offset * 0.2,
        };
        drawRoundedRect(cr, window_rect, 7);
        if (window_index == 0 and summary.focused) {
            c.cairo_set_source_rgba(cr, 0.58, 0.93, 1.0, 0.92);
        } else {
            c.cairo_set_source_rgba(cr, 0.88, 0.88, 0.92, 0.14 + @as(f64, @floatFromInt(window_count - window_index)) * 0.05);
        }
        c.cairo_fill(cr);

        drawRoundedRect(cr, .{
            .x = window_rect.x + 4,
            .y = window_rect.y + 4,
            .width = window_rect.width - 8,
            .height = 6,
        }, 3);
        c.cairo_set_source_rgba(cr, 0, 0, 0, 0.18);
        c.cairo_fill(cr);
    }
}

fn drawBadge(cr: *c.cairo_t, rect: Rect, label: []const u8) void {
    drawRoundedRect(cr, rect, 6);
    c.cairo_set_source_rgba(cr, 0, 0, 0, 0.20);
    c.cairo_fill(cr);
    drawCenteredLabel(cr, rect, 10.5, label, 0.95, 0.95, 0.97);
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
    drawLabel(cr, x, y, size, text, r, g, b);
}

fn truncate(text: []const u8, max_len: usize) []const u8 {
    if (text.len <= max_len) return text;
    if (max_len <= 1) return text[0..max_len];
    return text[0 .. max_len - 1];
}

const pi = 3.141592653589793;
