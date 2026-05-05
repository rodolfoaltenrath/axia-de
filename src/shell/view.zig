const std = @import("std");
const c = @import("../wl.zig").c;
const chrome = @import("../render/window_chrome.zig");
const CairoBuffer = @import("../render/cairo_buffer.zig").CairoBuffer;

const log = std.log.scoped(.axia_view);

const frame_margin_px: i32 = 4;
const titlebar_height_px: i32 = 46;
const content_inset_px: i32 = 3;
const attached_bottom_shadow_px: i32 = @intFromFloat(chrome.attached_bottom_shadow);
const chrome_left_reserved: f64 = 24.0;
const chrome_right_reserved: f64 = 120.0;

const ChromeMode = enum {
    none,
    floating,
    attached,
};

const ChromeMetrics = struct {
    left: i32,
    right: i32,
    top: i32,
    bottom: i32,
    content_inset: i32,
};

const LayoutMode = enum {
    floating,
    tiled,
    maximized,
    fullscreen,
};

pub const DestroyCallback = *const fn (?*anyopaque, *View) void;
pub const RequestMoveCallback = *const fn (?*anyopaque, *View, u32) void;
pub const RequestResizeCallback = *const fn (?*anyopaque, *View, u32, u32) void;

pub const View = struct {
    allocator: std.mem.Allocator,
    seat: [*c]c.struct_wlr_seat,
    output_layout: [*c]c.struct_wlr_output_layout,
    primary_output: [*c]c.struct_wlr_output,
    usable_area: c.struct_wlr_box,
    shadow_parent: [*c]c.struct_wlr_scene_tree,
    parent: [*c]c.struct_wlr_scene_tree,
    xdg_surface: [*c]c.struct_wlr_xdg_surface,
    toplevel: [*c]c.struct_wlr_xdg_toplevel,
    scene_tree: ?[*c]c.struct_wlr_scene_tree = null,
    content_tree: ?[*c]c.struct_wlr_scene_tree = null,
    frame_buffer: ?*CairoBuffer = null,
    frame_scene_buffer: ?[*c]c.struct_wlr_scene_buffer = null,
    attached_shadow_buffer: ?*CairoBuffer = null,
    attached_shadow_scene_buffer: ?[*c]c.struct_wlr_scene_buffer = null,
    workspace_index: usize = 0,
    workspace_visible: bool = true,
    mapped: bool = false,
    minimized: bool = false,
    x: i32,
    y: i32,
    restore_x: i32,
    restore_y: i32,
    restore_width: i32 = 960,
    restore_height: i32 = 540,
    layout_mode: LayoutMode = .floating,
    destroy_ctx: ?*anyopaque,
    destroy_cb: DestroyCallback,
    request_ctx: ?*anyopaque,
    request_move_cb: RequestMoveCallback,
    request_resize_cb: RequestResizeCallback,
    initial_configure_sent: bool = false,
    commit: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    map: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    unmap: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    destroy: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    request_maximize: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    request_fullscreen: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    request_minimize: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    request_move: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    request_resize: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    chrome_hovered: chrome.HoveredControl = .none,

    pub fn create(
        allocator: std.mem.Allocator,
        seat: [*c]c.struct_wlr_seat,
        output_layout: [*c]c.struct_wlr_output_layout,
        primary_output: [*c]c.struct_wlr_output,
        usable_area: c.struct_wlr_box,
        shadow_parent: [*c]c.struct_wlr_scene_tree,
        parent: [*c]c.struct_wlr_scene_tree,
        toplevel: [*c]c.struct_wlr_xdg_toplevel,
        xdg_surface: [*c]c.struct_wlr_xdg_surface,
        destroy_ctx: ?*anyopaque,
        destroy_cb: DestroyCallback,
        request_ctx: ?*anyopaque,
        request_move_cb: RequestMoveCallback,
        request_resize_cb: RequestResizeCallback,
        workspace_index: usize,
        x: i32,
        y: i32,
    ) !*View {
        const view = try allocator.create(View);
        view.* = .{
            .allocator = allocator,
            .seat = seat,
            .output_layout = output_layout,
            .primary_output = primary_output,
            .usable_area = usable_area,
            .shadow_parent = shadow_parent,
            .parent = parent,
            .xdg_surface = xdg_surface,
            .toplevel = toplevel,
            .workspace_index = workspace_index,
            .x = x,
            .y = y,
            .restore_x = x,
            .restore_y = y,
            .destroy_ctx = destroy_ctx,
            .destroy_cb = destroy_cb,
            .request_ctx = request_ctx,
            .request_move_cb = request_move_cb,
            .request_resize_cb = request_resize_cb,
        };

        view.commit.notify = handleCommit;
        view.map.notify = handleMap;
        view.unmap.notify = handleUnmap;
        view.destroy.notify = handleDestroy;
        view.request_maximize.notify = handleRequestMaximize;
        view.request_fullscreen.notify = handleRequestFullscreen;
        view.request_minimize.notify = handleRequestMinimize;
        view.request_move.notify = handleRequestMove;
        view.request_resize.notify = handleRequestResize;

        c.wl_signal_add(&xdg_surface.*.surface.*.events.commit, &view.commit);
        c.wl_signal_add(&xdg_surface.*.surface.*.events.map, &view.map);
        c.wl_signal_add(&xdg_surface.*.surface.*.events.unmap, &view.unmap);
        c.wl_signal_add(&xdg_surface.*.events.destroy, &view.destroy);
        c.wl_signal_add(&toplevel.*.events.request_maximize, &view.request_maximize);
        c.wl_signal_add(&toplevel.*.events.request_fullscreen, &view.request_fullscreen);
        c.wl_signal_add(&toplevel.*.events.request_minimize, &view.request_minimize);
        c.wl_signal_add(&toplevel.*.events.request_move, &view.request_move);
        c.wl_signal_add(&toplevel.*.events.request_resize, &view.request_resize);

        return view;
    }

    pub fn detach(self: *View) void {
        c.wl_list_remove(&self.request_resize.link);
        c.wl_list_remove(&self.request_move.link);
        c.wl_list_remove(&self.request_minimize.link);
        c.wl_list_remove(&self.request_fullscreen.link);
        c.wl_list_remove(&self.request_maximize.link);
        c.wl_list_remove(&self.destroy.link);
        c.wl_list_remove(&self.unmap.link);
        c.wl_list_remove(&self.map.link);
        c.wl_list_remove(&self.commit.link);
    }

    pub fn destroyScene(self: *View) void {
        if (self.scene_tree) |scene_tree| {
            c.wlr_scene_node_destroy(&scene_tree.*.node);
            self.scene_tree = null;
            self.content_tree = null;
            self.frame_scene_buffer = null;
        }
        if (self.attached_shadow_scene_buffer) |scene_buffer| {
            c.wlr_scene_node_destroy(&scene_buffer.*.node);
            self.attached_shadow_scene_buffer = null;
        }
        if (self.frame_buffer) |buffer| {
            buffer.deinit();
            self.frame_buffer = null;
        }
        if (self.attached_shadow_buffer) |buffer| {
            buffer.deinit();
            self.attached_shadow_buffer = null;
        }
    }

    pub fn focus(self: *View) void {
        if (!self.workspace_visible or self.minimized) return;

        tryCreateSceneTree(self) catch |err| {
            log.err("failed to create scene tree for mapped view: {}", .{err});
            return;
        };

        _ = c.wlr_xdg_toplevel_set_activated(self.toplevel, true);
        c.wlr_scene_node_raise_to_top(&self.scene_tree.?.*.node);
        self.redrawCompositorChrome() catch {};

        const keyboard = c.wlr_seat_get_keyboard(self.seat);
        if (keyboard != null) {
            const keycodes: [*c]const u32 = if (keyboard.*.num_keycodes > 0)
                @ptrCast(&keyboard.*.keycodes[0])
            else
                null;
            c.wlr_seat_keyboard_notify_enter(
                self.seat,
                self.xdg_surface.*.surface,
                keycodes,
                keyboard.*.num_keycodes,
                &keyboard.*.modifiers,
            );
        }

        log.info("mapped view: {s}", .{titleOrFallback(self.toplevel)});
    }

    pub fn unfocus(self: *View) void {
        _ = c.wlr_xdg_toplevel_set_activated(self.toplevel, false);
        c.wlr_seat_keyboard_notify_clear_focus(self.seat);
        self.redrawCompositorChrome() catch {};
    }

    pub fn setPosition(self: *View, x: i32, y: i32) void {
        const clamped = self.clampPosition(x, y);
        self.x = clamped.x;
        self.y = clamped.y;
        if (self.scene_tree) |scene_tree| {
            c.wlr_scene_node_set_position(&scene_tree.*.node, self.x, self.y);
        }
        if (self.attached_shadow_scene_buffer) |scene_buffer| {
            c.wlr_scene_node_set_position(&scene_buffer.*.node, self.x, self.y);
        }
    }

    pub fn setSize(self: *View, width: i32, height: i32) void {
        const clamped_width = @max(width, self.minWidth());
        const clamped_height = @max(height, self.minHeight());

        if (self.layout_mode == .floating) {
            self.restore_width = clamped_width;
            self.restore_height = clamped_height;
        }

        _ = c.wlr_xdg_toplevel_set_bounds(self.toplevel, clamped_width, clamped_height);
        _ = c.wlr_xdg_toplevel_set_size(self.toplevel, clamped_width, clamped_height);
        self.updateSceneLayout() catch {};
    }

    pub fn setOuterSize(self: *View, width: i32, height: i32) void {
        const mode = self.currentChromeModeForSizing();
        const metrics = self.chromeMetrics(mode);
        self.setSize(
            @max(width - metrics.left - metrics.right, self.minWidth()),
            @max(height - metrics.top - metrics.bottom, self.minHeight()),
        );
    }

    pub fn effectiveWidth(self: *const View) i32 {
        if (self.toplevel.*.current.width > 0) {
            return self.toplevel.*.current.width;
        }
        return self.restore_width;
    }

    pub fn effectiveHeight(self: *const View) i32 {
        if (self.toplevel.*.current.height > 0) {
            return self.toplevel.*.current.height;
        }
        return self.restore_height;
    }

    pub fn minWidth(self: *const View) i32 {
        if (self.toplevel.*.current.min_width > 0) {
            return self.toplevel.*.current.min_width;
        }
        return 160;
    }

    pub fn minHeight(self: *const View) i32 {
        if (self.toplevel.*.current.min_height > 0) {
            return self.toplevel.*.current.min_height;
        }
        return 90;
    }

    pub fn minOuterWidth(self: *const View) i32 {
        const metrics = self.chromeMetrics(self.currentChromeModeForSizing());
        return self.minWidth() + metrics.left + metrics.right;
    }

    pub fn minOuterHeight(self: *const View) i32 {
        const metrics = self.chromeMetrics(self.currentChromeModeForSizing());
        return self.minHeight() + metrics.top + metrics.bottom;
    }

    pub fn canStartInteractive(self: *const View) bool {
        return self.workspace_visible and
            !self.minimized and
            !self.toplevel.*.current.fullscreen and
            !self.toplevel.*.requested.fullscreen and
            !self.toplevel.*.requested.minimized;
    }

    pub fn canStartInteractiveResize(self: *const View) bool {
        return self.canStartInteractive() and
            self.layout_mode == .floating and
            !self.toplevel.*.current.maximized and
            !self.toplevel.*.requested.maximized;
    }

    pub fn workspaceIndex(self: *const View) usize {
        return self.workspace_index;
    }

    pub fn mappedVisible(self: *const View) bool {
        return self.mapped and !self.minimized;
    }

    pub fn mappedState(self: *const View) bool {
        return self.mapped;
    }

    pub fn isMinimized(self: *const View) bool {
        return self.minimized;
    }

    pub fn title(self: *const View) []const u8 {
        return titleOrFallback(self.toplevel);
    }

    pub fn appId(self: *const View) []const u8 {
        const raw_app_id = self.toplevel.*.app_id;
        if (raw_app_id != null) return std.mem.span(raw_app_id);
        return "";
    }

    pub fn usesCompositorChrome(self: *const View) bool {
        const app_id = self.appId();
        return app_id.len == 0 or !std.mem.startsWith(u8, app_id, "axia-");
    }

    pub fn compositorChromeVisible(self: *const View) bool {
        return self.usesCompositorChrome() and !self.toplevel.*.current.fullscreen and !self.toplevel.*.requested.fullscreen;
    }

    pub fn outerWidth(self: *const View) i32 {
        const metrics = self.chromeMetrics(self.currentChromeMode());
        return self.effectiveWidth() + metrics.left + metrics.right;
    }

    pub fn outerHeight(self: *const View) i32 {
        const metrics = self.chromeMetrics(self.currentChromeMode());
        return self.effectiveHeight() + metrics.top + metrics.bottom;
    }

    pub fn outerBox(self: *const View) c.struct_wlr_box {
        return .{
            .x = self.x,
            .y = self.y,
            .width = self.outerWidth(),
            .height = self.outerHeight(),
        };
    }

    pub fn captureBox(self: *const View) ?c.struct_wlr_box {
        const outer = self.outerBox();
        const output = self.outputArea();

        const left = @max(outer.x, output.x);
        const top = @max(outer.y, output.y);
        const right = @min(outer.x + outer.width, output.x + output.width);
        const bottom = @min(outer.y + outer.height, output.y + output.height);

        if (right <= left or bottom <= top) return null;

        return .{
            .x = left,
            .y = top,
            .width = right - left,
            .height = bottom - top,
        };
    }

    pub fn localCoords(self: *const View, lx: f64, ly: f64) struct { x: f64, y: f64 } {
        return .{
            .x = lx - @as(f64, @floatFromInt(self.x)),
            .y = ly - @as(f64, @floatFromInt(self.y)),
        };
    }

    pub fn chromeControlAt(self: *const View, local_x: f64, local_y: f64) chrome.HoveredControl {
        if (!self.compositorChromeVisible()) return .none;

        const width: u32 = @intCast(@max(self.outerWidth(), 1));
        if (chrome.closeRect(width).contains(local_x, local_y)) return .close;
        if (chrome.maximizeRect(width).contains(local_x, local_y)) return .maximize;
        if (chrome.minimizeRect(width).contains(local_x, local_y)) return .minimize;
        return .none;
    }

    pub fn isInChromeTitlebar(self: *const View, local_x: f64, local_y: f64) bool {
        if (!self.compositorChromeVisible()) return false;
        const width: u32 = @intCast(@max(self.outerWidth(), 1));
        const height: u32 = @intCast(@max(self.outerHeight(), 1));
        return chrome.titlebarDragRect(width, height, chrome_left_reserved, chrome_right_reserved).contains(local_x, local_y);
    }

    pub fn chromeResizeEdges(self: *const View, local_x: f64, local_y: f64) u32 {
        if (!self.compositorChromeVisible()) return 0;

        const width = @as(f64, @floatFromInt(@max(self.outerWidth(), 1)));
        const height = @as(f64, @floatFromInt(@max(self.outerHeight(), 1)));
        const edge = 8.0;
        var edges: u32 = 0;

        if (local_x <= edge) edges |= c.WLR_EDGE_LEFT;
        if (local_x >= width - edge) edges |= c.WLR_EDGE_RIGHT;
        if (local_y <= edge) edges |= c.WLR_EDGE_TOP;
        if (local_y >= height - edge) edges |= c.WLR_EDGE_BOTTOM;
        return edges;
    }

    pub fn setChromeHovered(self: *View, hovered: chrome.HoveredControl) void {
        if (self.chrome_hovered == hovered) return;
        self.chrome_hovered = hovered;
        self.redrawCompositorChrome() catch {};
    }

    pub fn requestMinimize(self: *View) void {
        self.minimized = true;
        self.syncVisibility();
        _ = c.wlr_xdg_toplevel_set_activated(self.toplevel, false);
        _ = c.wlr_xdg_surface_schedule_configure(self.xdg_surface);
    }

    pub fn toggleMaximized(self: *View) void {
        if (self.toplevel.*.current.maximized or self.toplevel.*.requested.maximized) {
            self.restoreFloatingGeometry();
            return;
        }

        self.maximize();
    }

    pub fn maximize(self: *View) void {
        if (self.toplevel.*.current.maximized or self.toplevel.*.requested.maximized) return;

        self.restoreCurrentGeometry();
        const outer_area = self.attachedOuterArea();
        self.maximizeToOuterArea(outer_area);
    }

    pub fn maximizeToUsableArea(self: *View, usable_area: c.struct_wlr_box) void {
        if (self.toplevel.*.current.maximized or self.toplevel.*.requested.maximized) return;

        self.restoreCurrentGeometry();
        self.maximizeToUsableAreaPreservingRestore(usable_area);
    }

    pub fn maximizeToUsableAreaPreservingRestore(self: *View, usable_area: c.struct_wlr_box) void {
        if (self.toplevel.*.current.maximized or self.toplevel.*.requested.maximized) return;

        const outer_area = self.attachedOuterAreaFor(usable_area);
        self.maximizeToOuterArea(outer_area);
    }

    fn maximizeToOuterArea(self: *View, outer_area: c.struct_wlr_box) void {
        const client_box = self.clientBoxForOuterWithMode(outer_area, .attached);
        self.layout_mode = .maximized;
        self.setPosition(outer_area.x, outer_area.y);
        _ = c.wlr_xdg_toplevel_set_tiled(
            self.toplevel,
            c.WLR_EDGE_TOP | c.WLR_EDGE_BOTTOM | c.WLR_EDGE_LEFT | c.WLR_EDGE_RIGHT,
        );
        _ = c.wlr_xdg_toplevel_set_bounds(self.toplevel, client_box.width, client_box.height);
        _ = c.wlr_xdg_toplevel_set_size(self.toplevel, client_box.width, client_box.height);
        _ = c.wlr_xdg_toplevel_set_maximized(self.toplevel, true);
    }

    pub fn rememberRestoreGeometry(self: *View, x: i32, y: i32, width: i32, height: i32) void {
        self.restore_x = x;
        self.restore_y = y;
        self.restore_width = @max(width, self.minWidth());
        self.restore_height = @max(height, self.minHeight());
    }

    pub fn restoreFloatingGeometry(self: *View) void {
        self.layout_mode = .floating;
        self.setPosition(self.restore_x, self.restore_y);
        _ = c.wlr_xdg_toplevel_set_tiled(self.toplevel, 0);
        _ = c.wlr_xdg_toplevel_set_bounds(self.toplevel, 0, 0);
        _ = c.wlr_xdg_toplevel_set_size(self.toplevel, self.restore_width, self.restore_height);
        _ = c.wlr_xdg_toplevel_set_maximized(self.toplevel, false);
        _ = c.wlr_xdg_toplevel_set_fullscreen(self.toplevel, false);
        self.updateSceneLayout() catch {};
    }

    pub fn prepareForInteractiveMove(self: *View, cursor_lx: f64, cursor_ly: f64) void {
        if (self.layout_mode == .floating and
            !self.toplevel.*.current.maximized and
            !self.toplevel.*.requested.maximized)
        {
            return;
        }
        if (self.toplevel.*.current.fullscreen or self.toplevel.*.requested.fullscreen) return;

        const current_outer_width = @max(self.outerWidth(), 1);
        const restore_outer_width = self.restoreOuterWidth();
        const restore_outer_height = self.restoreOuterHeight();
        const raw_ratio = (cursor_lx - @as(f64, @floatFromInt(self.x))) / @as(f64, @floatFromInt(current_outer_width));
        const ratio = std.math.clamp(raw_ratio, 0.18, 0.82);
        const next_x = @as(i32, @intFromFloat(@round(cursor_lx - ratio * @as(f64, @floatFromInt(restore_outer_width)))));
        const restore_grab_y = @min(@divTrunc(titlebar_height_px, 2), @divTrunc(restore_outer_height, 2));
        const next_y = @as(i32, @intFromFloat(@round(cursor_ly - @as(f64, @floatFromInt(restore_grab_y)))));

        self.layout_mode = .floating;
        self.setPosition(next_x, next_y);
        _ = c.wlr_xdg_toplevel_set_tiled(self.toplevel, 0);
        _ = c.wlr_xdg_toplevel_set_bounds(self.toplevel, 0, 0);
        _ = c.wlr_xdg_toplevel_set_size(self.toplevel, self.restore_width, self.restore_height);
        _ = c.wlr_xdg_toplevel_set_maximized(self.toplevel, false);
        self.updateSceneLayout() catch {};
    }

    pub fn finishInteractiveMove(self: *View) void {
        if (self.layout_mode != .floating) return;
        self.rememberRestoreGeometry(self.x, self.y, self.effectiveWidth(), self.effectiveHeight());
    }

    pub fn setWorkspaceIndex(self: *View, workspace_index: usize) void {
        self.workspace_index = workspace_index;
        self.syncVisibility();
    }

    pub fn setWorkspaceVisible(self: *View, visible: bool) void {
        self.workspace_visible = visible;
        self.syncVisibility();
    }

    pub fn setUsableArea(self: *View, usable_area: c.struct_wlr_box) void {
        self.usable_area = usable_area;
        if (!self.xdg_surface.*.initialized) return;

        if (self.toplevel.*.current.fullscreen) {
            const output_area = self.outputArea();
            const client_box = self.clientBoxForOuterWithMode(output_area, .none);
            self.layout_mode = .fullscreen;
            self.setPosition(output_area.x, output_area.y);
            _ = c.wlr_xdg_toplevel_set_bounds(self.toplevel, client_box.width, client_box.height);
            _ = c.wlr_xdg_toplevel_set_size(self.toplevel, client_box.width, client_box.height);
            return;
        }

        if (self.toplevel.*.current.maximized) {
            const outer_area = self.attachedOuterAreaFor(usable_area);
            const client_box = self.clientBoxForOuterWithMode(outer_area, .attached);
            self.layout_mode = .maximized;
            self.setPosition(outer_area.x, outer_area.y);
            _ = c.wlr_xdg_toplevel_set_bounds(self.toplevel, client_box.width, client_box.height);
            _ = c.wlr_xdg_toplevel_set_size(self.toplevel, client_box.width, client_box.height);
            return;
        }

        self.setPosition(self.x, self.y);
    }

    pub fn centerInUsableArea(self: *View) void {
        const width = self.outerWidth();
        const height = self.outerHeight();
        const centered_x = self.usable_area.x + @divTrunc(self.usable_area.width - width, 2);
        const centered_y = self.usable_area.y + @divTrunc(self.usable_area.height - height, 2);
        self.restore_x = centered_x;
        self.restore_y = centered_y;
        self.setPosition(centered_x, centered_y);
    }

    pub fn isLauncher(self: *const View) bool {
        if (self.toplevel.*.app_id != null and std.mem.eql(u8, std.mem.span(self.toplevel.*.app_id), "axia-launcher")) {
            return true;
        }
        if (self.toplevel.*.title != null and std.mem.eql(u8, std.mem.span(self.toplevel.*.title), "Axia Launcher")) {
            return true;
        }
        return false;
    }

    pub fn isAppGrid(self: *const View) bool {
        if (self.toplevel.*.app_id != null and std.mem.eql(u8, std.mem.span(self.toplevel.*.app_id), "axia-app-grid")) {
            return true;
        }
        if (self.toplevel.*.title != null and std.mem.eql(u8, std.mem.span(self.toplevel.*.title), "Todos os aplicativos")) {
            return true;
        }
        return false;
    }

    pub fn restoreFromMinimized(self: *View) void {
        if (!self.minimized) return;
        self.minimized = false;
        self.syncVisibility();
        _ = c.wlr_xdg_surface_schedule_configure(self.xdg_surface);
    }

    pub fn applyTiledRect(self: *View, rect: c.struct_wlr_box, edges: u32) void {
        self.minimized = false;
        self.layout_mode = .tiled;
        self.syncVisibility();
        _ = c.wlr_xdg_toplevel_set_fullscreen(self.toplevel, false);
        _ = c.wlr_xdg_toplevel_set_maximized(self.toplevel, false);
        _ = c.wlr_xdg_toplevel_set_tiled(self.toplevel, edges);
        const client_box = self.clientBoxForOuterWithMode(rect, .floating);
        _ = c.wlr_xdg_toplevel_set_bounds(self.toplevel, client_box.width, client_box.height);
        self.setPosition(rect.x, rect.y);
        _ = c.wlr_xdg_toplevel_set_size(self.toplevel, client_box.width, client_box.height);
    }

    fn titleOrFallback(toplevel: [*c]c.struct_wlr_xdg_toplevel) []const u8 {
        const raw_title = toplevel.*.title;
        if (raw_title != null) return std.mem.span(raw_title);
        return "untitled";
    }

    fn handleMap(listener: [*c]c.struct_wl_listener, _: ?*anyopaque) callconv(.c) void {
        const view: *View = @ptrCast(@as(*allowzero View, @fieldParentPtr("map", listener)));
        view.mapped = true;
        if (view.isLauncher() or view.isAppGrid()) {
            view.centerInUsableArea();
        }
        view.syncVisibility();
        view.focus();
        view.redrawCompositorChrome() catch {};
    }

    fn handleCommit(listener: [*c]c.struct_wl_listener, _: ?*anyopaque) callconv(.c) void {
        const view: *View = @ptrCast(@as(*allowzero View, @fieldParentPtr("commit", listener)));
        if (!view.xdg_surface.*.initialized) return;

        if (!view.initial_configure_sent) {
            _ = c.wlr_xdg_toplevel_set_wm_capabilities(
                view.toplevel,
                c.WLR_XDG_TOPLEVEL_WM_CAPABILITIES_MAXIMIZE |
                    c.WLR_XDG_TOPLEVEL_WM_CAPABILITIES_FULLSCREEN |
                    c.WLR_XDG_TOPLEVEL_WM_CAPABILITIES_MINIMIZE,
            );
            _ = c.wlr_xdg_toplevel_set_size(view.toplevel, view.restore_width, view.restore_height);
            _ = c.wlr_xdg_surface_schedule_configure(view.xdg_surface);
            view.initial_configure_sent = true;
        }

        view.updateSceneLayout() catch {};
        view.redrawCompositorChrome() catch {};
    }

    fn handleUnmap(listener: [*c]c.struct_wl_listener, _: ?*anyopaque) callconv(.c) void {
        const view: *View = @ptrCast(@as(*allowzero View, @fieldParentPtr("unmap", listener)));
        view.mapped = false;
        view.syncVisibility();
        view.unfocus();
    }

    fn handleDestroy(listener: [*c]c.struct_wl_listener, _: ?*anyopaque) callconv(.c) void {
        const view: *View = @ptrCast(@as(*allowzero View, @fieldParentPtr("destroy", listener)));
        view.destroyScene();
        view.detach();
        view.destroy_cb(view.destroy_ctx, view);
        view.allocator.destroy(view);
    }

    fn handleRequestMaximize(listener: [*c]c.struct_wl_listener, _: ?*anyopaque) callconv(.c) void {
        const view: *View = @ptrCast(@as(*allowzero View, @fieldParentPtr("request_maximize", listener)));
        view.applyRequestedWindowState();
    }

    fn handleRequestFullscreen(listener: [*c]c.struct_wl_listener, _: ?*anyopaque) callconv(.c) void {
        const view: *View = @ptrCast(@as(*allowzero View, @fieldParentPtr("request_fullscreen", listener)));
        view.applyRequestedWindowState();
    }

    fn handleRequestMinimize(listener: [*c]c.struct_wl_listener, _: ?*anyopaque) callconv(.c) void {
        const view: *View = @ptrCast(@as(*allowzero View, @fieldParentPtr("request_minimize", listener)));
        view.applyRequestedWindowState();
    }

    fn handleRequestMove(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const view: *View = @ptrCast(@as(*allowzero View, @fieldParentPtr("request_move", listener)));
        const raw_event = data orelse return;
        const event: *c.struct_wlr_xdg_toplevel_move_event = @ptrCast(@alignCast(raw_event));
        view.request_move_cb(view.request_ctx, view, event.serial);
    }

    fn handleRequestResize(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const view: *View = @ptrCast(@as(*allowzero View, @fieldParentPtr("request_resize", listener)));
        const raw_event = data orelse return;
        const event: *c.struct_wlr_xdg_toplevel_resize_event = @ptrCast(@alignCast(raw_event));
        view.request_resize_cb(view.request_ctx, view, event.serial, event.edges);
    }

    fn tryCreateSceneTree(self: *View) !void {
        if (self.scene_tree != null) return;

        if (self.usesCompositorChrome()) {
            const scene_tree = c.wlr_scene_tree_create(self.parent) orelse return error.SceneXdgSurfaceCreateFailed;
            errdefer c.wlr_scene_node_destroy(&scene_tree.*.node);

            const content_tree = c.wlr_scene_subsurface_tree_create(scene_tree, self.xdg_surface.*.surface) orelse {
                return error.SceneXdgSurfaceCreateFailed;
            };

            c.wlr_scene_node_set_position(&scene_tree.*.node, self.x, self.y);
            scene_tree.*.node.data = self;
            content_tree.*.node.data = self;

            self.scene_tree = scene_tree;
            self.content_tree = content_tree;
            try self.updateSceneLayout();
            try self.redrawCompositorChrome();
        } else {
            const scene_tree = c.wlr_scene_subsurface_tree_create(self.parent, self.xdg_surface.*.surface) orelse {
                return error.SceneXdgSurfaceCreateFailed;
            };

            c.wlr_scene_node_set_position(&scene_tree.*.node, self.x, self.y);
            scene_tree.*.node.data = self;
            self.scene_tree = scene_tree;
            try self.updateAttachedShadow();
        }

        self.syncVisibility();
        log.info("created scene tree for xdg surface", .{});
    }

    fn applyRequestedWindowState(self: *View) void {
        const requested = self.toplevel.*.requested;
        const output_area = self.outputArea();
        if (!self.xdg_surface.*.initialized) return;

        if (requested.minimized) {
            self.minimized = true;
            self.syncVisibility();
            _ = c.wlr_xdg_toplevel_set_activated(self.toplevel, false);
            _ = c.wlr_xdg_surface_schedule_configure(self.xdg_surface);
            return;
        }

        self.minimized = false;
        self.syncVisibility();

        if (requested.fullscreen) {
            self.restoreCurrentGeometry();
            self.layout_mode = .fullscreen;
            self.setPosition(output_area.x, output_area.y);
            _ = c.wlr_xdg_toplevel_set_tiled(self.toplevel, 0);
            const client_box = self.clientBoxForOuterWithMode(output_area, .none);
            _ = c.wlr_xdg_toplevel_set_bounds(self.toplevel, client_box.width, client_box.height);
            _ = c.wlr_xdg_toplevel_set_size(self.toplevel, client_box.width, client_box.height);
            _ = c.wlr_xdg_toplevel_set_maximized(self.toplevel, false);
            _ = c.wlr_xdg_toplevel_set_fullscreen(self.toplevel, true);
            self.updateSceneLayout() catch {};
            return;
        }

        if (requested.maximized) {
            self.restoreCurrentGeometry();
            const outer_area = self.attachedOuterArea();
            self.setPosition(outer_area.x, outer_area.y);
            const client_box = self.clientBoxForOuterWithMode(outer_area, .attached);
            self.layout_mode = .maximized;
            _ = c.wlr_xdg_toplevel_set_tiled(
                self.toplevel,
                c.WLR_EDGE_TOP | c.WLR_EDGE_BOTTOM | c.WLR_EDGE_LEFT | c.WLR_EDGE_RIGHT,
            );
            _ = c.wlr_xdg_toplevel_set_bounds(self.toplevel, client_box.width, client_box.height);
            _ = c.wlr_xdg_toplevel_set_fullscreen(self.toplevel, false);
            _ = c.wlr_xdg_toplevel_set_maximized(self.toplevel, true);
            _ = c.wlr_xdg_toplevel_set_size(self.toplevel, client_box.width, client_box.height);
            self.updateSceneLayout() catch {};
            return;
        }

        self.restoreFloatingGeometry();
    }

    fn restoreCurrentGeometry(self: *View) void {
        if (self.layout_mode != .floating) return;
        if (self.toplevel.*.current.maximized or self.toplevel.*.current.fullscreen) return;

        self.restore_x = self.x;
        self.restore_y = self.y;

        if (self.toplevel.*.current.width > 0) {
            self.restore_width = self.toplevel.*.current.width;
        }
        if (self.toplevel.*.current.height > 0) {
            self.restore_height = self.toplevel.*.current.height;
        }
    }

    fn clampPosition(self: *const View, x: i32, y: i32) struct { x: i32, y: i32 } {
        var area = self.usable_area;
        if (area.width <= 0 or area.height <= 0) {
            c.wlr_output_layout_get_box(self.output_layout, self.primary_output, &area);
        }

        return .{
            .x = x,
            .y = @max(y, area.y),
        };
    }

    fn outputArea(self: *const View) c.struct_wlr_box {
        var area: c.struct_wlr_box = std.mem.zeroes(c.struct_wlr_box);
        c.wlr_output_layout_get_box(self.output_layout, self.primary_output, &area);
        if (area.width <= 0 or area.height <= 0) {
            return self.usable_area;
        }
        return area;
    }

    fn syncVisibility(self: *View) void {
        if (self.scene_tree) |scene_tree| {
            c.wlr_scene_node_set_enabled(&scene_tree.*.node, self.mapped and self.workspace_visible and !self.minimized);
        }
        if (self.attached_shadow_scene_buffer) |scene_buffer| {
            c.wlr_scene_node_set_enabled(&scene_buffer.*.node, self.attachedShadowVisible());
        }
    }

    fn clientBoxForOuter(self: *const View, outer: c.struct_wlr_box) c.struct_wlr_box {
        return self.clientBoxForOuterWithMode(outer, self.currentChromeMode());
    }

    fn clientBoxForOuterWithMode(self: *const View, outer: c.struct_wlr_box, mode: ChromeMode) c.struct_wlr_box {
        const metrics = self.chromeMetrics(mode);
        if (mode == .none or !self.usesCompositorChrome()) return outer;
        return .{
            .x = outer.x,
            .y = outer.y,
            .width = @max(outer.width - metrics.left - metrics.right, self.minWidth()),
            .height = @max(outer.height - metrics.top - metrics.bottom, self.minHeight()),
        };
    }

    fn updateSceneLayout(self: *View) !void {
        if (self.scene_tree == null) return;
        try self.updateAttachedShadow();
        if (!self.usesCompositorChrome()) return;

        const metrics = self.chromeMetrics(self.currentChromeMode());

        if (self.content_tree) |content_tree| {
            var clip = c.struct_wlr_box{
                .x = 0,
                .y = 0,
                .width = @max(self.effectiveWidth() - metrics.content_inset * 2, 1),
                .height = @max(self.effectiveHeight() - metrics.content_inset * 2, 1),
            };
            c.wlr_scene_subsurface_tree_set_clip(&content_tree.*.node, &clip);
            c.wlr_scene_node_set_position(
                &content_tree.*.node,
                metrics.left + metrics.content_inset,
                metrics.top + metrics.content_inset,
            );
        }

        if (self.compositorChromeVisible()) {
            if (self.frame_buffer == null or
                self.frame_buffer.?.width != @as(u32, @intCast(@max(self.outerWidth(), 1))) or
                self.frame_buffer.?.height != @as(u32, @intCast(@max(self.outerHeight(), 1))))
            {
                const next_buffer = try CairoBuffer.init(
                    self.allocator,
                    @intCast(@max(self.outerWidth(), 1)),
                    @intCast(@max(self.outerHeight(), 1)),
                );
                errdefer next_buffer.deinit();

                if (self.frame_scene_buffer == null) {
                    self.frame_scene_buffer = c.wlr_scene_buffer_create(self.scene_tree.?, next_buffer.wlrBuffer()) orelse return error.SceneXdgSurfaceCreateFailed;
                } else {
                    c.wlr_scene_buffer_set_buffer(self.frame_scene_buffer.?, next_buffer.wlrBuffer());
                }

                if (self.frame_buffer) |old_buffer| old_buffer.deinit();
                self.frame_buffer = next_buffer;
                c.wlr_scene_node_lower_to_bottom(&self.frame_scene_buffer.?.*.node);
            }

            c.wlr_scene_buffer_set_dest_size(self.frame_scene_buffer.?, self.outerWidth(), self.outerHeight());
            c.wlr_scene_node_set_enabled(&self.frame_scene_buffer.?.*.node, true);
        } else if (self.frame_scene_buffer) |scene_buffer| {
            c.wlr_scene_node_set_enabled(&scene_buffer.*.node, false);
        }
    }

    fn redrawCompositorChrome(self: *View) !void {
        if (!self.usesCompositorChrome()) return;
        try self.updateSceneLayout();
        if (!self.compositorChromeVisible()) return;

        const buffer = self.frame_buffer orelse return;
        const mode = self.currentChromeMode();
        chrome.drawWindowShell(buffer.cr, buffer.width, buffer.height, .{
            .title = self.title(),
            .title_x = 22.0,
            .attached_to_edges = mode == .attached,
            .draw_attached_shadow = mode != .attached,
        }, self.chrome_hovered);
        c.cairo_surface_flush(buffer.surface);
        if (self.frame_scene_buffer) |scene_buffer| {
            c.wlr_scene_buffer_set_buffer(scene_buffer, buffer.wlrBuffer());
        }
    }

    fn currentChromeMode(self: *const View) ChromeMode {
        if (!self.compositorChromeVisible()) return .none;
        if (self.layout_mode == .maximized or self.toplevel.*.current.maximized or self.toplevel.*.requested.maximized) return .attached;
        return .floating;
    }

    fn currentChromeModeForSizing(self: *const View) ChromeMode {
        if (!self.usesCompositorChrome()) return .none;
        if (self.layout_mode == .maximized or self.toplevel.*.current.maximized or self.toplevel.*.requested.maximized) return .attached;
        return .floating;
    }

    fn chromeMetrics(self: *const View, mode: ChromeMode) ChromeMetrics {
        _ = self;
        return switch (mode) {
            .none => .{
                .left = 0,
                .right = 0,
                .top = 0,
                .bottom = 0,
                .content_inset = 0,
            },
            .floating => .{
                .left = frame_margin_px,
                .right = frame_margin_px,
                .top = frame_margin_px + titlebar_height_px,
                .bottom = frame_margin_px,
                .content_inset = content_inset_px,
            },
            .attached => .{
                .left = 0,
                .right = 0,
                .top = titlebar_height_px,
                .bottom = attached_bottom_shadow_px,
                .content_inset = 0,
            },
        };
    }

    fn restoreOuterWidth(self: *const View) i32 {
        const mode: ChromeMode = if (self.usesCompositorChrome()) .floating else .none;
        const metrics = self.chromeMetrics(mode);
        return @max(self.restore_width + metrics.left + metrics.right, 1);
    }

    fn restoreOuterHeight(self: *const View) i32 {
        const mode: ChromeMode = if (self.usesCompositorChrome()) .floating else .none;
        const metrics = self.chromeMetrics(mode);
        return @max(self.restore_height + metrics.top + metrics.bottom, 1);
    }

    fn attachedOuterArea(self: *const View) c.struct_wlr_box {
        return self.attachedOuterAreaFor(self.usable_area);
    }

    fn attachedOuterAreaFor(self: *const View, usable_area: c.struct_wlr_box) c.struct_wlr_box {
        var outer = usable_area;
        if (outer.width <= 0 or outer.height <= 0) return outer;

        const output = self.outputArea();
        const output_bottom = output.y + output.height;
        const desired_bottom = outer.y + outer.height + attached_bottom_shadow_px;
        const bottom = @min(output_bottom, desired_bottom);
        outer.height = @max(1, bottom - outer.y);
        return outer;
    }

    fn attachedShadowVisible(self: *const View) bool {
        return self.mapped and
            self.workspace_visible and
            !self.minimized and
            !self.toplevel.*.current.fullscreen and
            !self.toplevel.*.requested.fullscreen and
            self.isAttachedLayout();
    }

    fn isAttachedLayout(self: *const View) bool {
        return self.layout_mode == .maximized or
            self.toplevel.*.current.maximized or
            self.toplevel.*.requested.maximized;
    }

    fn updateAttachedShadow(self: *View) !void {
        if (!self.attachedShadowVisible()) {
            if (self.attached_shadow_scene_buffer) |scene_buffer| {
                c.wlr_scene_node_set_enabled(&scene_buffer.*.node, false);
            }
            return;
        }

        const shadow_width: u32 = @intCast(@max(self.outerWidth(), 1));
        const shadow_height: u32 = @intCast(@max(self.outerHeight(), 1));
        if (self.attached_shadow_buffer == null or
            self.attached_shadow_buffer.?.width != shadow_width or
            self.attached_shadow_buffer.?.height != shadow_height)
        {
            const next_buffer = try CairoBuffer.init(self.allocator, shadow_width, shadow_height);
            errdefer next_buffer.deinit();
            chrome.drawAttachedShadowOnly(next_buffer.cr, next_buffer.width, next_buffer.height);
            c.cairo_surface_flush(next_buffer.surface);

            if (self.attached_shadow_scene_buffer == null) {
                self.attached_shadow_scene_buffer = c.wlr_scene_buffer_create(self.shadow_parent, next_buffer.wlrBuffer()) orelse return error.SceneXdgSurfaceCreateFailed;
            } else {
                c.wlr_scene_buffer_set_buffer(self.attached_shadow_scene_buffer.?, next_buffer.wlrBuffer());
            }

            if (self.attached_shadow_buffer) |old_buffer| old_buffer.deinit();
            self.attached_shadow_buffer = next_buffer;
        } else if (self.attached_shadow_buffer) |buffer| {
            chrome.drawAttachedShadowOnly(buffer.cr, buffer.width, buffer.height);
            c.cairo_surface_flush(buffer.surface);
            if (self.attached_shadow_scene_buffer) |scene_buffer| {
                c.wlr_scene_buffer_set_buffer(scene_buffer, buffer.wlrBuffer());
            }
        }

        if (self.attached_shadow_scene_buffer) |scene_buffer| {
            c.wlr_scene_node_set_position(&scene_buffer.*.node, self.x, self.y);
            c.wlr_scene_buffer_set_dest_size(scene_buffer, @intCast(shadow_width), @intCast(shadow_height));
            c.wlr_scene_buffer_set_filter_mode(scene_buffer, c.WLR_SCALE_FILTER_BILINEAR);
            c.wlr_scene_node_set_enabled(&scene_buffer.*.node, true);
        }
    }
};
