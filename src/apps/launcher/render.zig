const std = @import("std");
const c = @import("client_wl").c;
const chrome = @import("client_chrome");
const model = @import("model.zig");

pub const Rect = chrome.Rect;

pub fn visibleResultLimit(height: u32) usize {
    const total_height = @as(i32, @intCast(height));
    const available = total_height - 180;
    if (available <= 0) return 1;
    return @max(1, @as(usize, @intCast(@divTrunc(available, 60))));
}

pub fn cardRect(width: u32, height: u32, has_query: bool, result_count: usize) Rect {
    const total_width = @as(f64, @floatFromInt(width));
    const total_height = @as(f64, @floatFromInt(height));
    const card_width = @min(total_width - 56.0, 664.0);
    const top_margin = 24.0;
    const bottom_margin = 24.0;
    const visible_results = @min(result_count, visibleResultLimit(height));
    const desired_height = if (!has_query)
        98.0
    else if (visible_results == 0)
        186.0
    else
        108.0 + @as(f64, @floatFromInt(visible_results)) * 60.0 + 24.0;
    const min_height: f64 = if (!has_query) 98.0 else 214.0;
    const card_height = @min(total_height - top_margin - bottom_margin, @max(min_height, desired_height));
    return .{
        .x = (total_width - card_width) / 2.0,
        .y = top_margin,
        .width = card_width,
        .height = card_height,
    };
}

pub fn searchRect(width: u32, height: u32, has_query: bool, result_count: usize) Rect {
    const card = cardRect(width, height, has_query, result_count);
    return .{
        .x = card.x + 28,
        .y = card.y + 22,
        .width = card.width - 56,
        .height = 44,
    };
}

pub fn resultRect(width: u32, height: u32, result_count: usize, index: usize) Rect {
    const has_query = result_count > 0;
    const card = cardRect(width, height, has_query, result_count);
    return .{
        .x = card.x + 28,
        .y = searchRect(width, height, has_query, result_count).y + 58.0 + @as(f64, @floatFromInt(index)) * 60.0,
        .width = card.width - 56,
        .height = 54,
    };
}

pub fn hitTest(width: u32, height: u32, x: f64, y: f64, snapshot: model.Snapshot) ?usize {
    for (0..snapshot.count) |index| {
        if (resultRect(width, height, snapshot.count, index).contains(x, y)) return index;
    }
    return null;
}

pub fn draw(cr: *c.cairo_t, width: u32, height: u32, snapshot: model.Snapshot, hovered: ?usize) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);

    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
    c.cairo_set_source_rgba(cr, 0, 0, 0, 0);
    c.cairo_paint(cr);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);

    const has_query = snapshot.query.len > 0;
    const card = cardRect(width, height, has_query, snapshot.count);

    drawRoundedRect(cr, card, 20);
    c.cairo_set_source_rgba(cr, 0.12, 0.12, 0.125, 0.965);
    c.cairo_fill_preserve(cr);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.07);
    c.cairo_set_line_width(cr, 1.0);
    c.cairo_stroke(cr);

    const search = searchRect(width, height, has_query, snapshot.count);
    drawRoundedRect(cr, search, 10);
    c.cairo_set_source_rgba(cr, 0.10, 0.10, 0.105, 0.95);
    c.cairo_fill_preserve(cr);
    c.cairo_set_source_rgba(cr, 0.36, 0.92, 1.0, 0.90);
    c.cairo_set_line_width(cr, 1.7);
    c.cairo_stroke(cr);

    drawSearchGlyph(cr, .{
        .x = search.x + 14,
        .y = search.y + 11,
        .width = 20,
        .height = 20,
    });

    const placeholder = "Digite para procurar aplicativos ou configurações...";
    const query = if (snapshot.query.len > 0) snapshot.query else placeholder;
    const query_color: [3]f64 = if (snapshot.query.len > 0) .{ 0.95, 0.96, 0.98 } else .{ 0.62, 0.64, 0.68 };
    drawLabel(cr, search.x + 48, search.y + 29, 15, query, query_color[0], query_color[1], query_color[2]);

    if (!has_query) return;

    if (snapshot.count == 0) {
        drawLabel(cr, card.x + 34, search.y + 90, 16, "Nenhum resultado encontrado", 0.92, 0.93, 0.95);
        drawLabel(cr, card.x + 34, search.y + 116, 14, "Tente outro nome, aplicativo ou ajuste do sistema.", 0.67, 0.69, 0.73);
        return;
    }

    for (0..snapshot.count) |index| {
        const rect = resultRect(width, height, snapshot.count, index);
        const selected = snapshot.selected != null and snapshot.selected.? == index;
        const is_hovered = hovered != null and hovered.? == index;
        drawResultRow(cr, rect, snapshot.entries[index], selected, is_hovered);
    }
}

fn drawResultRow(cr: *c.cairo_t, rect: Rect, entry: model.EntryView, selected: bool, hovered: bool) void {
    if (selected or hovered) {
        drawRoundedRect(cr, rect, 10);
        c.cairo_set_source_rgba(cr, 1, 1, 1, if (selected) 0.08 else 0.05);
        c.cairo_fill(cr);
    }

    const icon_rect = Rect{
        .x = rect.x + 16,
        .y = rect.y + 11,
        .width = 36,
        .height = 36,
    };
    drawRoundedRect(cr, icon_rect, 10);
    c.cairo_set_source_rgba(cr, entry.accent[0], entry.accent[1], entry.accent[2], if (entry.enabled) 0.22 else 0.14);
    c.cairo_fill(cr);
    drawCenteredLabel(cr, icon_rect, if (entry.monogram.len > 1) 12 else 16, entry.monogram, if (entry.enabled) 0.97 else 0.76, if (entry.enabled) 0.98 else 0.78, if (entry.enabled) 1.0 else 0.82);

    drawLabel(cr, rect.x + 66, rect.y + 25, 15, entry.label, if (entry.enabled) 0.96 else 0.78, if (entry.enabled) 0.97 else 0.80, if (entry.enabled) 0.99 else 0.83);
    drawLabel(cr, rect.x + 66, rect.y + 44, 13, entry.subtitle, if (entry.enabled) 0.74 else 0.58, if (entry.enabled) 0.76 else 0.60, if (entry.enabled) 0.79 else 0.64);
    if (entry.enabled) {
        drawLabel(cr, rect.x + rect.width - 72, rect.y + 25, 13, entry.shortcut, 0.78, 0.80, 0.84);
    } else {
        drawLabel(cr, rect.x + rect.width - 84, rect.y + 25, 13, "Em breve", 0.46, 0.78, 0.90);
    }
}

fn drawSearchGlyph(cr: *c.cairo_t, rect: Rect) void {
    const cx = rect.x + 8;
    const cy = rect.y + 8;
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_set_source_rgba(cr, 0.90, 0.91, 0.94, 0.96);
    c.cairo_set_line_width(cr, 2.0);
    c.cairo_arc(cr, cx, cy, 5.2, 0, std.math.pi * 2.0);
    c.cairo_stroke(cr);
    c.cairo_move_to(cr, cx + 3.7, cy + 3.7);
    c.cairo_line_to(cr, cx + 9.5, cy + 9.5);
    c.cairo_stroke(cr);
}

fn drawRoundedRect(cr: *c.cairo_t, rect: Rect, radius: f64) void {
    chrome.drawRoundedRect(cr, rect, radius);
}

fn drawLabel(cr: *c.cairo_t, x: f64, y: f64, size: f64, text: []const u8, r: f64, g: f64, b: f64) void {
    chrome.drawLabel(cr, x, y, size, text, r, g, b, c.CAIRO_FONT_WEIGHT_NORMAL);
}

fn drawCenteredLabel(cr: *c.cairo_t, rect: Rect, size: f64, text: []const u8, r: f64, g: f64, b: f64) void {
    chrome.drawCenteredLabel(cr, rect, size, text, r, g, b);
}
