const std = @import("std");
const c = @import("client_wl").c;
const browser = @import("browser.zig");
const icons = @import("icons.zig");

pub const Rect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,

    pub fn contains(self: Rect, px: f64, py: f64) bool {
        return px >= self.x and px <= self.x + self.width and py >= self.y and py <= self.y + self.height;
    }
};

const window_margin = 4.0;
const window_radius = 16.0;
const titlebar_height = 46.0;
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

    drawWindowSurface(cr, root);
    drawTitlebar(cr, width, hovered, sidebar_collapsed);
    drawSidebar(cr, sidebar, snapshot, hovered, sidebar_collapsed, sidebar_icons);
    drawContent(cr, width, height, content, snapshot, hovered, sidebar_collapsed);
}

pub fn hitTest(
    width: u32,
    height: u32,
    x: f64,
    y: f64,
    snapshot: browser.Snapshot,
    sidebar_collapsed: bool,
) Hit {
    if (closeRect(width).contains(x, y)) return .close;
    if (maximizeRect(width).contains(x, y)) return .maximize;
    if (minimizeRect(width).contains(x, y)) return .minimize;
    if (toggleSidebarRect().contains(x, y)) return .toggle_sidebar;

    if (upRect(width, height, sidebar_collapsed).contains(x, y)) return .up;
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

    if (titlebarDragRect(width).contains(x, y)) return .titlebar;
    return .none;
}

fn rootRect(width: u32, height: u32) Rect {
    return .{
        .x = window_margin,
        .y = window_margin,
        .width = @as(f64, @floatFromInt(width)) - window_margin * 2.0,
        .height = @as(f64, @floatFromInt(height)) - window_margin * 2.0,
    };
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

fn titlebarDragRect(width: u32) Rect {
    const root = rootRect(width, 580);
    return .{
        .x = root.x + 94,
        .y = root.y + 2,
        .width = root.width - 210,
        .height = titlebar_height - 4,
    };
}

fn toggleSidebarRect() Rect {
    return .{ .x = 24, .y = 18, .width = 18, .height = 18 };
}

fn appGlyphRect() Rect {
    return .{ .x = 52, .y = 18, .width = 18, .height = 18 };
}

fn minimizeRect(width: u32) Rect {
    const right = @as(f64, @floatFromInt(width)) - 34;
    return .{ .x = right - 88, .y = 14, .width = 18, .height = 18 };
}

fn maximizeRect(width: u32) Rect {
    const right = @as(f64, @floatFromInt(width)) - 34;
    return .{ .x = right - 52, .y = 14, .width = 18, .height = 18 };
}

fn closeRect(width: u32) Rect {
    const right = @as(f64, @floatFromInt(width)) - 34;
    return .{ .x = right - 16, .y = 14, .width = 18, .height = 18 };
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

fn entryRect(width: u32, height: u32, index: usize, collapsed: bool) Rect {
    const content = contentRect(width, height, collapsed);
    return .{
        .x = content.x,
        .y = content.y + top_strip_height + table_header_height + @as(f64, @floatFromInt(index)) * row_height,
        .width = content.width,
        .height = row_height,
    };
}

fn drawWindowSurface(cr: *c.cairo_t, root: Rect) void {
    drawRoundedRect(cr, root, window_radius);
    c.cairo_set_source_rgba(cr, 0.105, 0.105, 0.11, 0.97);
    c.cairo_fill_preserve(cr);
    c.cairo_set_source_rgba(cr, 0.40, 0.95, 1.0, 0.95);
    c.cairo_set_line_width(cr, 2.0);
    c.cairo_stroke(cr);

    drawRoundedRect(cr, .{
        .x = root.x + 1.5,
        .y = root.y + 1.5,
        .width = root.width - 3.0,
        .height = root.height - 3.0,
    }, window_radius - 1.5);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.04);
    c.cairo_set_line_width(cr, 1.0);
    c.cairo_stroke(cr);
}

fn drawTitlebar(cr: *c.cairo_t, width: u32, hovered: Hit, sidebar_collapsed: bool) void {
    const root = rootRect(width, 580);
    const bar = Rect{
        .x = root.x + 1,
        .y = root.y + 1,
        .width = root.width - 2,
        .height = titlebar_height,
    };

    c.cairo_rectangle(cr, bar.x, bar.y, bar.width, bar.height);
    c.cairo_set_source_rgba(cr, 0.11, 0.11, 0.115, 1.0);
    c.cairo_fill(cr);

    c.cairo_rectangle(cr, bar.x, bar.y + bar.height - 1, bar.width, 1);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.04);
    c.cairo_fill(cr);

    drawTopGlyphButton(cr, toggleSidebarRect(), "=", hovered == .toggle_sidebar);
    drawTopGlyphButton(cr, appGlyphRect(), if (sidebar_collapsed) ">" else "<", false);

    drawWindowGlyph(cr, minimizeRect(width), "-", hovered == .minimize);
    drawWindowGlyph(cr, maximizeRect(width), "+", hovered == .maximize);
    drawWindowGlyph(cr, closeRect(width), "x", hovered == .close);
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
) void {
    drawToolbarButton(cr, previousRect(width, height, sidebar_collapsed), "<", hovered == .previous);
    drawToolbarButton(cr, nextRect(width, height, sidebar_collapsed), ">", hovered == .next);
    drawToolbarButton(cr, upRect(width, height, sidebar_collapsed), "^", hovered == .up);

    drawBreadcrumb(cr, content, snapshot.current_dir);

    const header_y = content.y + top_strip_height;
    const footer_y = content.y + content.height - footer_height;
    const rows_bottom = footer_y - 6;
    c.cairo_rectangle(cr, content.x, header_y, content.width, 1);
    c.cairo_set_source_rgba(cr, 0.31, 0.94, 1.0, 0.85);
    c.cairo_fill(cr);

    drawColumnHeaders(cr, content, header_y, snapshot.modified_descending, hovered == .sort_modified);

    if (snapshot.count == 0) {
        drawEmptyState(cr, content);
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
        "Pasta vazia"
    else
        std.fmt.bufPrint(&footer_buf, "{d} itens", .{snapshot.total_count}) catch "Itens";
    drawLabel(cr, content.x, footer_y + 22, 13, footer, 0.78, 0.79, 0.82);
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
) void {
    if (hovered) {
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
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.045);
    c.cairo_fill(cr);
}

fn drawEmptyState(cr: *c.cairo_t, content: Rect) void {
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
    }, 16, "Pasta vazia", 0.90, 0.91, 0.94);
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
    drawCenteredLabel(cr, rect, 16, glyph, 0.39, 0.91, 1.0);
}

fn drawWindowGlyph(cr: *c.cairo_t, rect: Rect, glyph: []const u8, hovered: bool) void {
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
    drawCenteredLabel(cr, rect, 15, glyph, 0.38, 0.90, 0.99);
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

fn drawRoundedRect(cr: *c.cairo_t, rect: Rect, radius: f64) void {
    const right = rect.x + rect.width;
    const bottom = rect.y + rect.height;
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, right - radius, rect.y + radius, radius, -std.math.pi / 2.0, 0.0);
    c.cairo_arc(cr, right - radius, bottom - radius, radius, 0.0, std.math.pi / 2.0);
    c.cairo_arc(cr, rect.x + radius, bottom - radius, radius, std.math.pi / 2.0, std.math.pi);
    c.cairo_arc(cr, rect.x + radius, rect.y + radius, radius, std.math.pi, 3.0 * std.math.pi / 2.0);
    c.cairo_close_path(cr);
}

fn drawLabel(cr: *c.cairo_t, x: f64, y: f64, size: f64, text: []const u8, r: f64, g: f64, b: f64) void {
    var text_buf: [512]u8 = undefined;
    const c_text = toCString(&text_buf, text);
    c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
    c.cairo_set_font_size(cr, size);
    c.cairo_set_source_rgb(cr, r, g, b);
    c.cairo_move_to(cr, x, y);
    c.cairo_show_text(cr, c_text.ptr);
}

fn drawCenteredLabel(cr: *c.cairo_t, rect: Rect, size: f64, text: []const u8, r: f64, g: f64, b: f64) void {
    var text_buf: [128]u8 = undefined;
    const c_text = toCString(&text_buf, text);
    var extents: c.cairo_text_extents_t = undefined;
    var font_extents: c.cairo_font_extents_t = undefined;
    c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
    c.cairo_set_font_size(cr, size);
    c.cairo_text_extents(cr, c_text.ptr, &extents);
    c.cairo_font_extents(cr, &font_extents);
    c.cairo_set_source_rgb(cr, r, g, b);
    c.cairo_move_to(
        cr,
        rect.x + (rect.width - extents.width) / 2.0 - extents.x_bearing,
        rect.y + (rect.height - font_extents.height) / 2.0 + font_extents.ascent,
    );
    c.cairo_show_text(cr, c_text.ptr);
}

fn toCString(buffer: []u8, text: []const u8) [:0]u8 {
    const max_len = @min(text.len, buffer.len - 1);
    @memcpy(buffer[0..max_len], text[0..max_len]);
    buffer[max_len] = 0;
    return buffer[0..max_len :0];
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
