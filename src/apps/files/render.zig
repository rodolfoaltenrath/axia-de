const std = @import("std");
const c = @import("client_wl").c;
const chrome = @import("client_chrome");
const browser = @import("browser.zig");
const icons = @import("icons.zig");

pub const Rect = chrome.Rect;

const titlebar_height = chrome.titlebar_height;
const sidebar_expanded_width = 294.0;
const sidebar_collapsed_width = 64.0;
const content_padding = 18.0;
const top_strip_height = 56.0;
const table_header_height = 34.0;
const footer_height = 34.0;
const row_height = 40.0;

pub const Hit = union(enum) {
    none,
    titlebar,
    minimize,
    maximize,
    close,
    toggle_sidebar,
    up,
    open_selected,
    previous,
    next,
    sort_modified,
    sidebar: browser.SidebarTarget,
    entry: usize,
};

pub fn draw(
    cr: *c.cairo_t,
    width: u32,
    height: u32,
    snapshot: browser.Snapshot,
    hovered: Hit,
    sidebar_collapsed: bool,
    sidebar_icons: *const icons.SidebarIcons,
    picker_mode: bool,
) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);

    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
    c.cairo_set_source_rgba(cr, 0, 0, 0, 0);
    c.cairo_paint(cr);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);

    const root = rootRect(width, height);
    const sidebar = sidebarRect(width, height, sidebar_collapsed);
    const content = contentRect(width, height, sidebar_collapsed);

    _ = root;
    drawTitlebar(cr, width, height, hovered, sidebar_collapsed, picker_mode);
    drawSidebar(cr, sidebar, snapshot, hovered, sidebar_collapsed, sidebar_icons);
    drawContent(cr, width, height, content, snapshot, hovered, sidebar_collapsed, picker_mode);
}

pub fn hitTest(
    width: u32,
    height: u32,
    x: f64,
    y: f64,
    snapshot: browser.Snapshot,
    sidebar_collapsed: bool,
    picker_mode: bool,
) Hit {
    if (closeRect(width).contains(x, y)) return .close;
    if (maximizeRect(width).contains(x, y)) return .maximize;
    if (minimizeRect(width).contains(x, y)) return .minimize;
    if (toggleSidebarRect().contains(x, y)) return .toggle_sidebar;

    if (upRect(width, height, sidebar_collapsed).contains(x, y)) return .up;
    if (!picker_mode and openSelectedRect(width, height, sidebar_collapsed).contains(x, y)) return .open_selected;
    if (previousRect(width, height, sidebar_collapsed).contains(x, y)) return .previous;
    if (nextRect(width, height, sidebar_collapsed).contains(x, y)) return .next;
    if (modifiedHeaderRect(width, height, sidebar_collapsed).contains(x, y)) return .sort_modified;

    const sidebar = sidebarRect(width, height, sidebar_collapsed);
    for (browser.sidebar_items) |item| {
        if (sidebarItemRect(sidebar, item.target).contains(x, y)) {
            return .{ .sidebar = item.target };
        }
    }

    for (0..snapshot.count) |index| {
        if (entryRect(width, height, index, sidebar_collapsed).contains(x, y)) {
            return .{ .entry = index };
        }
    }

    if (titlebarDragRect(width, height).contains(x, y)) return .titlebar;
    return .none;
}

fn rootRect(width: u32, height: u32) Rect {
    return chrome.rootRect(width, height);
}

fn sidebarWidth(collapsed: bool) f64 {
    return if (collapsed) sidebar_collapsed_width else sidebar_expanded_width;
}

fn sidebarRect(width: u32, height: u32, collapsed: bool) Rect {
    const root = rootRect(width, height);
    return .{
        .x = root.x + 12,
        .y = root.y + titlebar_height + 6,
        .width = sidebarWidth(collapsed),
        .height = root.height - titlebar_height - 18,
    };
}

fn contentRect(width: u32, height: u32, collapsed: bool) Rect {
    const root = rootRect(width, height);
    const side = sidebarRect(width, height, collapsed);
    return .{
        .x = side.x + side.width + 18,
        .y = root.y + titlebar_height + 6,
        .width = root.x + root.width - (side.x + side.width + 30),
        .height = root.height - titlebar_height - 18,
    };
}

fn titlebarDragRect(width: u32, height: u32) Rect {
    return chrome.titlebarDragRect(width, height, 120, 120);
}

fn toggleSidebarRect() Rect {
    return .{ .x = 24, .y = 18, .width = 18, .height = 18 };
}

fn appGlyphRect() Rect {
    return .{ .x = 52, .y = 18, .width = 18, .height = 18 };
}

fn minimizeRect(width: u32) Rect {
    return chrome.minimizeRect(width);
}

fn maximizeRect(width: u32) Rect {
    return chrome.maximizeRect(width);
}

fn closeRect(width: u32) Rect {
    return chrome.closeRect(width);
}

fn previousRect(width: u32, height: u32, collapsed: bool) Rect {
    const content = contentRect(width, height, collapsed);
    return .{ .x = content.x + 10, .y = content.y + 12, .width = 28, .height = 28 };
}

fn nextRect(width: u32, height: u32, collapsed: bool) Rect {
    const content = contentRect(width, height, collapsed);
    return .{ .x = content.x + 40, .y = content.y + 12, .width = 28, .height = 28 };
}

fn upRect(width: u32, height: u32, collapsed: bool) Rect {
    const content = contentRect(width, height, collapsed);
    return .{ .x = content.x + 82, .y = content.y + 12, .width = 28, .height = 28 };
}

fn sidebarItemRect(sidebar: Rect, target: browser.SidebarTarget) Rect {
    const index = @as(f64, @floatFromInt(@intFromEnum(target)));
    return .{
        .x = sidebar.x + 10,
        .y = sidebar.y + 46 + index * 40,
        .width = sidebar.width - 20,
        .height = 30,
    };
}

fn openSelectedRect(width: u32, height: u32, collapsed: bool) Rect {
    const content = contentRect(width, height, collapsed);
    return .{
        .x = content.x + content.width - 94,
        .y = content.y + 10,
        .width = 84,
        .height = 30,
    };
}

fn entryRect(width: u32, height: u32, index: usize, collapsed: bool) Rect {
    const content = contentRect(width, height, collapsed);
    return .{
        .x = content.x,
        .y = content.y + top_strip_height + table_header_height + @as(f64, @floatFromInt(index)) * row_height,
        .width = content.width,
        .height = row_height,
    };
}

fn drawTitlebar(cr: *c.cairo_t, width: u32, height: u32, hovered: Hit, sidebar_collapsed: bool, picker_mode: bool) void {
    chrome.drawWindowShell(cr, width, height, .{
        .title = if (picker_mode) "Selecionar Wallpaper" else "Arquivos",
        .title_x = 86,
    }, hoveredControl(hovered));
    drawTopGlyphButton(cr, toggleSidebarRect(), "=", hovered == .toggle_sidebar);
    drawTopGlyphButton(cr, appGlyphRect(), if (sidebar_collapsed) ">" else "<", false);
}

fn drawSidebar(
    cr: *c.cairo_t,
    sidebar: Rect,
    snapshot: browser.Snapshot,
    hovered: Hit,
    collapsed: bool,
    sidebar_icons: *const icons.SidebarIcons,
) void {
    drawRoundedRect(cr, sidebar, 12);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.045);
    c.cairo_fill(cr);

    if (collapsed) {
        for (browser.sidebar_items) |item| {
            const rect = sidebarItemRect(sidebar, item.target);
            const hovered_item = switch (hovered) {
                .sidebar => |target| target == item.target,
                else => false,
            };
        const active = matchesSidebar(snapshot.current_dir, item.target);
        drawCollapsedSidebarItem(cr, rect, item.icon, hovered_item or active, sidebar_icons.surfaceFor(item.target));
        }
        return;
    }

    for (browser.sidebar_items, 0..) |item, index| {
        const rect = sidebarItemRect(sidebar, item.target);
        const hovered_item = switch (hovered) {
            .sidebar => |target| target == item.target,
            else => false,
        };
        const active = matchesSidebar(snapshot.current_dir, item.target);
        drawSidebarItem(cr, rect, item.icon, item.label, active, hovered_item, sidebar_icons.surfaceFor(item.target));

        if (index == 6 or index == 7) {
            c.cairo_rectangle(cr, sidebar.x + 18, rect.y + rect.height + 10, sidebar.width - 36, 1);
            c.cairo_set_source_rgba(cr, 1, 1, 1, 0.08);
            c.cairo_fill(cr);
        }
    }
}

fn drawContent(
    cr: *c.cairo_t,
    width: u32,
    height: u32,
    content: Rect,
    snapshot: browser.Snapshot,
    hovered: Hit,
    sidebar_collapsed: bool,
    picker_mode: bool,
) void {
    drawToolbarButton(cr, previousRect(width, height, sidebar_collapsed), "<", hovered == .previous);
    drawToolbarButton(cr, nextRect(width, height, sidebar_collapsed), ">", hovered == .next);
    drawToolbarButton(cr, upRect(width, height, sidebar_collapsed), "^", hovered == .up);
    if (!picker_mode) {
        drawActionButton(
            cr,
            openSelectedRect(width, height, sidebar_collapsed),
            "Abrir",
            snapshot.selected_is_file,
            hovered == .open_selected,
        );
    }

    drawBreadcrumb(cr, content, snapshot.current_dir);
    if (picker_mode) drawPickerHint(cr, content);

    const header_y = content.y + top_strip_height;
    const footer_y = content.y + content.height - footer_height;
    const rows_bottom = footer_y - 6;
    c.cairo_rectangle(cr, content.x, header_y, content.width, 1);
    c.cairo_set_source_rgba(cr, 0.31, 0.94, 1.0, 0.85);
    c.cairo_fill(cr);

    drawColumnHeaders(cr, content, header_y, snapshot.modified_descending, hovered == .sort_modified);

    if (snapshot.count == 0) {
        drawEmptyState(cr, content, picker_mode);
    } else {
        const rows_top = header_y + table_header_height;
        c.cairo_save(cr);
        c.cairo_rectangle(cr, content.x, rows_top, content.width, rows_bottom - rows_top);
        c.cairo_clip(cr);
        for (0..snapshot.count) |index| {
            const rect = Rect{
                .x = content.x,
                .y = rows_top + @as(f64, @floatFromInt(index)) * row_height,
                .width = content.width,
                .height = row_height,
            };
            const hovered_entry = switch (hovered) {
                .entry => |visible| visible == index,
                else => false,
            };
            drawEntryRow(
                cr,
                rect,
                snapshot.entries[index].kind,
                snapshot.entries[index].text(),
                snapshot.entries[index].modifiedText(),
                snapshot.entries[index].sizeText(),
                hovered_entry,
                snapshot.selected_visible and snapshot.selected_visible_index == index,
            );
        }
        c.cairo_restore(cr);
    }

    c.cairo_rectangle(cr, content.x, footer_y, content.width, footer_height);
    c.cairo_set_source_rgba(cr, 0.11, 0.11, 0.115, 0.94);
    c.cairo_fill(cr);

    c.cairo_rectangle(cr, content.x, footer_y, content.width, 1);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.05);
    c.cairo_fill(cr);

    var footer_buf: [96]u8 = undefined;
    const footer = if (snapshot.total_count == 0)
        (if (picker_mode) "Nenhuma imagem nesta pasta" else "Pasta vazia")
    else
        std.fmt.bufPrint(&footer_buf, "{d} itens", .{snapshot.total_count}) catch "Itens";
    drawLabel(cr, content.x, footer_y + 22, 13, footer, 0.78, 0.79, 0.82);
}

fn drawPickerHint(cr: *c.cairo_t, content: Rect) void {
    const rect = Rect{
        .x = content.x + 376,
        .y = content.y + 10,
        .width = content.width - 376,
        .height = 32,
    };
    drawRoundedRect(cr, rect, 10);
    c.cairo_set_source_rgba(cr, 0.18, 0.66, 0.84, 0.18);
    c.cairo_fill(cr);
    drawLabel(cr, rect.x + 14, rect.y + 21, 12.5, "Clique numa imagem para aplicar como wallpaper.", 0.82, 0.93, 0.97);
}

fn drawBreadcrumb(cr: *c.cairo_t, content: Rect, current_dir: []const u8) void {
    const y = content.y + 34;
    drawLabel(cr, content.x + 122, y, 15, "Pasta pessoal", 0.38, 0.88, 0.98);
    drawLabel(cr, content.x + 234, y, 17, "/", 0.86, 0.87, 0.9);
    drawLabel(cr, content.x + 256, y, 15, basenameLabel(current_dir), 0.38, 0.88, 0.98);
}

fn drawColumnHeaders(cr: *c.cairo_t, content: Rect, header_y: f64, modified_descending: bool, modified_hovered: bool) void {
    const name_x = content.x + 10;
    const modified_x = content.x + content.width * 0.46;
    const size_x = content.x + content.width * 0.80;
    drawLabel(cr, name_x, header_y + 24, 14, "Nome", 0.95, 0.95, 0.96);

    if (modified_hovered) {
        drawRoundedRect(cr, .{
            .x = modified_x - 8,
            .y = header_y + 4,
            .width = 116,
            .height = 24,
        }, 7);
        c.cairo_set_source_rgba(cr, 1, 1, 1, 0.05);
        c.cairo_fill(cr);
    }
    drawLabel(cr, modified_x, header_y + 24, 14, "Modificado", 0.95, 0.95, 0.96);
    drawLabel(cr, modified_x + 82, header_y + 24, 13, if (modified_descending) "^" else "v", 0.82, 0.83, 0.86);
    drawLabel(cr, size_x, header_y + 24, 14, "Tamanho", 0.95, 0.95, 0.96);

    c.cairo_rectangle(cr, content.x, header_y + table_header_height - 1, content.width, 1);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.08);
    c.cairo_fill(cr);
}

fn drawEntryRow(
    cr: *c.cairo_t,
    rect: Rect,
    kind: browser.EntryKind,
    label: []const u8,
    modified: []const u8,
    size: []const u8,
    hovered: bool,
    selected: bool,
) void {
    if (selected) {
        c.cairo_rectangle(cr, rect.x, rect.y, rect.width, rect.height);
        c.cairo_set_source_rgba(cr, 0.22, 0.62, 0.88, 0.18);
        c.cairo_fill(cr);
    } else if (hovered) {
        c.cairo_rectangle(cr, rect.x, rect.y, rect.width, rect.height);
        c.cairo_set_source_rgba(cr, 1, 1, 1, 0.05);
        c.cairo_fill(cr);
    }

    const name_x = rect.x + 10;
    const modified_x = rect.x + rect.width * 0.46;
    const size_x = rect.x + rect.width * 0.80;
    const icon_rect = Rect{ .x = name_x, .y = rect.y + 9, .width = 20, .height = 20 };

    if (kind == .directory) {
        drawFolderGlyph(cr, icon_rect);
        drawLabel(cr, name_x + 30, rect.y + 24, 15, label, 0.91, 0.92, 0.94);
        drawLabel(cr, modified_x, rect.y + 24, 14, modified, 0.74, 0.76, 0.80);
        drawLabel(cr, size_x, rect.y + 24, 14, size, 0.74, 0.76, 0.80);
    } else {
        drawFileGlyph(cr, icon_rect);
        drawLabel(cr, name_x + 30, rect.y + 24, 15, label, 0.91, 0.92, 0.94);
        drawLabel(cr, modified_x, rect.y + 24, 14, modified, 0.74, 0.76, 0.80);
        drawLabel(cr, size_x, rect.y + 24, 14, size, 0.74, 0.76, 0.80);
    }

    c.cairo_rectangle(cr, rect.x, rect.y + rect.height - 1, rect.width, 1);
    c.cairo_set_source_rgba(cr, if (selected) 0.32 else 1, if (selected) 0.82 else 1, if (selected) 0.96 else 1, if (selected) 0.16 else 0.045);
    c.cairo_fill(cr);
}

fn drawEmptyState(cr: *c.cairo_t, content: Rect, picker_mode: bool) void {
    const center = Rect{
        .x = content.x + (content.width - 180) / 2.0,
        .y = content.y + 150,
        .width = 180,
        .height = 130,
    };

    drawFolderGlyph(cr, .{
        .x = center.x + 56,
        .y = center.y + 12,
        .width = 56,
        .height = 44,
    });
    drawCenteredLabel(cr, .{
        .x = center.x,
        .y = center.y + 72,
        .width = center.width,
        .height = 26,
    }, 16, if (picker_mode) "Sem imagens aqui" else "Pasta vazia", 0.90, 0.91, 0.94);
}

fn drawFolderGlyph(cr: *c.cairo_t, rect: Rect) void {
    drawRoundedRect(cr, .{
        .x = rect.x + 6,
        .y = rect.y,
        .width = rect.width * 0.40,
        .height = rect.height * 0.32,
    }, 5);
    c.cairo_set_source_rgba(cr, 0.88, 0.88, 0.89, 0.95);
    c.cairo_fill(cr);

    drawRoundedRect(cr, .{
        .x = rect.x,
        .y = rect.y + rect.height * 0.18,
        .width = rect.width,
        .height = rect.height * 0.82,
    }, 8);
    c.cairo_set_source_rgba(cr, 0.88, 0.88, 0.89, 0.95);
    c.cairo_fill(cr);
}

fn drawFileGlyph(cr: *c.cairo_t, rect: Rect) void {
    drawRoundedRect(cr, rect, 4);
    c.cairo_set_source_rgba(cr, 0.85, 0.85, 0.88, 0.22);
    c.cairo_fill(cr);
}

fn drawTopGlyphButton(cr: *c.cairo_t, rect: Rect, glyph: []const u8, hovered: bool) void {
    if (hovered) {
        drawRoundedRect(cr, .{
            .x = rect.x - 6,
            .y = rect.y - 5,
            .width = rect.width + 12,
            .height = rect.height + 10,
        }, 8);
        c.cairo_set_source_rgba(cr, 1, 1, 1, 0.06);
        c.cairo_fill(cr);
    }
    drawTopGlyphIcon(cr, rect, glyph);
}

fn drawToolbarButton(cr: *c.cairo_t, rect: Rect, label: []const u8, hovered: bool) void {
    if (hovered) {
        drawRoundedRect(cr, .{
            .x = rect.x - 2,
            .y = rect.y - 2,
            .width = rect.width + 4,
            .height = rect.height + 4,
        }, 8);
        c.cairo_set_source_rgba(cr, 1, 1, 1, 0.06);
        c.cairo_fill(cr);
    }
    drawCenteredLabel(cr, rect, 18, label, 0.94, 0.95, 0.97);
}

fn drawActionButton(cr: *c.cairo_t, rect: Rect, label: []const u8, enabled: bool, hovered: bool) void {
    drawRoundedRect(cr, rect, 10);
    if (enabled) {
        c.cairo_set_source_rgba(cr, if (hovered) 0.20 else 0.16, if (hovered) 0.56 else 0.46, if (hovered) 0.76 else 0.62, if (hovered) 0.90 else 0.74);
        c.cairo_fill_preserve(cr);
        c.cairo_set_source_rgba(cr, 0.44, 0.88, 0.98, 0.28);
        c.cairo_set_line_width(cr, 1);
        c.cairo_stroke(cr);
        drawCenteredLabel(cr, rect, 14, label, 0.95, 0.97, 1.0);
    } else {
        c.cairo_set_source_rgba(cr, 1, 1, 1, 0.04);
        c.cairo_fill_preserve(cr);
        c.cairo_set_source_rgba(cr, 1, 1, 1, 0.05);
        c.cairo_set_line_width(cr, 1);
        c.cairo_stroke(cr);
        drawCenteredLabel(cr, rect, 14, label, 0.58, 0.60, 0.64);
    }
}

fn drawSidebarItem(
    cr: *c.cairo_t,
    rect: Rect,
    icon: []const u8,
    label: []const u8,
    active: bool,
    hovered: bool,
    surface: ?*c.cairo_surface_t,
) void {
    const icon_r: f64 = if (active) 0.38 else 0.78;
    const icon_g: f64 = if (active) 0.91 else 0.79;
    const icon_b: f64 = if (active) 1.0 else 0.81;

    if (active or hovered) {
        drawRoundedRect(cr, rect, 8);
        c.cairo_set_source_rgba(cr, 1, 1, 1, if (active) 0.08 else 0.05);
        c.cairo_fill(cr);
    }
    drawSidebarIcon(cr, .{
        .x = rect.x + 6,
        .y = rect.y + 7,
        .width = 16,
        .height = 16,
    }, icon, surface, icon_r, icon_g, icon_b);
    drawLabel(cr, rect.x + 38, rect.y + 21, 15, label, icon_r, icon_g, icon_b);
}

fn drawCollapsedSidebarItem(cr: *c.cairo_t, rect: Rect, icon: []const u8, active: bool, surface: ?*c.cairo_surface_t) void {
    const icon_r: f64 = if (active) 0.38 else 0.80;
    const icon_g: f64 = if (active) 0.91 else 0.82;
    const icon_b: f64 = if (active) 1.0 else 0.84;

    if (active) {
        drawRoundedRect(cr, rect, 8);
        c.cairo_set_source_rgba(cr, 1, 1, 1, 0.06);
        c.cairo_fill(cr);
    }
    drawSidebarIcon(cr, .{
        .x = rect.x + (rect.width - 16) / 2.0,
        .y = rect.y + (rect.height - 16) / 2.0,
        .width = 16,
        .height = 16,
    }, icon, surface, icon_r, icon_g, icon_b);
}

fn drawSidebarIcon(
    cr: *c.cairo_t,
    rect: Rect,
    fallback: []const u8,
    surface: ?*c.cairo_surface_t,
    r: f64,
    g: f64,
    b: f64,
) void {
    if (surface) |loaded| {
        const src_w = @as(f64, @floatFromInt(c.cairo_image_surface_get_width(loaded)));
        const src_h = @as(f64, @floatFromInt(c.cairo_image_surface_get_height(loaded)));
        c.cairo_save(cr);
        c.cairo_translate(cr, rect.x, rect.y);
        c.cairo_scale(cr, rect.width / src_w, rect.height / src_h);
        c.cairo_set_source_rgb(cr, r, g, b);
        c.cairo_mask_surface(cr, loaded, 0, 0);
        c.cairo_restore(cr);
        return;
    }

    drawCenteredLabel(cr, rect, 14, fallback, r, g, b);
}

fn hoveredControl(hit: Hit) chrome.HoveredControl {
    return switch (hit) {
        .minimize => .minimize,
        .maximize => .maximize,
        .close => .close,
        else => .none,
    };
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

fn drawTopGlyphIcon(cr: *c.cairo_t, rect: Rect, glyph: []const u8) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);

    c.cairo_set_source_rgb(cr, 0.39, 0.91, 1.0);
    c.cairo_set_line_width(cr, 1.8);
    c.cairo_set_line_cap(cr, c.CAIRO_LINE_CAP_ROUND);
    c.cairo_set_line_join(cr, c.CAIRO_LINE_JOIN_ROUND);

    const cx = rect.x + rect.width / 2.0;
    const cy = rect.y + rect.height / 2.0;
    if (std.mem.eql(u8, glyph, "=")) {
        c.cairo_move_to(cr, cx - 4.0, cy - 2.5);
        c.cairo_line_to(cr, cx + 4.0, cy - 2.5);
        c.cairo_move_to(cr, cx - 4.0, cy + 2.5);
        c.cairo_line_to(cr, cx + 4.0, cy + 2.5);
        c.cairo_stroke(cr);
        return;
    }

    if (std.mem.eql(u8, glyph, "<")) {
        c.cairo_move_to(cr, cx + 2.5, cy - 5.0);
        c.cairo_line_to(cr, cx - 2.5, cy);
        c.cairo_line_to(cr, cx + 2.5, cy + 5.0);
        c.cairo_stroke(cr);
        return;
    }

    if (std.mem.eql(u8, glyph, ">")) {
        c.cairo_move_to(cr, cx - 2.5, cy - 5.0);
        c.cairo_line_to(cr, cx + 2.5, cy);
        c.cairo_line_to(cr, cx - 2.5, cy + 5.0);
        c.cairo_stroke(cr);
        return;
    }

    drawCenteredLabel(cr, rect, 16, glyph, 0.39, 0.91, 1.0);
}

fn basenameLabel(current_dir: []const u8) []const u8 {
    if (current_dir.len == 0) return "Início";
    if (std.fs.path.basename(current_dir).len == 0) return current_dir;
    return std.fs.path.basename(current_dir);
}

fn modifiedHeaderRect(width: u32, height: u32, collapsed: bool) Rect {
    const content = contentRect(width, height, collapsed);
    return .{
        .x = content.x + content.width * 0.46 - 4,
        .y = content.y + top_strip_height + 4,
        .width = 134,
        .height = 24,
    };
}

fn matchesSidebar(current_dir: []const u8, target: browser.SidebarTarget) bool {
    const home = std.process.getEnvVarOwned(std.heap.page_allocator, "HOME") catch return false;
    defer std.heap.page_allocator.free(home);

    return switch (target) {
        .recents => std.mem.eql(u8, current_dir, home),
        .home => std.mem.eql(u8, current_dir, home),
        .trash, .network => false,
        else => blk: {
            const item = browser.sidebar_items[@intFromEnum(target)];
            const subdir = item.subdir orelse break :blk false;
            const joined = std.fs.path.join(std.heap.page_allocator, &.{ home, subdir }) catch break :blk false;
            defer std.heap.page_allocator.free(joined);
            break :blk std.mem.eql(u8, current_dir, joined);
        },
    };
}
