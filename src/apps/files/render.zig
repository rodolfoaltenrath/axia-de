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
const selection_context_menu_width = 220.0;
const empty_context_menu_width = 360.0;
const context_menu_item_height = 40.0;
const context_menu_padding = 8.0;
const context_menu_separator_height = 1.0;
const sidebar_default_top_offset = 46.0;
const sidebar_default_item_height = 30.0;
const sidebar_default_item_step = 40.0;

pub const DialogKind = enum {
    none,
    new_folder,
    new_file,
    rename,
    delete_confirm,
    delete_permanent_confirm,
};

const ActionTone = enum {
    primary,
    secondary,
    danger,
};

pub const ViewOptions = struct {
    zoom_level: u8 = 1,
    show_details: bool = false,
    context_menu: ?ContextMenu = null,
};

pub const ContextMenu = struct {
    x: f64,
    y: f64,
    kind: ContextMenuKind = .selection,
    details_enabled: bool,
    can_pin: bool,
    can_unpin: bool,
    sort_field: browser.SortField = .modified,
};

pub const ContextMenuKind = enum {
    selection,
    empty_space,
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
    context_details,
    context_pin,
    context_unpin,
    context_new_folder,
    context_new_file,
    context_open_terminal,
    context_select_all,
    context_paste,
    context_sort_name,
    context_sort_modified,
    context_sort_size,
    dialog_confirm,
    dialog_cancel,
    sidebar: browser.SidebarTarget,
    pinned_folder: usize,
    entry: usize,
};

pub fn draw(
    cr: *c.cairo_t,
    width: u32,
    height: u32,
    snapshot: *const browser.Snapshot,
    hovered: Hit,
    sidebar_collapsed: bool,
    sidebar_icons: *const icons.SidebarIcons,
    picker_mode: bool,
    dialog_kind: DialogKind,
    dialog_input: []const u8,
    dialog_subject: []const u8,
    maximized: bool,
    view: ViewOptions,
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
    drawContent(cr, width, height, content, snapshot, hovered, sidebar_collapsed, sidebar_icons, picker_mode, maximized, view);
    if (view.context_menu == null and dialog_kind == .none) {
        drawTooltip(cr, width, height, snapshot, hovered, sidebar_collapsed, maximized);
    }
    if (view.context_menu) |menu| drawContextMenu(cr, menu, hovered);
    if (dialog_kind != .none) {
        drawDialog(cr, width, height, dialog_kind, dialog_input, dialog_subject, hovered, maximized);
    }
}

pub fn hitTest(
    width: u32,
    height: u32,
    x: f64,
    y: f64,
    current_dir: []const u8,
    visible_count: usize,
    pinned_count: usize,
    sidebar_collapsed: bool,
    picker_mode: bool,
    dialog_kind: DialogKind,
    maximized: bool,
    view: ViewOptions,
) Hit {
    _ = picker_mode;
    if (dialog_kind != .none) {
        if (dialogConfirmRect(width, height, maximized).contains(x, y)) return .dialog_confirm;
        if (dialogCancelRect(width, height, maximized).contains(x, y)) return .dialog_cancel;
        return .none;
    }

    if (view.context_menu) |menu| {
        const action = contextMenuHit(menu, x, y);
        if (action != .none) return action;
    }

    if (closeRect(width).contains(x, y)) return .close;
    if (maximizeRect(width).contains(x, y)) return .maximize;
    if (minimizeRect(width).contains(x, y)) return .minimize;
    if (toggleSidebarRect().contains(x, y)) return .toggle_sidebar;

    if (upRect(width, height, sidebar_collapsed, maximized).contains(x, y)) return .up;
    if (breadcrumbTargetRect(width, height, sidebar_collapsed, current_dir, maximized).contains(x, y)) return .breadcrumb_up;
    if (previousRect(width, height, sidebar_collapsed, maximized).contains(x, y)) return .previous;
    if (nextRect(width, height, sidebar_collapsed, maximized).contains(x, y)) return .next;
    if (view.show_details and modifiedHeaderRect(width, height, sidebar_collapsed, maximized).contains(x, y)) return .sort_modified;

    const sidebar = sidebarRect(width, height, sidebar_collapsed, maximized);
    for (browser.sidebar_items) |item| {
        if (sidebarItemRect(sidebar, item.target).contains(x, y)) {
            return .{ .sidebar = item.target };
        }
    }
    for (0..pinned_count) |index| {
        if (pinnedItemRect(sidebar, index).contains(x, y)) {
            return .{ .pinned_folder = index };
        }
    }

    for (0..visible_count) |index| {
        if (entryRect(width, height, index, sidebar_collapsed, maximized, view).contains(x, y)) {
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
    const rows_top = header_y + 8;
    const rows_bottom = footer_y + footer_height - 4;
    return .{
        .x = content.x + 4,
        .y = rows_top,
        .width = content.width - 8,
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
    return chrome.titlebarDragRectStyled(width, height, 366, 120, maximized);
}

fn toggleSidebarRect() Rect {
    return .{ .x = 28, .y = 18, .width = 18, .height = 18 };
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
    const layout = sidebarItemLayout(sidebar);
    return .{
        .x = sidebar.x + 10,
        .y = sidebar.y + layout.top_offset + index * layout.step,
        .width = sidebar.width - 20,
        .height = layout.item_height,
    };
}

fn pinnedItemRect(sidebar: Rect, index: usize) Rect {
    const layout = sidebarItemLayout(sidebar);
    const base_y = sidebar.y + layout.top_offset + @as(f64, @floatFromInt(browser.sidebar_items.len)) * layout.step + 28;
    return .{
        .x = sidebar.x + 10,
        .y = base_y + @as(f64, @floatFromInt(index)) * layout.step,
        .width = sidebar.width - 20,
        .height = layout.item_height,
    };
}

const SidebarItemLayout = struct {
    top_offset: f64,
    step: f64,
    item_height: f64,
    compact: bool,
};

fn sidebarItemLayout(sidebar: Rect) SidebarItemLayout {
    const item_count = @as(f64, @floatFromInt(browser.sidebar_items.len));
    const default_needed = sidebar_default_top_offset +
        (item_count - 1.0) * sidebar_default_item_step +
        sidebar_default_item_height +
        12.0;
    if (sidebar.height >= default_needed) {
        return .{
            .top_offset = sidebar_default_top_offset,
            .step = sidebar_default_item_step,
            .item_height = sidebar_default_item_height,
            .compact = false,
        };
    }

    const top_offset = @max(14.0, @min(28.0, sidebar.height * 0.10));
    const bottom_padding = 10.0;
    const available_step = @max(16.0, (sidebar.height - top_offset - bottom_padding - sidebar_default_item_height) / (item_count - 1.0));
    const item_height = @max(18.0, @min(sidebar_default_item_height, available_step - 2.0));
    return .{
        .top_offset = top_offset,
        .step = available_step,
        .item_height = item_height,
        .compact = true,
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

pub fn visibleEntryCapacity(width: u32, height: u32, collapsed: bool, maximized: bool, view: ViewOptions) usize {
    const rows = scrollRegionRect(width, height, collapsed, maximized);
    const metrics = gridMetrics(rows, view);
    return metrics.columns * metrics.rows;
}

pub fn visibleColumns(width: u32, height: u32, collapsed: bool, maximized: bool, view: ViewOptions) usize {
    const rows = scrollRegionRect(width, height, collapsed, maximized);
    return gridMetrics(rows, view).columns;
}

fn entryRect(width: u32, height: u32, index: usize, collapsed: bool, maximized: bool, view: ViewOptions) Rect {
    const rows = scrollRegionRect(width, height, collapsed, maximized);
    const metrics = gridMetrics(rows, view);
    const col = index % metrics.columns;
    const row = index / metrics.columns;
    const start_x = rows.x + 2.0;
    return .{
        .x = start_x + @as(f64, @floatFromInt(col)) * (metrics.tile_width + metrics.gap),
        .y = rows.y + @as(f64, @floatFromInt(row)) * (metrics.tile_height + metrics.gap),
        .width = metrics.tile_width,
        .height = metrics.tile_height,
    };
}

fn drawTitlebar(cr: *c.cairo_t, width: u32, height: u32, snapshot: *const browser.Snapshot, hovered: Hit, sidebar_collapsed: bool, picker_mode: bool, maximized: bool) void {
    _ = snapshot;
    _ = picker_mode;
    chrome.drawWindowShell(cr, width, height, .{
        .title = "",
        .title_x = 0,
        .attached_to_edges = maximized,
    }, hoveredControl(hovered));
    drawFilesMenuBar(cr, width, height, hovered, sidebar_collapsed, maximized);
}

fn drawFilesMenuBar(cr: *c.cairo_t, width: u32, height: u32, hovered: Hit, sidebar_collapsed: bool, maximized: bool) void {
    _ = height;
    _ = maximized;

    drawSidebarToggleButton(cr, toggleSidebarRect(), hovered == .toggle_sidebar, sidebar_collapsed);
    drawMenuLabel(cr, 76, 31, "Arquivo");
    drawMenuLabel(cr, 155, 31, "Editar");
    drawMenuLabel(cr, 223, 31, "Exibir");
    drawMenuLabel(cr, 292, 31, "Ordenar");
    drawFilesWindowControls(cr, width, hovered);
}

fn drawSidebar(
    cr: *c.cairo_t,
    sidebar: Rect,
    snapshot: *const browser.Snapshot,
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

        const layout = sidebarItemLayout(sidebar);
        if ((index == 5 or index == 6) and !layout.compact) {
            c.cairo_rectangle(cr, sidebar.x + 18, rect.y + rect.height + 10, sidebar.width - 36, 1);
            c.cairo_set_source_rgba(cr, 1, 1, 1, 0.08);
            c.cairo_fill(cr);
        }
    }

    if (snapshot.pinned_count > 0) {
        const first_pin = pinnedItemRect(sidebar, 0);
        c.cairo_rectangle(cr, sidebar.x + 18, first_pin.y - 14, sidebar.width - 36, 1);
        c.cairo_set_source_rgba(cr, 1, 1, 1, 0.08);
        c.cairo_fill(cr);
        for (0..snapshot.pinned_count) |index| {
            const rect = pinnedItemRect(sidebar, index);
            const hovered_item = switch (hovered) {
                .pinned_folder => |pinned_index| pinned_index == index,
                else => false,
            };
            drawSidebarItem(cr, rect, "P", snapshot.pinned[index].labelText(), false, hovered_item, null);
        }
    }
}

fn drawContent(
    cr: *c.cairo_t,
    width: u32,
    height: u32,
    content: Rect,
    snapshot: *const browser.Snapshot,
    hovered: Hit,
    sidebar_collapsed: bool,
    sidebar_icons: *const icons.SidebarIcons,
    picker_mode: bool,
    maximized: bool,
    view: ViewOptions,
) void {
    drawToolbarButton(cr, previousRect(width, height, sidebar_collapsed, maximized), "<", hovered == .previous);
    drawToolbarButton(cr, nextRect(width, height, sidebar_collapsed, maximized), ">", hovered == .next);
    drawToolbarButton(cr, upRect(width, height, sidebar_collapsed, maximized), "^", hovered == .up or hovered == .breadcrumb_up);
    drawBreadcrumb(cr, width, height, snapshot.current_dir, hovered == .breadcrumb_up, sidebar_collapsed, maximized);
    if (picker_mode) drawPickerHint(cr, content);

    const header_y = content.y + top_strip_height;
    const footer_y = content.y + content.height - footer_height;
    c.cairo_rectangle(cr, content.x, header_y, content.width, 1);
    c.cairo_set_source_rgba(cr, 0.31, 0.94, 1.0, 0.85);
    c.cairo_fill(cr);

    if (view.show_details) {
        drawColumnHeaders(cr, content, header_y, snapshot.modified_descending, hovered == .sort_modified);
    }

    if (snapshot.count == 0) {
        drawEmptyState(cr, content, picker_mode);
    } else {
        const rows_area = scrollRegionRect(width, height, sidebar_collapsed, maximized);
        c.cairo_save(cr);
        c.cairo_rectangle(cr, rows_area.x, rows_area.y, rows_area.width, rows_area.height);
        c.cairo_clip(cr);
        for (0..snapshot.count) |index| {
            const rect = entryRect(width, height, index, sidebar_collapsed, maximized, view);
            const hovered_entry = switch (hovered) {
                .entry => |visible| visible == index,
                else => false,
            };
            drawEntryTile(
                cr,
                rect,
                snapshot.entries[index].kind,
                snapshot.entries[index].text(),
                snapshot.entries[index].modifiedText(),
                snapshot.entries[index].sizeText(),
                hovered_entry,
                snapshot.entries[index].selected,
                view.show_details,
                tileIconSize(view.zoom_level),
                sidebar_icons.folderSurface(),
                sidebar_icons.thumbnailFor(snapshot.entries[index].pathText()),
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
    const footer = if (snapshot.selected_count == 1)
        std.fmt.bufPrint(&footer_buf, "1 item selecionado  •  {s}", .{snapshot.selectedSizeText()}) catch "1 item selecionado"
    else if (snapshot.selected_count > 1 and snapshot.selected_file_count == snapshot.selected_count and snapshot.selectedSizeText().len > 0)
        std.fmt.bufPrint(&footer_buf, "{d} arquivos selecionados  •  {s}", .{ snapshot.selected_count, snapshot.selectedSizeText() }) catch "Arquivos selecionados"
    else if (snapshot.selected_count > 1)
        std.fmt.bufPrint(&footer_buf, "{d} itens selecionados", .{snapshot.selected_count}) catch "Itens selecionados"
    else if (snapshot.total_count == 0)
        (if (picker_mode) "Nenhuma imagem nesta pasta" else "Pasta vazia")
    else
        std.fmt.bufPrint(&footer_buf, "{d} itens", .{snapshot.total_count}) catch "Itens";
    drawLabel(cr, content.x, footer_y + 22, 13, footer, 0.78, 0.79, 0.82);
}

fn drawScrollbar(cr: *c.cairo_t, rows_area: Rect, snapshot: *const browser.Snapshot) void {
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

const GridMetrics = struct {
    columns: usize,
    rows: usize,
    tile_width: f64,
    tile_height: f64,
    gap: f64,
};

fn gridMetrics(area: Rect, view: ViewOptions) GridMetrics {
    const tile_width: f64 = switch (@min(view.zoom_level, 3)) {
        0 => 96.0,
        1 => 112.0,
        2 => 136.0,
        else => 164.0,
    };
    const icon_size = tileIconSize(view.zoom_level);
    const label_height: f64 = 38.0;
    const detail_height: f64 = if (view.show_details) 38.0 else 0.0;
    const tile_height: f64 = 8.0 + icon_size + 4.0 + label_height + detail_height + 6.0;
    const gap: f64 = 6.0;
    const usable_width = @max(1.0, area.width - scrollbarReserve());
    const cols_float = @floor((usable_width + gap) / (tile_width + gap));
    const rows_float = @floor((area.height + gap) / (tile_height + gap));
    return .{
        .columns = @max(1, @as(usize, @intFromFloat(@max(1.0, cols_float)))),
        .rows = @max(1, @as(usize, @intFromFloat(@max(1.0, rows_float)))),
        .tile_width = tile_width,
        .tile_height = tile_height,
        .gap = gap,
    };
}

fn tileIconSize(zoom_level: u8) f64 {
    return switch (@min(zoom_level, 3)) {
        0 => 54.0,
        1 => 64.0,
        2 => 78.0,
        else => 96.0,
    };
}

fn drawEntryTile(
    cr: *c.cairo_t,
    rect: Rect,
    kind: browser.EntryKind,
    label: []const u8,
    modified: []const u8,
    size: []const u8,
    hovered: bool,
    selected: bool,
    show_details: bool,
    icon_size: f64,
    folder_surface: ?*c.cairo_surface_t,
    thumbnail_surface: ?*c.cairo_surface_t,
) void {
    if (selected or hovered) {
        drawRoundedRect(cr, rect, 8);
        c.cairo_set_source_rgba(cr, if (selected) 0.20 else 1.0, if (selected) 0.58 else 1.0, if (selected) 0.82 else 1.0, if (selected) 0.20 else 0.05);
        c.cairo_fill_preserve(cr);
        c.cairo_set_source_rgba(cr, 0.40, 0.91, 1.0, if (selected) 0.28 else 0.06);
        c.cairo_set_line_width(cr, 1);
        c.cairo_stroke(cr);
    }

    const icon_rect = Rect{
        .x = rect.x + (rect.width - icon_size) / 2.0,
        .y = rect.y + 8,
        .width = icon_size,
        .height = icon_size,
    };

    if (kind == .directory) {
        drawFolderIcon(cr, icon_rect, folder_surface);
    } else if (thumbnail_surface) |thumbnail| {
        drawThumbnailPreview(cr, icon_rect, thumbnail);
    } else {
        drawFileGlyph(cr, icon_rect);
    }

    const label_rect = Rect{
        .x = rect.x + 6,
        .y = icon_rect.y + icon_rect.height + 4,
        .width = rect.width - 12,
        .height = if (show_details) 34.0 else @max(24.0, rect.y + rect.height - (icon_rect.y + icon_rect.height + 6)),
    };
    drawAdaptiveWrappedCenteredLabel(cr, label_rect, 14, label, 0.91, 0.92, 0.94);

    if (show_details) {
        const detail_top = label_rect.y + label_rect.height + 3;
        drawClippedCenteredLabel(cr, .{
            .x = rect.x + 8,
            .y = detail_top,
            .width = rect.width - 16,
            .height = 18,
        }, 11.5, size, 0.70, 0.73, 0.78);
        drawClippedCenteredLabel(cr, .{
            .x = rect.x + 8,
            .y = detail_top + 17,
            .width = rect.width - 16,
            .height = 18,
        }, 11.0, modified, 0.60, 0.63, 0.69);
    }
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
    const file_rect = Rect{
        .x = rect.x + rect.width * 0.18,
        .y = rect.y + rect.height * 0.08,
        .width = rect.width * 0.64,
        .height = rect.height * 0.76,
    };
    drawRoundedRect(cr, file_rect, @max(4.0, rect.width * 0.06));
    c.cairo_set_source_rgba(cr, 0.85, 0.85, 0.88, 0.22);
    c.cairo_fill_preserve(cr);
    c.cairo_set_source_rgba(cr, 0.85, 0.88, 0.92, 0.20);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);
}

fn drawFolderIcon(cr: *c.cairo_t, rect: Rect, surface: ?*c.cairo_surface_t) void {
    if (surface) |loaded| {
        drawImageSurface(cr, loaded, rect);
        return;
    }
    drawFolderGlyph(cr, .{
        .x = rect.x + rect.width * 0.08,
        .y = rect.y + rect.height * 0.14,
        .width = rect.width * 0.84,
        .height = rect.height * 0.68,
    });
}

fn drawThumbnailPreview(cr: *c.cairo_t, rect: Rect, surface: *c.cairo_surface_t) void {
    const preview = Rect{
        .x = rect.x + rect.width * 0.08,
        .y = rect.y + rect.height * 0.03,
        .width = rect.width * 0.84,
        .height = rect.height * 0.86,
    };
    drawRoundedRect(cr, preview, 6);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.07);
    c.cairo_fill_preserve(cr);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.13);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);

    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    drawRoundedRect(cr, .{
        .x = preview.x + 3,
        .y = preview.y + 3,
        .width = preview.width - 6,
        .height = preview.height - 6,
    }, 5);
    c.cairo_clip(cr);
    drawImageSurface(cr, surface, .{
        .x = preview.x + 3,
        .y = preview.y + 3,
        .width = preview.width - 6,
        .height = preview.height - 6,
    });
}

fn drawImageSurface(cr: *c.cairo_t, surface: *c.cairo_surface_t, rect: Rect) void {
    const src_w = @as(f64, @floatFromInt(c.cairo_image_surface_get_width(surface)));
    const src_h = @as(f64, @floatFromInt(c.cairo_image_surface_get_height(surface)));
    if (src_w <= 0 or src_h <= 0) return;

    const scale = @min(rect.width / src_w, rect.height / src_h);
    const draw_w = src_w * scale;
    const draw_h = src_h * scale;
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_translate(cr, rect.x + (rect.width - draw_w) / 2.0, rect.y + (rect.height - draw_h) / 2.0);
    c.cairo_scale(cr, scale, scale);
    c.cairo_set_source_surface(cr, surface, 0, 0);
    c.cairo_paint(cr);
}

fn drawSidebarToggleButton(cr: *c.cairo_t, rect: Rect, hovered: bool, collapsed: bool) void {
    if (hovered) {
        drawRoundedRect(cr, .{
            .x = rect.x - 7,
            .y = rect.y - 6,
            .width = rect.width + 14,
            .height = rect.height + 12,
        }, 7);
        c.cairo_set_source_rgba(cr, 0.35, 0.92, 1.0, 0.11);
        c.cairo_fill(cr);
    }

    c.cairo_save(cr);
    defer c.cairo_restore(cr);

    c.cairo_set_source_rgb(cr, 0.36, 0.93, 1.0);
    c.cairo_set_line_width(cr, 1.45);
    c.cairo_set_line_cap(cr, c.CAIRO_LINE_CAP_SQUARE);
    c.cairo_set_line_join(cr, c.CAIRO_LINE_JOIN_MITER);

    const x = rect.x + 4.0;
    const y = rect.y + 4.0;
    const w = rect.width - 8.0;
    const h = rect.height - 8.0;
    c.cairo_rectangle(cr, x, y, w, h);
    c.cairo_stroke(cr);

    c.cairo_move_to(cr, x + 3.0, y + 1.0);
    c.cairo_line_to(cr, x + 3.0, y + h - 1.0);
    c.cairo_stroke(cr);

    const cx = x + w * 0.66;
    const cy = y + h / 2.0;
    if (collapsed) {
        c.cairo_move_to(cr, cx - 2.0, cy - 3.0);
        c.cairo_line_to(cr, cx + 1.8, cy);
        c.cairo_line_to(cr, cx - 2.0, cy + 3.0);
    } else {
        c.cairo_move_to(cr, cx + 1.8, cy - 3.0);
        c.cairo_line_to(cr, cx - 2.0, cy);
        c.cairo_line_to(cr, cx + 1.8, cy + 3.0);
    }
    c.cairo_stroke(cr);
}

fn drawMenuLabel(cr: *c.cairo_t, x: f64, y: f64, text: []const u8) void {
    chrome.drawLabel(cr, x, y, 14, text, 0.36, 0.91, 1.0, c.CAIRO_FONT_WEIGHT_NORMAL);
}

fn drawFilesWindowControls(cr: *c.cairo_t, width: u32, hovered: Hit) void {
    drawFilesWindowControl(cr, minimizeRect(width), "minimize", hovered == .minimize);
    drawFilesWindowControl(cr, maximizeRect(width), "maximize", hovered == .maximize);
    drawFilesWindowControl(cr, closeRect(width), "close", hovered == .close);
}

fn drawFilesWindowControl(cr: *c.cairo_t, rect: Rect, kind: []const u8, hovered: bool) void {
    if (hovered) {
        drawRoundedRect(cr, .{
            .x = rect.x - 6,
            .y = rect.y - 5,
            .width = rect.width + 12,
            .height = rect.height + 10,
        }, 8);
        c.cairo_set_source_rgba(cr, if (std.mem.eql(u8, kind, "close")) 0.82 else 1.0, if (std.mem.eql(u8, kind, "close")) 0.28 else 1.0, if (std.mem.eql(u8, kind, "close")) 0.34 else 1.0, if (std.mem.eql(u8, kind, "close")) 0.18 else 0.07);
        c.cairo_fill(cr);
    }

    c.cairo_save(cr);
    defer c.cairo_restore(cr);

    c.cairo_set_line_width(cr, if (std.mem.eql(u8, kind, "minimize")) 1.9 else 1.65);
    c.cairo_set_line_cap(cr, c.CAIRO_LINE_CAP_ROUND);
    c.cairo_set_line_join(cr, c.CAIRO_LINE_JOIN_ROUND);
    c.cairo_set_source_rgba(cr, 0.88, 0.91, 0.94, 0.98);

    const cx = rect.x + rect.width / 2.0;
    const cy = rect.y + rect.height / 2.0;
    if (std.mem.eql(u8, kind, "minimize")) {
        c.cairo_move_to(cr, cx - 4.7, cy + 3.0);
        c.cairo_line_to(cr, cx + 4.7, cy + 3.0);
    } else if (std.mem.eql(u8, kind, "maximize")) {
        drawRoundedRect(cr, .{ .x = cx - 4.7, .y = cy - 4.2, .width = 9.4, .height = 8.4 }, 2.3);
    } else {
        c.cairo_move_to(cr, cx - 4.1, cy - 4.1);
        c.cairo_line_to(cr, cx + 4.1, cy + 4.1);
        c.cairo_move_to(cr, cx + 4.1, cy - 4.1);
        c.cairo_line_to(cr, cx - 4.1, cy + 4.1);
    }
    c.cairo_stroke(cr);
}

fn drawTooltip(cr: *c.cairo_t, width: u32, height: u32, snapshot: *const browser.Snapshot, hovered: Hit, sidebar_collapsed: bool, maximized: bool) void {
    const tooltip = tooltipForHit(width, height, snapshot.current_dir, hovered, sidebar_collapsed, maximized) orelse return;
    const padding_x = 10.0;
    const tooltip_width = textWidth(cr, tooltip.label, 12.5) + padding_x * 2.0;
    const tooltip_height = 28.0;
    const surface_width = @as(f64, @floatFromInt(width));
    const anchor_center = tooltip.anchor.x + tooltip.anchor.width / 2.0;
    var x = anchor_center - tooltip_width / 2.0;
    x = @max(6.0, @min(x, surface_width - tooltip_width - 6.0));

    var y = tooltip.anchor.y + tooltip.anchor.height + 8.0;
    if (y + tooltip_height > @as(f64, @floatFromInt(height)) - 8.0) {
        y = tooltip.anchor.y - tooltip_height - 8.0;
    }

    const rect = Rect{ .x = x, .y = y, .width = tooltip_width, .height = tooltip_height };
    drawRoundedRect(cr, rect, 7);
    c.cairo_set_source_rgba(cr, 0.04, 0.045, 0.05, 0.96);
    c.cairo_fill_preserve(cr);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.12);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);
    drawCenteredTextLine(cr, rect.x, rect.y, rect.width, rect.height, 12.5, tooltip.label, 0.90, 0.92, 0.95);
}

const Tooltip = struct {
    label: []const u8,
    anchor: Rect,
};

fn tooltipForHit(width: u32, height: u32, current_dir: []const u8, hovered: Hit, sidebar_collapsed: bool, maximized: bool) ?Tooltip {
    return switch (hovered) {
        .toggle_sidebar => .{
            .label = if (sidebar_collapsed) "Expandir pastas" else "Recolher pastas",
            .anchor = toggleSidebarRect(),
        },
        .previous => .{ .label = "Voltar", .anchor = previousRect(width, height, sidebar_collapsed, maximized) },
        .next => .{ .label = "Avançar", .anchor = nextRect(width, height, sidebar_collapsed, maximized) },
        .up => .{ .label = "Pasta acima", .anchor = upRect(width, height, sidebar_collapsed, maximized) },
        .breadcrumb_up => .{ .label = "Pasta acima", .anchor = breadcrumbTargetRect(width, height, sidebar_collapsed, current_dir, maximized) },
        .minimize => .{ .label = "Minimizar", .anchor = minimizeRect(width) },
        .maximize => .{ .label = if (maximized) "Restaurar" else "Maximizar", .anchor = maximizeRect(width) },
        .close => .{ .label = "Fechar", .anchor = closeRect(width) },
        .sort_modified => .{ .label = "Ordenar por modificação", .anchor = modifiedHeaderRect(width, height, sidebar_collapsed, maximized) },
        else => null,
    };
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
        .new_file => "Novo arquivo",
        .rename => "Renomear item",
        .delete_confirm => "Mover para a lixeira",
        .delete_permanent_confirm => "Excluir permanentemente",
        .none => "",
    };
    const subtitle = switch (kind) {
        .new_folder => "Escolha um nome para a nova pasta.",
        .new_file => "Escolha um nome para o novo arquivo.",
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
        .y = rect.y + (rect.height - 16) / 2.0,
        .width = 16,
        .height = 16,
    }, icon, surface, icon_r, icon_g, icon_b);
    drawLabel(cr, rect.x + 38, rect.y + rect.height / 2.0 + 5.0, if (rect.height < 24.0) 13.5 else 15.0, label, icon_r, icon_g, icon_b);
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

fn drawContextMenu(cr: *c.cairo_t, menu: ContextMenu, hovered: Hit) void {
    const rect = contextMenuRect(menu);

    drawRoundedRect(cr, rect, 10);
    c.cairo_set_source_rgba(cr, 0.165, 0.165, 0.170, 0.99);
    c.cairo_fill_preserve(cr);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.10);
    c.cairo_set_line_width(cr, 1);
    c.cairo_stroke(cr);

    switch (menu.kind) {
        .selection => drawSelectionContextMenu(cr, menu, hovered),
        .empty_space => drawEmptySpaceContextMenu(cr, menu, hovered),
    }
}

fn drawSelectionContextMenu(cr: *c.cairo_t, menu: ContextMenu, hovered: Hit) void {
    var row: usize = 0;
    drawContextMenuItem(cr, contextMenuItemRect(menu, row), "Detalhes", "", if (menu.details_enabled) "✓" else "", hovered == .context_details, true);
    row += 1;
    if (menu.can_pin) {
        drawContextMenuItem(cr, contextMenuItemRect(menu, row), "Fixar na barra lateral", "", "", hovered == .context_pin, true);
        row += 1;
    }
    if (menu.can_unpin) {
        drawContextMenuItem(cr, contextMenuItemRect(menu, row), "Desfixar", "", "", hovered == .context_unpin, true);
    }
}

fn drawEmptySpaceContextMenu(cr: *c.cairo_t, menu: ContextMenu, hovered: Hit) void {
    drawContextMenuItem(cr, contextMenuItemRect(menu, 0), "Nova pasta...", "Ctrl + Shift + N", "", hovered == .context_new_folder, true);
    drawContextMenuItem(cr, contextMenuItemRect(menu, 1), "Novo arquivo...", "", "", hovered == .context_new_file, true);
    drawContextMenuItem(cr, contextMenuItemRect(menu, 2), "Abrir no terminal", "", "", hovered == .context_open_terminal, true);
    drawContextMenuSeparator(cr, contextMenuSeparatorRect(menu, 0));
    drawContextMenuItem(cr, contextMenuItemRect(menu, 3), "Selecionar tudo", "Ctrl + A", "", hovered == .context_select_all, true);
    drawContextMenuItem(cr, contextMenuItemRect(menu, 4), "Colar", "Ctrl + V", "", hovered == .context_paste, true);
    drawContextMenuSeparator(cr, contextMenuSeparatorRect(menu, 1));
    drawContextMenuItem(cr, contextMenuItemRect(menu, 5), "Ordenar por nome", "", if (menu.sort_field == .name) "↓" else "", hovered == .context_sort_name, true);
    drawContextMenuItem(cr, contextMenuItemRect(menu, 6), "Ordenar por data de modificação", "", if (menu.sort_field == .modified) "↓" else "", hovered == .context_sort_modified, true);
    drawContextMenuItem(cr, contextMenuItemRect(menu, 7), "Ordenar por tamanho", "", if (menu.sort_field == .size) "↓" else "", hovered == .context_sort_size, true);
}

fn drawContextMenuItem(cr: *c.cairo_t, rect: Rect, label: []const u8, shortcut: []const u8, marker: []const u8, hovered: bool, enabled: bool) void {
    if (hovered and enabled) {
        drawRoundedRect(cr, .{
            .x = rect.x + 6,
            .y = rect.y + 4,
            .width = rect.width - 12,
            .height = rect.height - 8,
        }, 7);
        c.cairo_set_source_rgba(cr, 1, 1, 1, 0.07);
        c.cairo_fill(cr);
    }
    const label_alpha: f64 = if (enabled) 0.84 else 0.45;
    drawLabel(cr, rect.x + 16, rect.y + 25, 14, label, label_alpha, label_alpha, label_alpha + 0.02);
    if (shortcut.len > 0) {
        drawRightLabel(cr, rect.x + rect.width - 16, rect.y + 25, 13, shortcut, 0.58, 0.58, 0.61);
    }
    if (marker.len > 0) {
        drawLabel(cr, rect.x + rect.width - 33, rect.y + 25, 14, marker, 0.86, 0.86, 0.88);
    }
}

fn drawContextMenuSeparator(cr: *c.cairo_t, rect: Rect) void {
    c.cairo_rectangle(cr, rect.x, rect.y, rect.width, rect.height);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.10);
    c.cairo_fill(cr);
}

fn contextMenuHit(menu: ContextMenu, x: f64, y: f64) Hit {
    switch (menu.kind) {
        .selection => return selectionContextMenuHit(menu, x, y),
        .empty_space => return emptySpaceContextMenuHit(menu, x, y),
    }
}

fn selectionContextMenuHit(menu: ContextMenu, x: f64, y: f64) Hit {
    var row: usize = 0;
    if (contextMenuItemRect(menu, row).contains(x, y)) return .context_details;
    row += 1;
    if (menu.can_pin) {
        if (contextMenuItemRect(menu, row).contains(x, y)) return .context_pin;
        row += 1;
    }
    if (menu.can_unpin and contextMenuItemRect(menu, row).contains(x, y)) return .context_unpin;
    return .none;
}

fn emptySpaceContextMenuHit(menu: ContextMenu, x: f64, y: f64) Hit {
    const hits = [_]Hit{
        .context_new_folder,
        .context_new_file,
        .context_open_terminal,
        .context_select_all,
        .context_paste,
        .context_sort_name,
        .context_sort_modified,
        .context_sort_size,
    };
    for (hits, 0..) |hit, index| {
        if (contextMenuItemRect(menu, index).contains(x, y)) return hit;
    }
    return .none;
}

fn contextMenuRect(menu: ContextMenu) Rect {
    return .{
        .x = menu.x,
        .y = menu.y,
        .width = contextMenuWidth(menu.kind),
        .height = contextMenuHeight(menu),
    };
}

fn contextMenuItemRect(menu: ContextMenu, index: usize) Rect {
    return .{
        .x = menu.x,
        .y = menu.y + context_menu_padding + @as(f64, @floatFromInt(index)) * context_menu_item_height + separatorOffsetForItem(menu.kind, index),
        .width = contextMenuWidth(menu.kind),
        .height = context_menu_item_height,
    };
}

fn contextMenuSeparatorRect(menu: ContextMenu, separator_index: usize) Rect {
    const row_before: usize = if (separator_index == 0) 3 else 5;
    return .{
        .x = menu.x + 10,
        .y = menu.y + context_menu_padding + @as(f64, @floatFromInt(row_before)) * context_menu_item_height + @as(f64, @floatFromInt(separator_index)) * context_menu_separator_height,
        .width = contextMenuWidth(menu.kind) - 20,
        .height = context_menu_separator_height,
    };
}

fn contextMenuWidth(kind: ContextMenuKind) f64 {
    return switch (kind) {
        .selection => selection_context_menu_width,
        .empty_space => empty_context_menu_width,
    };
}

fn contextMenuHeight(menu: ContextMenu) f64 {
    return switch (menu.kind) {
        .selection => blk: {
            const count: usize = 1 + @intFromBool(menu.can_pin) + @intFromBool(menu.can_unpin);
            break :blk context_menu_padding * 2.0 + @as(f64, @floatFromInt(count)) * context_menu_item_height;
        },
        .empty_space => context_menu_padding * 2.0 + 8.0 * context_menu_item_height + 2.0 * context_menu_separator_height,
    };
}

fn separatorOffsetForItem(kind: ContextMenuKind, index: usize) f64 {
    if (kind != .empty_space) return 0;
    var offset: f64 = 0;
    if (index >= 3) offset += context_menu_separator_height;
    if (index >= 5) offset += context_menu_separator_height;
    return offset;
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

fn drawClippedCenteredLabel(cr: *c.cairo_t, rect: Rect, size: f64, text: []const u8, r: f64, g: f64, b: f64) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_rectangle(cr, rect.x, rect.y, rect.width, rect.height);
    c.cairo_clip(cr);
    chrome.drawCenteredLabel(cr, rect, size, text, r, g, b);
}

fn drawAdaptiveWrappedCenteredLabel(cr: *c.cairo_t, rect: Rect, base_size: f64, text: []const u8, r: f64, g: f64, b: f64) void {
    if (text.len == 0) return;

    const line_gap = 2.0;
    var size = base_size;
    while (size >= 11.0) : (size -= 0.75) {
        const line_height = size + 4.0;
        if (line_height * 2.0 + line_gap > rect.height + 0.5) continue;
        if (textWidth(cr, text, size) <= rect.width) {
            drawCenteredTextLine(cr, rect.x, rect.y + (rect.height - line_height) / 2.0, rect.width, line_height, size, text, r, g, b);
            return;
        }

        const split = wrapSplitIndex(cr, text, rect.width, size);
        if (split == 0 or split >= text.len) continue;
        const first = std.mem.trim(u8, text[0..split], " \t");
        const second_raw = std.mem.trim(u8, text[split..], " \t");
        if (first.len == 0 or second_raw.len == 0) continue;

        var second_buf: [128]u8 = undefined;
        const second = ellipsizedToFit(cr, second_raw, size, rect.width, &second_buf);
        const total_height = line_height * 2.0 + line_gap;
        const y = rect.y + (rect.height - total_height) / 2.0;
        drawCenteredTextLine(cr, rect.x, y, rect.width, line_height, size, first, r, g, b);
        drawCenteredTextLine(cr, rect.x, y + line_height + line_gap, rect.width, line_height, size, second, r, g, b);
        return;
    }

    var fallback_buf: [128]u8 = undefined;
    const fallback = ellipsizedToFit(cr, text, 11.0, rect.width, &fallback_buf);
    drawCenteredTextLine(cr, rect.x, rect.y, rect.width, rect.height, 11.0, fallback, r, g, b);
}

fn wrapSplitIndex(cr: *c.cairo_t, text: []const u8, width: f64, size: f64) usize {
    var best_space: usize = 0;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (text[index] == ' ' or text[index] == '-' or text[index] == '_') {
            const candidate = if (text[index] == ' ') index else index + 1;
            if (candidate > 0 and textWidth(cr, std.mem.trim(u8, text[0..candidate], " \t"), size) <= width) {
                best_space = candidate;
            }
        }
    }
    if (best_space > 0) return best_space;
    return fitPrefixIndex(cr, text, size, width, "");
}

fn ellipsizedToFit(cr: *c.cairo_t, text: []const u8, size: f64, width: f64, buffer: []u8) []const u8 {
    if (textWidth(cr, text, size) <= width) return text;
    const suffix = "...";
    const prefix_len = fitPrefixIndex(cr, text, size, width, suffix);
    const copy_len = @min(prefix_len, buffer.len - suffix.len);
    @memcpy(buffer[0..copy_len], text[0..copy_len]);
    @memcpy(buffer[copy_len .. copy_len + suffix.len], suffix);
    return buffer[0 .. copy_len + suffix.len];
}

fn fitPrefixIndex(cr: *c.cairo_t, text: []const u8, size: f64, width: f64, suffix: []const u8) usize {
    if (text.len == 0) return 0;
    var index = text.len;
    while (index > 0) {
        index = previousUtf8Boundary(text, index);
        var probe_buf: [128]u8 = undefined;
        const prefix_len = @min(index, probe_buf.len - suffix.len);
        @memcpy(probe_buf[0..prefix_len], text[0..prefix_len]);
        @memcpy(probe_buf[prefix_len .. prefix_len + suffix.len], suffix);
        const probe = probe_buf[0 .. prefix_len + suffix.len];
        if (textWidth(cr, probe, size) <= width) return prefix_len;
        if (index == 0) break;
    }
    return 0;
}

fn previousUtf8Boundary(text: []const u8, start: usize) usize {
    var index = @min(start -| 1, text.len);
    while (index > 0 and (text[index] & 0b1100_0000) == 0b1000_0000) : (index -= 1) {}
    return index;
}

fn textWidth(cr: *c.cairo_t, text: []const u8, size: f64) f64 {
    var text_buf: [256]u8 = undefined;
    const max_len = @min(text.len, text_buf.len - 1);
    @memcpy(text_buf[0..max_len], text[0..max_len]);
    text_buf[max_len] = 0;
    c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
    c.cairo_set_font_size(cr, size);
    var extents: c.cairo_text_extents_t = undefined;
    c.cairo_text_extents(cr, text_buf[0..max_len :0].ptr, &extents);
    return extents.x_advance;
}

fn drawCenteredTextLine(cr: *c.cairo_t, x: f64, y: f64, width: f64, height: f64, size: f64, text: []const u8, r: f64, g: f64, b: f64) void {
    var text_buf: [256]u8 = undefined;
    const max_len = @min(text.len, text_buf.len - 1);
    @memcpy(text_buf[0..max_len], text[0..max_len]);
    text_buf[max_len] = 0;
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
    c.cairo_set_font_size(cr, size);
    var extents: c.cairo_text_extents_t = undefined;
    var font_extents: c.cairo_font_extents_t = undefined;
    c.cairo_text_extents(cr, text_buf[0..max_len :0].ptr, &extents);
    c.cairo_font_extents(cr, &font_extents);
    c.cairo_set_source_rgb(cr, r, g, b);
    c.cairo_move_to(
        cr,
        x + (width - extents.width) / 2.0 - extents.x_bearing,
        y + (height - font_extents.height) / 2.0 + font_extents.ascent,
    );
    c.cairo_show_text(cr, text_buf[0..max_len :0].ptr);
}

fn drawRightLabel(cr: *c.cairo_t, right_x: f64, y: f64, size: f64, text: []const u8, r: f64, g: f64, b: f64) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    var text_buf: [128]u8 = undefined;
    const max_len = @min(text.len, text_buf.len - 1);
    @memcpy(text_buf[0..max_len], text[0..max_len]);
    text_buf[max_len] = 0;
    c.cairo_select_font_face(cr, "Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
    c.cairo_set_font_size(cr, size);
    var extents: c.cairo_text_extents_t = undefined;
    c.cairo_text_extents(cr, text_buf[0..max_len :0].ptr, &extents);
    c.cairo_set_source_rgb(cr, r, g, b);
    c.cairo_move_to(cr, right_x - extents.x_advance, y);
    c.cairo_show_text(cr, text_buf[0..max_len :0].ptr);
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
