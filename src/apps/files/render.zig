const std = @import("std");
const c = @import("client_wl").c;
const browser = @import("browser.zig");

pub const Rect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,

    pub fn contains(self: Rect, px: f64, py: f64) bool {
        return px >= self.x and px <= self.x + self.width and py >= self.y and py <= self.y + self.height;
    }
};

pub const sidebar_width: f64 = 196;
pub const titlebar_height: f64 = 42;
const header_height: f64 = 72;
const footer_height: f64 = 54;
const row_height: f64 = 34;

pub const Hit = union(enum) {
    none,
    titlebar,
    minimize,
    maximize,
    close,
    up,
    previous,
    next,
    sidebar: browser.SidebarTarget,
    entry: usize,
};

pub fn sidebarRect() Rect {
    return .{ .x = 0, .y = 0, .width = sidebar_width, .height = 560 };
}

pub fn contentRect(width: u32, height: u32) Rect {
    return .{
        .x = sidebar_width,
        .y = titlebar_height,
        .width = @as(f64, @floatFromInt(width)) - sidebar_width,
        .height = @as(f64, @floatFromInt(height)) - titlebar_height,
    };
}

pub fn hitTest(width: u32, _: u32, x: f64, y: f64, snapshot: browser.Snapshot) Hit {
    if (closeRect(width).contains(x, y)) return .close;
    if (maximizeRect(width).contains(x, y)) return .maximize;
    if (minimizeRect(width).contains(x, y)) return .minimize;
    if (titlebarRect(width).contains(x, y)) return .titlebar;

    if (upRect(width).contains(x, y)) return .up;
    if (previousRect(width).contains(x, y)) return .previous;
    if (nextRect(width).contains(x, y)) return .next;

    for (browser.sidebar_items) |item| {
        if (sidebarItemRect(item.target).contains(x, y)) return .{ .sidebar = item.target };
    }

    for (0..snapshot.count) |index| {
        if (entryRect(width, index).contains(x, y)) return .{ .entry = index };
    }

    return .none;
}

pub fn draw(
    cr: *c.cairo_t,
    width: u32,
    height: u32,
    snapshot: browser.Snapshot,
    hovered: Hit,
) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);

    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
    c.cairo_set_source_rgba(cr, 0.08, 0.085, 0.10, 1.0);
    c.cairo_paint(cr);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);

    drawTitlebar(cr, width, hovered);

    const content = contentRect(width, height);

    c.cairo_rectangle(cr, 0, titlebar_height, sidebar_width, @as(f64, @floatFromInt(height)) - titlebar_height);
    c.cairo_set_source_rgba(cr, 0.11, 0.115, 0.135, 1.0);
    c.cairo_fill(cr);

    c.cairo_rectangle(cr, sidebar_width - 1, titlebar_height, 1, @as(f64, @floatFromInt(height)) - titlebar_height);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.08);
    c.cairo_fill(cr);

    drawLabel(cr, 22, titlebar_height + 34, 24, "Arquivos", 0.97, 0.98, 0.99);

    for (browser.sidebar_items) |item| {
        const rect = sidebarItemRect(item.target);
        const active = snapshot.current_dir.len > 0 and matchesSidebar(snapshot.current_dir, item.target);
        const is_hovered = switch (hovered) {
            .sidebar => |target| target == item.target,
            else => false,
        };
        drawSidebarItem(cr, rect, item.label, active, is_hovered);
    }

    drawLabel(cr, content.x + 20, titlebar_height + 34, 18, "Axia Files", 0.96, 0.97, 0.99);
    drawLabel(cr, content.x + 20, titlebar_height + 58, 14, snapshot.current_dir, 0.72, 0.74, 0.78);

    drawToolbarButton(cr, upRect(width), "Up", hovered == .up);
    drawToolbarButton(cr, previousRect(width), "<", hovered == .previous);
    drawToolbarButton(cr, nextRect(width), ">", hovered == .next);

    c.cairo_rectangle(cr, content.x, header_height, content.width, 1);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.08);
    c.cairo_fill(cr);

    for (0..snapshot.count) |index| {
        const rect = entryRect(width, index);
        const entry = snapshot.entries[index];
        const hovered_entry = switch (hovered) {
            .entry => |visible| visible == index,
            else => false,
        };
        drawEntryRow(cr, rect, entry.kind, entry.text(), hovered_entry);
    }

    c.cairo_rectangle(cr, content.x, @as(f64, @floatFromInt(height)) - footer_height, content.width, 1);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.08);
    c.cairo_fill(cr);

    var footer_buf: [160]u8 = undefined;
    const footer = if (snapshot.selected_path.len > 0)
        std.fmt.bufPrint(&footer_buf, "Selecionado: {s}", .{snapshot.selected_path}) catch "Selecionado"
    else if (snapshot.total_count == 0)
        "Diretório vazio"
    else
        std.fmt.bufPrint(&footer_buf, "{d} itens", .{snapshot.total_count}) catch "Itens";
    drawLabel(cr, content.x + 20, @as(f64, @floatFromInt(height)) - 20, 14, footer, 0.74, 0.76, 0.80);
}

fn upRect(width: u32) Rect {
    return .{ .x = @as(f64, @floatFromInt(width)) - 146, .y = titlebar_height + 18, .width = 44, .height = 32 };
}

fn previousRect(width: u32) Rect {
    return .{ .x = @as(f64, @floatFromInt(width)) - 94, .y = titlebar_height + 18, .width = 32, .height = 32 };
}

fn nextRect(width: u32) Rect {
    return .{ .x = @as(f64, @floatFromInt(width)) - 54, .y = titlebar_height + 18, .width = 32, .height = 32 };
}

fn sidebarItemRect(target: browser.SidebarTarget) Rect {
    return .{
        .x = 14,
        .y = titlebar_height + 46 + @as(f64, @floatFromInt(@intFromEnum(target))) * 44,
        .width = sidebar_width - 28,
        .height = 34,
    };
}

fn entryRect(width: u32, index: usize) Rect {
    const content = contentRect(width, 560);
    return .{
        .x = content.x + 14,
        .y = titlebar_height + header_height + 10 + @as(f64, @floatFromInt(index)) * row_height,
        .width = content.width - 28,
        .height = 28,
    };
}

fn titlebarRect(width: u32) Rect {
    return .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(width),
        .height = titlebar_height,
    };
}

fn minimizeRect(width: u32) Rect {
    const right = @as(f64, @floatFromInt(width)) - 18;
    return .{ .x = right - 72, .y = 9, .width = 18, .height = 18 };
}

fn maximizeRect(width: u32) Rect {
    const right = @as(f64, @floatFromInt(width)) - 18;
    return .{ .x = right - 44, .y = 9, .width = 18, .height = 18 };
}

fn closeRect(width: u32) Rect {
    const right = @as(f64, @floatFromInt(width)) - 18;
    return .{ .x = right - 16, .y = 9, .width = 18, .height = 18 };
}

fn drawTitlebar(cr: *c.cairo_t, width: u32, hovered: Hit) void {
    c.cairo_rectangle(cr, 0, 0, @floatFromInt(width), titlebar_height);
    c.cairo_set_source_rgba(cr, 0.105, 0.112, 0.132, 1.0);
    c.cairo_fill(cr);

    c.cairo_rectangle(cr, 0, titlebar_height - 1, @floatFromInt(width), 1);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.08);
    c.cairo_fill(cr);

    drawLabel(cr, 16, 26, 15, "Axia Files", 0.97, 0.98, 0.99);

    drawWindowButton(cr, minimizeRect(width), "-", hovered == .minimize);
    drawWindowButton(cr, maximizeRect(width), "+", hovered == .maximize);
    drawWindowButton(cr, closeRect(width), "x", hovered == .close);
}

fn drawWindowButton(cr: *c.cairo_t, rect: Rect, label: []const u8, hovered: bool) void {
    if (hovered) {
        drawRoundedRect(cr, rect, 6);
        c.cairo_set_source_rgba(cr, 1, 1, 1, 0.08);
        c.cairo_fill(cr);
    }
    drawCenteredLabel(cr, rect, 14, label, 0.95, 0.96, 0.98);
}

fn drawSidebarItem(cr: *c.cairo_t, rect: Rect, label: []const u8, active: bool, hovered: bool) void {
    if (active or hovered) {
        drawRoundedRect(cr, rect, 10);
        c.cairo_set_source_rgba(cr, 1, 1, 1, if (active) 0.09 else 0.05);
        c.cairo_fill(cr);
    }
    drawLabel(cr, rect.x + 12, rect.y + 22, 15, label, if (active) 0.97 else 0.88, if (active) 0.98 else 0.89, if (active) 1.0 else 0.91);
}

fn drawToolbarButton(cr: *c.cairo_t, rect: Rect, label: []const u8, hovered: bool) void {
    drawRoundedRect(cr, rect, 9);
    c.cairo_set_source_rgba(cr, 1, 1, 1, if (hovered) 0.08 else 0.04);
    c.cairo_fill(cr);
    drawCenteredLabel(cr, rect, 15, label, 0.96, 0.97, 0.99);
}

fn drawEntryRow(cr: *c.cairo_t, rect: Rect, kind: browser.EntryKind, label: []const u8, hovered: bool) void {
    if (hovered) {
        drawRoundedRect(cr, rect, 9);
        c.cairo_set_source_rgba(cr, 1, 1, 1, 0.05);
        c.cairo_fill(cr);
    }

    const icon_rect = Rect{ .x = rect.x + 8, .y = rect.y + 4, .width = 20, .height = 20 };
    drawRoundedRect(cr, icon_rect, 5);
    switch (kind) {
        .directory => c.cairo_set_source_rgba(cr, 0.42, 0.72, 0.96, 0.34),
        .file => c.cairo_set_source_rgba(cr, 0.74, 0.76, 0.82, 0.16),
    }
    c.cairo_fill(cr);

    drawLabel(cr, rect.x + 38, rect.y + 19, 15, label, 0.93, 0.94, 0.96);
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

fn matchesSidebar(current_dir: []const u8, target: browser.SidebarTarget) bool {
    const home = std.process.getEnvVarOwned(std.heap.page_allocator, "HOME") catch return false;
    defer std.heap.page_allocator.free(home);
    return switch (target) {
        .home => std.mem.eql(u8, current_dir, home),
        else => blk: {
            const item = browser.sidebar_items[@intFromEnum(target)];
            const joined = std.fs.path.join(std.heap.page_allocator, &.{ home, item.subdir.? }) catch break :blk false;
            defer std.heap.page_allocator.free(joined);
            break :blk std.mem.eql(u8, current_dir, joined);
        },
    };
}
