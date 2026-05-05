const std = @import("std");
const c = @import("client_wl").c;
const chrome = @import("client_chrome");
const icons = @import("icons.zig");
const model = @import("model.zig");

pub const Rect = chrome.Rect;

const search_height: f64 = 46.0;
const tile_width: f64 = 132.0;
const tile_height: f64 = 122.0;
const tile_gap_x: f64 = 18.0;
const tile_gap_y: f64 = 18.0;

pub fn cardRect(width: u32, height: u32) Rect {
    const total_width = @as(f64, @floatFromInt(width));
    const total_height = @as(f64, @floatFromInt(height));
    const horizontal_margin: f64 = if (total_width < 560.0) 24.0 else 72.0;
    const vertical_margin: f64 = if (total_height < 520.0) 36.0 else 60.0;
    const card_width = @max(1.0, total_width - horizontal_margin);
    const card_height = @max(1.0, total_height - vertical_margin);
    return .{
        .x = (total_width - card_width) / 2.0,
        .y = (total_height - card_height) / 2.0,
        .width = card_width,
        .height = card_height,
    };
}

pub fn searchRect(width: u32, height: u32) Rect {
    const card = cardRect(width, height);
    const search_width = @max(1.0, @min(card.width - 48.0, 420.0));
    return .{
        .x = card.x + (card.width - search_width) / 2.0,
        .y = card.y + 30.0,
        .width = search_width,
        .height = search_height,
    };
}

pub fn gridRect(width: u32, height: u32) Rect {
    const card = cardRect(width, height);
    const horizontal_padding: f64 = if (card.width < 520.0) 22.0 else 44.0;
    const top_offset: f64 = if (card.height < 420.0) 96.0 else 110.0;
    const bottom_padding: f64 = if (card.height < 420.0) 26.0 else 38.0;
    return .{
        .x = card.x + horizontal_padding,
        .y = card.y + top_offset,
        .width = @max(1.0, card.width - horizontal_padding * 2.0),
        .height = @max(1.0, card.height - top_offset - bottom_padding),
    };
}

pub fn gridColumns(width: u32, height: u32) usize {
    const grid = gridRect(width, height);
    return @max(1, @as(usize, @intFromFloat(@floor((grid.width + tile_gap_x) / (tile_width + tile_gap_x)))));
}

pub fn visibleRowCount(width: u32, height: u32) usize {
    const grid = gridRect(width, height);
    return @max(1, @as(usize, @intFromFloat(@floor((grid.height + tile_gap_y) / (tile_height + tile_gap_y)))));
}

pub fn visibleCapacity(width: u32, height: u32) usize {
    return gridColumns(width, height) * visibleRowCount(width, height);
}

pub fn maxScrollRows(snapshot: model.Snapshot, width: u32, height: u32) usize {
    const cols = gridColumns(width, height);
    const visible_rows = visibleRowCount(width, height);
    const total_rows = @as(usize, @intCast((snapshot.count + cols - 1) / cols));
    return total_rows -| visible_rows;
}

pub fn hitTest(width: u32, height: u32, x: f64, y: f64, snapshot: model.Snapshot, scroll_rows: usize) ?usize {
    const visible = @min(snapshot.count -| (scroll_rows * gridColumns(width, height)), visibleCapacity(width, height));
    for (0..visible) |index| {
        const absolute_index = scroll_rows * gridColumns(width, height) + index;
        if (tileRect(width, height, index).contains(x, y)) return absolute_index;
    }
    return null;
}

pub fn gridContains(width: u32, height: u32, x: f64, y: f64) bool {
    return gridRect(width, height).contains(x, y);
}

pub fn draw(
    cr: *c.cairo_t,
    width: u32,
    height: u32,
    snapshot: model.Snapshot,
    icon_cache: *const icons.IconCache,
    hovered: ?usize,
    scroll_rows: usize,
    loading: bool,
) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);

    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
    c.cairo_set_source_rgba(cr, 0, 0, 0, 0);
    c.cairo_paint(cr);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);

    const card = cardRect(width, height);
    drawRoundedRect(cr, card, 22.0);
    c.cairo_set_source_rgba(cr, 0.11, 0.11, 0.115, 0.975);
    c.cairo_fill_preserve(cr);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.08);
    c.cairo_set_line_width(cr, 1.0);
    c.cairo_stroke(cr);

    const search = searchRect(width, height);
    drawRoundedRect(cr, search, 11.0);
    c.cairo_set_source_rgba(cr, 0.10, 0.10, 0.105, 0.96);
    c.cairo_fill_preserve(cr);
    c.cairo_set_source_rgba(cr, 0.36, 0.92, 1.0, 0.90);
    c.cairo_set_line_width(cr, 1.8);
    c.cairo_stroke(cr);
    drawSearchGlyph(cr, .{
        .x = search.x + 16.0,
        .y = search.y + 12.0,
        .width = 20.0,
        .height = 20.0,
    });

    const placeholder = "Digite para pesquisar aplicativos...";
    const query = if (snapshot.query.len > 0) snapshot.query else placeholder;
    const query_color: [3]f64 = if (snapshot.query.len > 0) .{ 0.95, 0.96, 0.98 } else .{ 0.62, 0.64, 0.68 };
    drawLabel(cr, search.x + 50.0, search.y + 30.0, 15.0, query, query_color[0], query_color[1], query_color[2]);

    if (snapshot.count == 0) {
        const empty_padding = @min(120.0, card.width / 5.0);
        const empty_rect = Rect{
            .x = card.x + empty_padding,
            .y = card.y + 180.0,
            .width = @max(1.0, card.width - empty_padding * 2.0),
            .height = @max(1.0, card.height - 210.0),
        };
        drawEmptyState(cr, empty_rect, snapshot.query.len > 0, loading);
        return;
    }

    const cols = gridColumns(width, height);
    const start = scroll_rows * cols;
    const visible = @min(snapshot.count -| start, visibleCapacity(width, height));
    for (0..visible) |visible_index| {
        const snapshot_index = start + visible_index;
        const rect = tileRect(width, height, visible_index);
        const entry = snapshot.entries[snapshot_index];
        const selected = snapshot.selected != null and snapshot.selected.? == snapshot_index;
        const is_hovered = hovered != null and hovered.? == snapshot_index;
        drawTile(cr, rect, entry, icon_cache.surfaceFor(entry.entry_index), selected, is_hovered);
    }

    drawScrollBar(cr, width, height, snapshot, scroll_rows);
}

fn tileRect(width: u32, height: u32, visible_index: usize) Rect {
    const grid = gridRect(width, height);
    const cols = gridColumns(width, height);
    const col = visible_index % cols;
    const row = visible_index / cols;
    const width_for_tile = @min(tile_width, grid.width);
    const height_for_tile = @min(tile_height, grid.height);
    return .{
        .x = grid.x + @as(f64, @floatFromInt(col)) * (tile_width + tile_gap_x),
        .y = grid.y + @as(f64, @floatFromInt(row)) * (tile_height + tile_gap_y),
        .width = width_for_tile,
        .height = height_for_tile,
    };
}

fn drawTile(cr: *c.cairo_t, rect: Rect, entry: model.EntryView, icon_surface: ?*c.cairo_surface_t, selected: bool, hovered: bool) void {
    if (selected or hovered) {
        drawRoundedRect(cr, rect, 16.0);
        c.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, if (selected) 0.09 else 0.05);
        c.cairo_fill(cr);
    }

    const icon_tile = Rect{
        .x = rect.x + (rect.width - 72.0) / 2.0,
        .y = rect.y + 10.0,
        .width = 72.0,
        .height = 72.0,
    };
    if (icon_surface) |surface| {
        drawIconTile(cr, icon_tile, surface);
    } else {
        drawRoundedRect(cr, icon_tile, 18.0);
        c.cairo_set_source_rgba(cr, entry.accent[0], entry.accent[1], entry.accent[2], 0.22);
        c.cairo_fill(cr);
        drawCenteredLabel(cr, icon_tile, if (entry.monogram.len > 1) 18.0 else 24.0, entry.monogram, 0.96, 0.98, 1.0);
    }

    drawCenteredLabel(
        cr,
        .{
            .x = rect.x + 8.0,
            .y = rect.y + 88.0,
            .width = rect.width - 16.0,
            .height = 20.0,
        },
        14.0,
        truncateLabel(entry.label, 22),
        0.94,
        0.95,
        0.98,
    );
    drawCenteredLabel(
        cr,
        .{
            .x = rect.x + 8.0,
            .y = rect.y + 108.0,
            .width = rect.width - 16.0,
            .height = 16.0,
        },
        12.0,
        truncateLabel(entry.subtitle, 22),
        0.68,
        0.70,
        0.74,
    );
}

fn drawIconTile(cr: *c.cairo_t, rect: Rect, surface: *c.cairo_surface_t) void {
    const src_w = @as(f64, @floatFromInt(c.cairo_image_surface_get_width(surface)));
    const src_h = @as(f64, @floatFromInt(c.cairo_image_surface_get_height(surface)));
    if (src_w <= 0 or src_h <= 0) return;

    const scale = @min(rect.width / src_w, rect.height / src_h);
    const dest_w = src_w * scale;
    const dest_h = src_h * scale;
    const dest_x = rect.x + (rect.width - dest_w) / 2.0;
    const dest_y = rect.y + (rect.height - dest_h) / 2.0;

    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_translate(cr, dest_x, dest_y);
    c.cairo_scale(cr, scale, scale);
    _ = c.cairo_set_source_surface(cr, surface, 0, 0);
    c.cairo_paint(cr);
}

fn drawEmptyState(cr: *c.cairo_t, rect: Rect, filtered: bool, loading: bool) void {
    const bubble = Rect{
        .x = rect.x + (rect.width - 74.0) / 2.0,
        .y = rect.y + 12.0,
        .width = 74.0,
        .height = 74.0,
    };
    drawRoundedRect(cr, bubble, 18.0);
    c.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.08);
    c.cairo_fill(cr);
    drawGridGlyph(cr, bubble, 0.96, 0.97, 1.0, 0.98);
    drawCenteredLabel(cr, .{
        .x = rect.x,
        .y = rect.y + 98.0,
        .width = rect.width,
        .height = 28.0,
    }, 18.0, if (loading) "Carregando aplicativos..." else if (filtered) "Nenhum aplicativo encontrado" else "Sem aplicativos", 0.96, 0.97, 0.99);
    drawCenteredLabel(cr, .{
        .x = rect.x,
        .y = rect.y + 130.0,
        .width = rect.width,
        .height = 20.0,
    }, 14.0, if (loading) "A grade abre primeiro e preenche logo depois." else if (filtered) "Tente outro termo de busca." else "Nada disponível para mostrar.", 0.70, 0.72, 0.76);
}

fn drawScrollBar(cr: *c.cairo_t, width: u32, height: u32, snapshot: model.Snapshot, scroll_rows: usize) void {
    const max_rows = maxScrollRows(snapshot, width, height);
    if (max_rows == 0) return;

    const grid = gridRect(width, height);
    const track = Rect{
        .x = grid.x + grid.width + 8.0,
        .y = grid.y + 2.0,
        .width = 6.0,
        .height = grid.height - 4.0,
    };
    drawRoundedRect(cr, track, 3.0);
    c.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.07);
    c.cairo_fill(cr);

    const visible_rows = visibleRowCount(width, height);
    const total_rows = max_rows + visible_rows;
    const thumb_h = @max(34.0, track.height * (@as(f64, @floatFromInt(visible_rows)) / @as(f64, @floatFromInt(total_rows))));
    const travel = @max(track.height - thumb_h, 1.0);
    const y = track.y + (@as(f64, @floatFromInt(scroll_rows)) / @as(f64, @floatFromInt(max_rows))) * travel;
    drawRoundedRect(cr, .{
        .x = track.x,
        .y = y,
        .width = track.width,
        .height = thumb_h,
    }, 3.0);
    c.cairo_set_source_rgba(cr, 0.36, 0.92, 1.0, 0.92);
    c.cairo_fill(cr);
}

fn drawSearchGlyph(cr: *c.cairo_t, rect: Rect) void {
    const cx = rect.x + 8.0;
    const cy = rect.y + 8.0;
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

fn drawGridGlyph(cr: *c.cairo_t, rect: Rect, r: f64, g: f64, b: f64, a: f64) void {
    const start_x = rect.x + rect.width / 2.0 - 10.8;
    const start_y = rect.y + rect.height / 2.0 - 10.8;
    for (0..3) |row| {
        for (0..3) |col| {
            c.cairo_arc(
                cr,
                start_x + @as(f64, @floatFromInt(col)) * 10.8,
                start_y + @as(f64, @floatFromInt(row)) * 10.8,
                2.5,
                0,
                std.math.tau,
            );
            c.cairo_set_source_rgba(cr, r, g, b, a);
            c.cairo_fill(cr);
        }
    }
}

fn truncateLabel(text: []const u8, comptime max_len: usize) []const u8 {
    if (text.len <= max_len) return text;
    return text[0..max_len];
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
