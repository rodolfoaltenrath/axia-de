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
const scrollbar_width = 8.0;
const scrollbar_gap = 8.0;
const toolbar_button_size = 30.0;
const toolbar_button_gap = 8.0;
const action_button_height = 30.0;
const action_button_gap = 10.0;

pub const DialogKind = enum {
    none,
    new_folder,
    rename,
    delete_confirm,
    delete_permanent_confirm,
};

const ActionTone = enum {
    primary,
    secondary,
    danger,
};

pub const Hit = union(enum) {
    none,
    titlebar,
    minimize,
    maximize,
    close,
    toggle_sidebar,
    up,
    breadcrumb_up,
    open_selected,
    new_folder,
    rename_selected,
    delete_selected,
    previous,
    next,
    sort_modified,
    dialog_confirm,
    dialog_cancel,
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
    dialog_kind: DialogKind,
    dialog_input: []const u8,
    dialog_subject: []const u8,
    maximized: bool,
) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);

    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
    c.cairo_set_source_rgba(cr, 0, 0, 0, 0);
    c.cairo_paint(cr);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);

    const root = rootRect(width, height, maximized);
    const sidebar = sidebarRect(width, height, sidebar_collapsed, maximized);
    const content = contentRect(width, height, sidebar_collapsed, maximized);

    _ = root;
    drawTitlebar(cr, width, height, snapshot, hovered, sidebar_collapsed, picker_mode, maximized);
    drawSidebar(cr, sidebar, snapshot, hovered, sidebar_collapsed, sidebar_icons);
    drawContent(cr, width, height, content, snapshot, hovered, sidebar_collapsed, picker_mode, maximized);
    if (dialog_kind != .none) {
        drawDialog(cr, width, height, dialog_kind, dialog_input, dialog_subject, hovered, maximized);
    }
}

pub fn hitTest(
    width: u32,
    height: u32,
    x: f64,
    y: f64,
    snapshot: browser.Snapshot,
    sidebar_collapsed: bool,
    picker_mode: bool,
    dialog_kind: DialogKind,
    maximized: bool,
) Hit {
    if (dialog_kind != .none) {
        if (dialogConfirmRect(width, height, maximized).contains(x, y)) return .dialog_confirm;
        if (dialogCancelRect(width, height, maximized).contains(x, y)) return .dialog_cancel;
        return .none;
    }

    if (closeRect(width).contains(x, y)) return .close;
    if (maximizeRect(width).contains(x, y)) return .maximize;
    if (minimizeRect(width).contains(x, y)) return .minimize;
    if (toggleSidebarRect().contains(x, y)) return .toggle_sidebar;

    if (upRect(width, height, sidebar_collapsed, maximized).contains(x, y)) return .up;
    if (breadcrumbTargetRect(width, height, sidebar_collapsed, snapshot.current_dir, maximized).contains(x, y)) return .breadcrumb_up;
    if (!picker_mode and openSelectedRect(width, height, sidebar_collapsed, maximized).contains(x, y)) return .open_selected;
    if (!picker_mode and newFolderRect(width, height, sidebar_collapsed, maximized).contains(x, y)) return .new_folder;
    if (!picker_mode and renameRect(width, height, sidebar_collapsed, maximized).contains(x, y)) return .rename_selected;
    if (!picker_mode and deleteRect(width, height, sidebar_collapsed, maximized).contains(x, y)) return .delete_selected;
    if (previousRect(width, height, sidebar_collapsed, maximized).contains(x, y)) return .previous;
    if (nextRect(width, height, sidebar_collapsed, maximized).contains(x, y)) return .next;
    if (modifiedHeaderRect(width, height, sidebar_collapsed, maximized).contains(x, y)) return .sort_modified;

    const sidebar = sidebarRect(width, height, sidebar_collapsed, maximized);
    for (browser.sidebar_items) |item| {
        if (sidebarItemRect(sidebar, item.target).contains(x, y)) {
            return .{ .sidebar = item.target };
        }
    }

    for (0..snapshot.count) |index| {
        if (entryRect(width, height, index, sidebar_collapsed, maximized).contains(x, y)) {
            return .{ .entry = index };
        }
    }

    if (titlebarDragRect(width, height, maximized).contains(x, y)) return .titlebar;
    return .none;
}

pub fn scrollRegionRect(width: u32, height: u32, collapsed: bool, maximized: bool) Rect {
    const content = contentRect(width, height, collapsed, maximized);
    const header_y = content.y + top_strip_height;
    const footer_y = content.y + content.height - footer_height;
    const rows_top = header_y + table_header_height;
    const rows_bottom = footer_y - 6;
    return .{
        .x = content.x,
        .y = rows_top,
        .width = content.width,
        .height = rows_bottom - rows_top,
    };
}

fn rootRect(width: u32, height: u32, maximized: bool) Rect {
    return chrome.rootRectStyled(width, height, maximized);
}

fn sidebarWidth(collapsed: bool) f64 {
    return if (collapsed) sidebar_collapsed_width else sidebar_expanded_width;
}

fn sidebarRect(width: u32, height: u32, collapsed: bool, maximized: bool) Rect {
    const root = rootRect(width, height, maximized);
    return .{
        .x = root.x + 12,
        .y = root.y + titlebar_height + 6,
        .width = sidebarWidth(collapsed),
        .height = root.height - titlebar_height - 18,
    };
}

fn contentRect(width: u32, height: u32, collapsed: bool, maximized: bool) Rect {
    const root = rootRect(width, height, maximized);
    const side = sidebarRect(width, height, collapsed, maximized);
    return .{
        .x = side.x + side.width + 18,
        .y = root.y + titlebar_height + 6,
        .width = root.x + root.width - (side.x + side.width + 30),
        .height = root.height - titlebar_height - 18,
    };
}

fn titlebarDragRect(width: u32, height: u32, maximized: bool) Rect {
    return chrome.titlebarDragRectStyled(width, height, 120, 120, maximized);
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

fn previousRect(width: u32, height: u32, collapsed: bool, maximized: bool) Rect {
    const content = contentRect(width, height, collapsed, maximized);
    return .{ .x = content.x + 10, .y = content.y + 10, .width = toolbar_button_size, .height = toolbar_button_size };
}

fn nextRect(width: u32, height: u32, collapsed: bool, maximized: bool) Rect {
    const previous = previousRect(width, height, collapsed, maximized);
    return .{ .x = previous.x + previous.width + toolbar_button_gap, .y = previous.y, .width = toolbar_button_size, .height = toolbar_button_size };
}

fn upRect(width: u32, height: u32, collapsed: bool, maximized: bool) Rect {
    const next = nextRect(width, height, collapsed, maximized);
    return .{ .x = next.x + next.width + toolbar_button_gap, .y = next.y, .width = toolbar_button_size, .height = toolbar_button_size };
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

fn openSelectedRect(width: u32, height: u32, collapsed: bool, maximized: bool) Rect {
    const content = contentRect(width, height, collapsed, maximized);
    return .{
        .x = content.x + content.width - 84.0,
        .y = content.y + 10,
        .width = 84.0,
        .height = action_button_height,
    };
}

fn deleteRect(width: u32, height: u32, collapsed: bool, maximized: bool) Rect {
    _ = collapsed;
    const total_width = 108.0 + action_button_gap + 92.0;
    const root = rootRect(width, height, maximized);
    const start_x = (root.x + root.width / 2.0) - total_width / 2.0;
    return .{
        .x = start_x + 108.0 + action_button_gap,
        .y = 12,
        .width = 92.0,
        .height = action_button_height,
    };
}

fn renameRect(width: u32, height: u32, collapsed: bool, maximized: bool) Rect {
    _ = collapsed;
    const total_width = 108.0 + action_button_gap + 92.0;
    const root = rootRect(width, height, maximized);
    const start_x = (root.x + root.width / 2.0) - total_width / 2.0;
    return .{
        .x = start_x,
        .y = 12,
        .width = 108.0,
        .height = action_button_height,
    };
}

fn newFolderRect(width: u32, height: u32, collapsed: bool, maximized: bool) Rect {
    const open_button = openSelectedRect(width, height, collapsed, maximized);
    return .{
        .x = open_button.x - 118.0 - action_button_gap,
        .y = open_button.y,
        .width = 118.0,
        .height = action_button_height,
    };
}

fn breadcrumbTargetRect(width: u32, height: u32, collapsed: bool, current_dir: []const u8, maximized: bool) Rect {
    const content = contentRect(width, height, collapsed, maximized);
    const base = basenameLabel(current_dir);
    const estimated_width = @min(220.0, 18.0 + @as(f64, @floatFromInt(base.len)) * 9.0);
    return .{
        .x = content.x + 232,
        .y = content.y + 12,
        .width = estimated_width,
        .height = 28.0,
    };
}

fn entryRect(width: u32, height: u32, index: usize, collapsed: bool, maximized: bool) Rect {
    const rows = scrollRegionRect(width, height, collapsed, maximized);
    return .{
        .x = rows.x,
        .y = rows.y + @as(f64, @floatFromInt(index)) * row_height,
        .width = rows.width - scrollbarReserve(),
        .height = row_height,
    };
}

fn drawTitlebar(cr: *c.cairo_t, width: u32, height: u32, snapshot: browser.Snapshot, hovered: Hit, sidebar_collapsed: bool, picker_mode: bool, maximized: bool) void {
    chrome.drawWindowShell(cr, width, height, .{
        .title = if (picker_mode) "Selecionar Wallpaper" else "Arquivos",
        .title_x = 86,
        .attached_to_edges = maximized,
    }, hoveredControl(hovered));
    drawTopGlyphButton(cr, toggleSidebarRect(), "=", hovered == .toggle_sidebar);
    drawTopGlyphButton(cr, appGlyphRect(), if (sidebar_collapsed) ">" else "<", false);
    if (!picker_mode) {
        drawActionButton(
            cr,
            renameRect(width, height, sidebar_collapsed, maximized),
            "Renomear",
            snapshot.selected_exists,
            hovered == .rename_selected,
            .secondary,
        );
        drawActionButton(
            cr,
            deleteRect(width, height, sidebar_collapsed, maximized),
            "Excluir",
            snapshot.selected_exists,
            hovered == .delete_selected,
            .danger,
        );
    }
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
        const active = matchesSidebar(snapshot.current_sidebar, item.target);
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
        const active = matchesSidebar(snapshot.current_sidebar, item.target);
        drawSidebarItem(cr, rect, item.icon, item.label, active, hovered_item, sidebar_icons.surfaceFor(item.target));

        if (index == 5 or index == 6) {
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
    maximized: bool,
) void {
    drawToolbarButton(cr, previousRect(width, height, sidebar_collapsed, maximized), "<", hovered == .previous);
    drawToolbarButton(cr, nextRect(width, height, sidebar_collapsed, maximized), ">", hovered == .next);
    drawToolbarButton(cr, upRect(width, height, sidebar_collapsed, maximized), "^", hovered == .up or hovered == .breadcrumb_up);
    if (!picker_mode) {
        drawActionButton(
            cr,
            newFolderRect(width, height, sidebar_collapsed, maximized),
            "Nova pasta",
            true,
            hovered == .new_folder,
            .primary,
        );
        drawActionButton(
            cr,
            openSelectedRect(width, height, sidebar_collapsed, maximized),
            "Abrir",
            snapshot.selected_exists,
            hovered == .open_selected,
            .secondary,
        );
    }
    drawBreadcrumb(cr, width, height, snapshot.current_dir, hovered == .breadcrumb_up, sidebar_collapsed, maximized);
    if (picker_mode) drawPickerHint(cr, content);

    const header_y = content.y + top_strip_height;
    const footer_y = content.y + content.height - footer_height;
    c.cairo_rectangle(cr, content.x, header_y, content.width, 1);
    c.cairo_set_source_rgba(cr, 0.31, 0.94, 1.0, 0.85);
    c.cairo_fill(cr);

    drawColumnHeaders(cr, content, header_y, snapshot.modified_descending, hovered == .sort_modified);

    if (snapshot.count == 0) {
        drawEmptyState(cr, content, picker_mode);
    } else {
        const rows_area = scrollRegionRect(width, height, sidebar_collapsed, maximized);
        c.cairo_save(cr);
        c.cairo_rectangle(cr, rows_area.x, rows_area.y, rows_area.width, rows_area.height);
        c.cairo_clip(cr);
        for (0..snapshot.count) |index| {
            const rect = Rect{
                .x = rows_area.x,
                .y = rows_area.y + @as(f64, @floatFromInt(index)) * row_height,
                .width = rows_area.width - scrollbarReserve(),
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
        drawScrollbar(cr, rows_area, snapshot);
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

fn drawScrollbar(cr: *c.cairo_t, rows_area: Rect, snapshot: browser.Snapshot) void {
    if (snapshot.total_count <= snapshot.count or snapshot.count == 0) return;

    const track = Rect{
        .x = rows_area.x + rows_area.width - scrollbar_width,
        .y = rows_area.y + 4,
        .width = scrollbar_width,
        .height = rows_area.height - 8,
    };
    drawRoundedRect(cr, track, scrollbar_width / 2.0);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.05);
    c.cairo_fill(cr);

    const visible_ratio = @as(f64, @floatFromInt(snapshot.count)) / @as(f64, @floatFromInt(snapshot.total_count));
    const thumb_height = @max(30.0, track.height * visible_ratio);
    const max_start = @max(snapshot.total_count - snapshot.count, 1);
    const progress = @as(f64, @floatFromInt(snapshot.page_start)) / @as(f64, @floatFromInt(max_start));
    const thumb_y = track.y + (track.height - thumb_height) * progress;
    const thumb = Rect{
        .x = track.x,
        .y = thumb_y,
        .width = track.width,
        .height = thumb_height,
    };
    drawRoundedRect(cr, thumb, scrollbar_width / 2.0);
    c.cairo_set_source_rgba(cr, 0.42, 0.88, 0.98, 0.50);
    c.cairo_fill(cr);
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

fn drawBreadcrumb(cr: *c.cairo_t, width: u32, height: u32, current_dir: []const u8, hovered: bool, collapsed: bool, maximized: bool) void {
    const content = contentRect(width, height, collapsed, maximized);
    const y = content.y + 30;
    const breadcrumb_x = content.x + 124;
    const separator_x = breadcrumb_x + 92;
    drawLabel(cr, breadcrumb_x, y, 15, "Local atual", 0.70, 0.72, 0.77);
    drawLabel(cr, separator_x, y, 17, "/", 0.86, 0.87, 0.9);
    if (hovered) {
        const target = breadcrumbTargetRect(width, height, collapsed, current_dir, maximized);
        drawRoundedRect(cr, target, 8);
        c.cairo_set_source_rgba(cr, 1, 1, 1, 0.05);
        c.cairo_fill(cr);
    }
    drawLabel(cr, separator_x + 24, y, 15, basenameLabel(current_dir), 0.38, 0.88, 0.98);
}

fn drawColumnHeaders(cr: *c.cairo_t, content: Rect, header_y: f64, modified_descending: bool, modified_hovered: bool) void {
    const name_x = content.x + 10;
    const modified_x = content.x + content.width * 0.46;
    const size_x = content.x + content.width * 0.80 - scrollbarReserve();
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

fn scrollbarReserve() f64 {
    return scrollbar_width + scrollbar_gap;
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
        .x = content.x + (content.width - 220) / 2.0,
        .y = content.y + 138,
        .width = 220,
        .height = 156,
    };

    drawFolderGlyph(cr, .{
        .x = center.x + 72,
        .y = center.y + 10,
        .width = 76,
        .height = 58,
    });
    drawCenteredLabel(cr, .{
        .x = center.x,
        .y = center.y + 84,
        .width = center.width,
        .height = 28,
    }, 18, "Vazio", 0.92, 0.93, 0.96);
    if (picker_mode) {
        drawCenteredLabel(cr, .{
            .x = center.x,
            .y = center.y + 114,
            .width = center.width,
            .height = 24,
        }, 13, "Nenhuma imagem nesta pasta", 0.66, 0.68, 0.73);
    }
}

fn drawFolderGlyph(cr: *c.cairo_t, rect: Rect) void {
    const tab = Rect{
        .x = rect.x + rect.width * 0.12,
        .y = rect.y + rect.height * 0.10,
        .width = rect.width * 0.34,
        .height = rect.height * 0.20,
    };
    const back = Rect{
        .x = rect.x + rect.width * 0.06,
        .y = rect.y + rect.height * 0.24,
        .width = rect.width * 0.88,
        .height = rect.height * 0.56,
    };

    drawRoundedRect(cr, tab, @max(2.5, rect.height * 0.08));
    c.cairo_set_source_rgba(cr, 0.99, 0.85, 0.42, 0.98);
    c.cairo_fill(cr);

    drawRoundedRect(cr, back, @max(3.0, rect.height * 0.10));
    c.cairo_set_source_rgba(cr, 0.97, 0.77, 0.22, 0.98);
    c.cairo_fill_preserve(cr);
    c.cairo_set_source_rgba(cr, 0.70, 0.50, 0.08, 0.18);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);

    c.cairo_new_sub_path(cr);
    c.cairo_move_to(cr, rect.x + rect.width * 0.04, rect.y + rect.height * 0.44);
    c.cairo_line_to(cr, rect.x + rect.width * 0.28, rect.y + rect.height * 0.34);
    c.cairo_line_to(cr, rect.x + rect.width * 0.97, rect.y + rect.height * 0.34);
    c.cairo_line_to(cr, rect.x + rect.width * 0.88, rect.y + rect.height * 0.88);
    c.cairo_line_to(cr, rect.x + rect.width * 0.12, rect.y + rect.height * 0.88);
    c.cairo_close_path(cr);
    c.cairo_set_source_rgba(cr, 0.95, 0.73, 0.16, 0.99);
    c.cairo_fill_preserve(cr);
    c.cairo_set_source_rgba(cr, 0.66, 0.46, 0.08, 0.22);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);

    c.cairo_new_sub_path(cr);
    c.cairo_move_to(cr, rect.x + rect.width * 0.09, rect.y + rect.height * 0.50);
    c.cairo_line_to(cr, rect.x + rect.width * 0.30, rect.y + rect.height * 0.40);
    c.cairo_line_to(cr, rect.x + rect.width * 0.90, rect.y + rect.height * 0.40);
    c.cairo_line_to(cr, rect.x + rect.width * 0.84, rect.y + rect.height * 0.54);
    c.cairo_line_to(cr, rect.x + rect.width * 0.14, rect.y + rect.height * 0.54);
    c.cairo_close_path(cr);
    c.cairo_set_source_rgba(cr, 1.0, 0.90, 0.56, 0.24);
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
    drawRoundedRect(cr, rect, 9);
    c.cairo_set_source_rgba(cr, 1, 1, 1, if (hovered) 0.08 else 0.04);
    c.cairo_fill_preserve(cr);
    c.cairo_set_source_rgba(cr, 1, 1, 1, if (hovered) 0.08 else 0.05);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);
    drawToolbarGlyph(cr, rect, label, 0.90, 0.92, 0.96);
}

fn drawToolbarGlyph(cr: *c.cairo_t, rect: Rect, glyph: []const u8, r: f64, g: f64, b: f64) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);

    c.cairo_set_source_rgb(cr, r, g, b);
    c.cairo_set_line_width(cr, 1.8);
    c.cairo_set_line_cap(cr, c.CAIRO_LINE_CAP_ROUND);
    c.cairo_set_line_join(cr, c.CAIRO_LINE_JOIN_ROUND);

    const cx = rect.x + rect.width / 2.0;
    const cy = rect.y + rect.height / 2.0;

    if (std.mem.eql(u8, glyph, "<")) {
        c.cairo_move_to(cr, cx + 3.0, cy - 5.0);
        c.cairo_line_to(cr, cx - 2.0, cy);
        c.cairo_line_to(cr, cx + 3.0, cy + 5.0);
        c.cairo_stroke(cr);
        return;
    }
    if (std.mem.eql(u8, glyph, ">")) {
        c.cairo_move_to(cr, cx - 3.0, cy - 5.0);
        c.cairo_line_to(cr, cx + 2.0, cy);
        c.cairo_line_to(cr, cx - 3.0, cy + 5.0);
        c.cairo_stroke(cr);
        return;
    }
    if (std.mem.eql(u8, glyph, "^")) {
        c.cairo_move_to(cr, cx - 5.0, cy + 2.5);
        c.cairo_line_to(cr, cx, cy - 3.5);
        c.cairo_line_to(cr, cx + 5.0, cy + 2.5);
        c.cairo_stroke(cr);
        return;
    }
    if (std.mem.eql(u8, glyph, "open")) {
        c.cairo_rectangle(cr, cx - 5.5, cy - 4.5, 8.0, 8.0);
        c.cairo_stroke(cr);
        c.cairo_move_to(cr, cx - 1.5, cy + 1.5);
        c.cairo_line_to(cr, cx + 5.0, cy - 5.0);
        c.cairo_move_to(cr, cx + 1.0, cy - 5.0);
        c.cairo_line_to(cr, cx + 5.0, cy - 5.0);
        c.cairo_line_to(cr, cx + 5.0, cy - 1.0);
        c.cairo_stroke(cr);
        return;
    }
    if (std.mem.eql(u8, glyph, "rename")) {
        c.cairo_move_to(cr, cx - 4.5, cy + 4.5);
        c.cairo_line_to(cr, cx - 1.5, cy + 1.5);
        c.cairo_line_to(cr, cx + 4.5, cy - 4.5);
        c.cairo_stroke(cr);
        c.cairo_move_to(cr, cx - 4.5, cy + 4.5);
        c.cairo_line_to(cr, cx - 0.5, cy + 3.5);
        c.cairo_stroke(cr);
        return;
    }
    if (std.mem.eql(u8, glyph, "delete")) {
        c.cairo_move_to(cr, cx - 5.0, cy - 3.0);
        c.cairo_line_to(cr, cx + 5.0, cy - 3.0);
        c.cairo_move_to(cr, cx - 3.5, cy - 5.0);
        c.cairo_line_to(cr, cx + 3.5, cy - 5.0);
        c.cairo_move_to(cr, cx - 4.0, cy - 3.0);
        c.cairo_line_to(cr, cx - 3.0, cy + 5.0);
        c.cairo_line_to(cr, cx + 3.0, cy + 5.0);
        c.cairo_line_to(cr, cx + 4.0, cy - 3.0);
        c.cairo_stroke(cr);
        return;
    }
    if (std.mem.eql(u8, glyph, "new-folder")) {
        drawFolderGlyph(cr, .{
            .x = rect.x + 5,
            .y = rect.y + 7,
            .width = 14,
            .height = 12,
        });
        c.cairo_move_to(cr, cx + 4.0, cy - 1.0);
        c.cairo_line_to(cr, cx + 4.0, cy + 5.0);
        c.cairo_move_to(cr, cx + 1.0, cy + 2.0);
        c.cairo_line_to(cr, cx + 7.0, cy + 2.0);
        c.cairo_stroke(cr);
        return;
    }
}

fn drawActionButton(cr: *c.cairo_t, rect: Rect, label: []const u8, enabled: bool, hovered: bool, tone: ActionTone) void {
    drawRoundedRect(cr, rect, 10);
    if (enabled) {
        const fill = switch (tone) {
            .primary => [4]f64{ if (hovered) 0.20 else 0.16, if (hovered) 0.56 else 0.46, if (hovered) 0.76 else 0.62, if (hovered) 0.90 else 0.74 },
            .secondary => [4]f64{ 1.0, 1.0, 1.0, if (hovered) 0.08 else 0.05 },
            .danger => [4]f64{ 0.80, 0.26, 0.30, if (hovered) 0.28 else 0.20 },
        };
        c.cairo_set_source_rgba(cr, fill[0], fill[1], fill[2], fill[3]);
        c.cairo_fill_preserve(cr);
        const stroke = switch (tone) {
            .primary => [4]f64{ 0.44, 0.88, 0.98, 0.28 },
            .secondary => [4]f64{ 1.0, 1.0, 1.0, 0.08 },
            .danger => [4]f64{ 1.0, 0.46, 0.52, 0.24 },
        };
        c.cairo_set_source_rgba(cr, stroke[0], stroke[1], stroke[2], stroke[3]);
        c.cairo_set_line_width(cr, 1);
        c.cairo_stroke(cr);
        drawCenteredLabel(cr, rect, 13.5, label, 0.95, 0.97, 1.0);
    } else {
        c.cairo_set_source_rgba(cr, 1, 1, 1, 0.04);
        c.cairo_fill_preserve(cr);
        c.cairo_set_source_rgba(cr, 1, 1, 1, 0.05);
        c.cairo_set_line_width(cr, 1);
        c.cairo_stroke(cr);
        drawCenteredLabel(cr, rect, 13.5, label, 0.58, 0.60, 0.64);
    }
}

fn drawDialog(cr: *c.cairo_t, width: u32, height: u32, kind: DialogKind, input: []const u8, subject: []const u8, hovered: Hit, maximized: bool) void {
    const overlay = rootRect(width, height, maximized);
    c.cairo_rectangle(cr, overlay.x, overlay.y, overlay.width, overlay.height);
    c.cairo_set_source_rgba(cr, 0.01, 0.02, 0.04, 0.58);
    c.cairo_fill(cr);

    const card = dialogRect(width, height, maximized);
    drawRoundedRect(cr, card, 14);
    c.cairo_set_source_rgba(cr, 0.09, 0.10, 0.12, 0.98);
    c.cairo_fill_preserve(cr);
    c.cairo_set_source_rgba(cr, 0.38, 0.91, 1.0, 0.28);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);

    const title = switch (kind) {
        .new_folder => "Nova pasta",
        .rename => "Renomear item",
        .delete_confirm => "Mover para a lixeira",
        .delete_permanent_confirm => "Excluir permanentemente",
        .none => "",
    };
    const subtitle = switch (kind) {
        .new_folder => "Escolha um nome para a nova pasta.",
        .rename => "Digite o novo nome do item selecionado.",
        .delete_confirm => "O item selecionado será enviado para a lixeira.",
        .delete_permanent_confirm => "Esta ação apaga o item sem passar pela lixeira.",
        .none => "",
    };
    drawLabel(cr, card.x + 18, card.y + 30, 18, title, 0.96, 0.97, 0.99);
    drawLabel(cr, card.x + 18, card.y + 54, 13.5, subtitle, 0.72, 0.74, 0.78);

    if (kind == .delete_confirm or kind == .delete_permanent_confirm) {
        const subject_rect = Rect{ .x = card.x + 18, .y = card.y + 76, .width = card.width - 36, .height = 44 };
        drawRoundedRect(cr, subject_rect, 10);
        c.cairo_set_source_rgba(cr, 1, 1, 1, 0.05);
        c.cairo_fill(cr);
        drawLabel(cr, subject_rect.x + 14, subject_rect.y + 28, 15, subject, 0.92, 0.93, 0.96);
    } else {
        const input_rect = dialogInputRect(width, height, maximized);
        drawRoundedRect(cr, input_rect, 10);
        c.cairo_set_source_rgba(cr, 1, 1, 1, 0.05);
        c.cairo_fill_preserve(cr);
        c.cairo_set_source_rgba(cr, 0.38, 0.91, 1.0, 0.20);
        c.cairo_set_line_width(cr, 1);
        c.cairo_stroke(cr);
        drawLabel(cr, input_rect.x + 14, input_rect.y + 27, 15, if (input.len == 0) "Digite aqui..." else input, if (input.len == 0) 0.54 else 0.94, if (input.len == 0) 0.56 else 0.95, if (input.len == 0) 0.60 else 0.97);
    }

    drawActionButton(cr, dialogCancelRect(width, height, maximized), "Cancelar", true, hovered == .dialog_cancel, .secondary);
    drawActionButton(
        cr,
        dialogConfirmRect(width, height, maximized),
        if (kind == .delete_confirm) "Mover" else if (kind == .delete_permanent_confirm) "Excluir" else "Confirmar",
        if (kind == .delete_confirm or kind == .delete_permanent_confirm) true else input.len > 0,
        hovered == .dialog_confirm,
        if (kind == .delete_confirm) .secondary else if (kind == .delete_permanent_confirm) .danger else .primary,
    );
}

fn dialogRect(width: u32, height: u32, maximized: bool) Rect {
    const root = rootRect(width, height, maximized);
    return .{
        .x = root.x + (root.width - 420) / 2.0,
        .y = root.y + (root.height - 196) / 2.0,
        .width = 420,
        .height = 196,
    };
}

fn dialogInputRect(width: u32, height: u32, maximized: bool) Rect {
    const card = dialogRect(width, height, maximized);
    return .{
        .x = card.x + 18,
        .y = card.y + 76,
        .width = card.width - 36,
        .height = 44,
    };
}

fn dialogCancelRect(width: u32, height: u32, maximized: bool) Rect {
    const card = dialogRect(width, height, maximized);
    return .{
        .x = card.x + card.width - 214,
        .y = card.y + card.height - 50,
        .width = 92,
        .height = 32,
    };
}

fn dialogConfirmRect(width: u32, height: u32, maximized: bool) Rect {
    const card = dialogRect(width, height, maximized);
    return .{
        .x = card.x + card.width - 112,
        .y = card.y + card.height - 50,
        .width = 94,
        .height = 32,
    };
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

fn modifiedHeaderRect(width: u32, height: u32, collapsed: bool, maximized: bool) Rect {
    const content = contentRect(width, height, collapsed, maximized);
    return .{
        .x = content.x + content.width * 0.46 - 4,
        .y = content.y + top_strip_height + 4,
        .width = 134,
        .height = 24,
    };
}

fn matchesSidebar(current_sidebar: ?browser.SidebarTarget, target: browser.SidebarTarget) bool {
    return current_sidebar != null and current_sidebar.? == target;
}
