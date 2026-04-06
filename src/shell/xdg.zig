const std = @import("std");
const c = @import("../wl.zig").c;
const ipc = @import("../ipc/server.zig");
const InteractiveState = @import("interactive.zig").InteractiveState;
const View = @import("view.zig").View;
const WorkspaceState = @import("workspace.zig").WorkspaceState;

const log = std.log.scoped(.axia_xdg);

const Position = struct {
    x: i32,
    y: i32,
};

pub const XdgManager = struct {
    allocator: std.mem.Allocator,
    seat: [*c]c.struct_wlr_seat,
    output_layout: [*c]c.struct_wlr_output_layout,
    primary_output: ?[*c]c.struct_wlr_output = null,
    usable_area: c.struct_wlr_box = std.mem.zeroes(c.struct_wlr_box),
    window_root: [*c]c.struct_wlr_scene_tree,
    shell: [*c]c.struct_wlr_xdg_shell,
    views: std.ArrayListUnmanaged(*View) = .empty,
    focused_view: ?*View = null,
    interactive: InteractiveState = .{},
    workspaces: WorkspaceState = .{},
    workspace_wrap: bool = true,
    cursor_lx: f64 = 0,
    cursor_ly: f64 = 0,
    next_x: i32 = 48,
    next_y: i32 = 48,
    new_toplevel: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    listeners_ready: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        seat: [*c]c.struct_wlr_seat,
        output_layout: [*c]c.struct_wlr_output_layout,
        window_root: [*c]c.struct_wlr_scene_tree,
        display: *c.struct_wl_display,
    ) !XdgManager {
        const shell = c.wlr_xdg_shell_create(display, 6);
        if (shell == null) return error.XdgShellCreateFailed;

        return .{
            .allocator = allocator,
            .seat = seat,
            .output_layout = output_layout,
            .window_root = window_root,
            .shell = shell,
        };
    }

    pub fn setPrimaryOutput(self: *XdgManager, output: [*c]c.struct_wlr_output) void {
        self.primary_output = output;
    }

    pub fn activeWorkspace(self: *const XdgManager) usize {
        return self.workspaces.current;
    }

    pub fn setWorkspaceWrap(self: *XdgManager, enabled: bool) void {
        self.workspace_wrap = enabled;
    }

    pub fn setUsableArea(self: *XdgManager, usable_area: c.struct_wlr_box) void {
        self.usable_area = usable_area;
        self.next_x = usable_area.x + 32;
        self.next_y = usable_area.y + 32;

        for (self.views.items) |view| {
            view.setUsableArea(usable_area);
        }
    }

    pub fn activateWorkspace(self: *XdgManager, workspace_index: usize) void {
        const active = self.workspaces.activate(workspace_index);
        self.syncWorkspaceVisibility();
        log.info("workspace {} active", .{active + 1});
    }

    pub fn moveFocusedViewToWorkspace(self: *XdgManager, workspace_index: usize) void {
        const view = self.focused_view orelse return;
        const target = self.workspaces.clampIndex(workspace_index);
        view.setWorkspaceIndex(target);
        if (target != self.workspaces.current) {
            self.clearFocus();
        } else {
            self.focusView(view);
        }
        log.info("moved view to workspace {}", .{target + 1});
    }

    pub fn cycleWorkspace(self: *XdgManager) void {
        const active = if (self.workspace_wrap)
            self.workspaces.next()
        else blk: {
            if (self.workspaces.current + 1 < self.workspaces.count) {
                break :blk self.workspaces.activate(self.workspaces.current + 1);
            }
            break :blk self.workspaces.current;
        };
        self.syncWorkspaceVisibility();
        log.info("workspace {} active", .{active + 1});
    }

    pub fn workspaceSnapshot(self: *const XdgManager) ipc.WorkspaceSnapshot {
        var snapshot = ipc.WorkspaceSnapshot{
            .current = self.workspaces.current,
            .count = self.workspaces.count,
        };

        for (self.views.items) |view| {
            if (!view.mappedVisible()) continue;

            const workspace_index = self.workspaces.clampIndex(view.workspaceIndex());
            var summary = &snapshot.summaries[workspace_index];
            summary.window_count += 1;
            if (self.focused_view == view) {
                summary.focused = true;
            }
            if (summary.preview_len == 0) {
                summary.preview_len = sanitizeTitle(summary.preview[0..], view.title());
            }
        }

        return snapshot;
    }

    pub fn setupListeners(self: *XdgManager) void {
        self.new_toplevel.notify = handleNewToplevel;
        c.wl_signal_add(&self.shell.*.events.new_toplevel, &self.new_toplevel);
        self.listeners_ready = true;
    }

    pub fn deinit(self: *XdgManager) void {
        if (self.listeners_ready) {
            c.wl_list_remove(&self.new_toplevel.link);
        }

        for (self.views.items) |view| {
            view.detach();
            self.allocator.destroy(view);
        }
        self.views.deinit(self.allocator);
    }

    fn registerView(self: *XdgManager, toplevel: [*c]c.struct_wlr_xdg_toplevel) !void {
        const initial_position = self.initialPositionForToplevel(toplevel);
        const view = try View.create(
            self.allocator,
            self.seat,
            self.output_layout,
            self.primary_output orelse return error.PrimaryOutputMissing,
            self.usable_area,
            self.window_root,
            toplevel,
            toplevel.*.base,
            self,
            unregisterViewCallback,
            self,
            handleViewRequestMove,
            handleViewRequestResize,
            self.workspaces.current,
            initial_position.x,
            initial_position.y,
        );
        errdefer self.allocator.destroy(view);

        if (self.isLauncherToplevel(toplevel)) {
            view.restore_width = 760;
            view.restore_height = 432;
            const centered = self.initialPositionForLauncher();
            view.setPosition(centered.x, centered.y);
        }

        try self.views.append(self.allocator, view);
        view.setWorkspaceVisible(view.workspaceIndex() == self.workspaces.current);
        log.info("new toplevel registered", .{});

        self.next_x += 32;
        self.next_y += 24;
        const base_x = self.usable_area.x + 32;
        const base_y = self.usable_area.y + 32;
        const max_x = if (self.usable_area.width > 320) self.usable_area.x + 240 else base_x;
        const max_y = if (self.usable_area.height > 220) self.usable_area.y + 180 else base_y;
        if (self.next_x > max_x) self.next_x = base_x;
        if (self.next_y > max_y) self.next_y = base_y;
    }

    fn initialPositionForToplevel(self: *XdgManager, toplevel: [*c]c.struct_wlr_xdg_toplevel) Position {
        if (self.isLauncherToplevel(toplevel)) {
            return self.initialPositionForLauncher();
        }

        return .{ .x = self.next_x, .y = self.next_y };
    }

    fn initialPositionForLauncher(self: *const XdgManager) Position {
        const launcher_width: i32 = 760;
        const launcher_height: i32 = 432;
        const output_area = self.outputArea();
        return .{
            .x = output_area.x + @divTrunc(output_area.width - launcher_width, 2),
            .y = output_area.y + @divTrunc(output_area.height - launcher_height, 2),
        };
    }

    fn isLauncherToplevel(self: *const XdgManager, toplevel: [*c]c.struct_wlr_xdg_toplevel) bool {
        _ = self;
        if (toplevel.*.app_id != null and std.mem.eql(u8, std.mem.span(toplevel.*.app_id), "axia-launcher")) {
            return true;
        }
        if (toplevel.*.title != null and std.mem.eql(u8, std.mem.span(toplevel.*.title), "Axia Launcher")) {
            return true;
        }
        return false;
    }

    fn outputArea(self: *const XdgManager) c.struct_wlr_box {
        var area: c.struct_wlr_box = std.mem.zeroes(c.struct_wlr_box);
        const primary_output = self.primary_output orelse return self.usable_area;
        c.wlr_output_layout_get_box(self.output_layout, primary_output, &area);
        if (area.width <= 0 or area.height <= 0) {
            return self.usable_area;
        }
        return area;
    }

    fn unregisterView(self: *XdgManager, target: *View) void {
        if (self.focused_view == target) {
            self.focused_view = null;
        }

        for (self.views.items, 0..) |view, index| {
            if (view == target) {
                _ = self.views.swapRemove(index);
                return;
            }
        }
    }

    pub fn handlePointerMotion(self: *XdgManager, time_msec: u32, lx: f64, ly: f64) void {
        self.cursor_lx = lx;
        self.cursor_ly = ly;

        if (self.interactive.update(lx, ly)) {
            return;
        }

        if (self.hitTest(lx, ly)) |hit| {
            if (!c.wlr_seat_pointer_surface_has_focus(self.seat, hit.surface)) {
                c.wlr_seat_pointer_notify_enter(self.seat, hit.surface, hit.sx, hit.sy);
            } else {
                c.wlr_seat_pointer_notify_motion(self.seat, time_msec, hit.sx, hit.sy);
            }
            return;
        }

        c.wlr_seat_pointer_notify_clear_focus(self.seat);
    }

    pub fn hasHitAt(self: *XdgManager, lx: f64, ly: f64) bool {
        return self.hitTest(lx, ly) != null;
    }

    pub fn dismissLauncherIfOutside(self: *XdgManager, lx: f64, ly: f64) void {
        const launcher = self.findLauncherView() orelse return;

        if (self.hitTest(lx, ly)) |hit| {
            if (hit.view == launcher) return;
        }

        if (self.focused_view == launcher) {
            self.clearFocus();
        }
        c.wlr_xdg_toplevel_send_close(launcher.toplevel);
    }

    pub fn dismissLauncher(self: *XdgManager) bool {
        const launcher = self.findLauncherView() orelse return false;
        if (self.focused_view == launcher) {
            self.clearFocus();
        }
        c.wlr_xdg_toplevel_send_close(launcher.toplevel);
        return true;
    }

    pub fn clearDesktopFocus(self: *XdgManager) void {
        c.wlr_seat_pointer_notify_clear_focus(self.seat);
        self.clearFocus();
    }

    pub fn handlePointerButton(self: *XdgManager, time_msec: u32, button: u32, state: c.enum_wl_pointer_button_state, lx: f64, ly: f64, modifiers: u32) void {
        self.cursor_lx = lx;
        self.cursor_ly = ly;

        if (self.interactive.active()) {
            if (self.interactive.shouldForwardButtons()) {
                _ = c.wlr_seat_pointer_notify_button(self.seat, time_msec, button, state);
            }
            if (state == c.WL_POINTER_BUTTON_STATE_RELEASED) {
                self.interactive.finish();
            }
            return;
        }

        if (state == c.WL_POINTER_BUTTON_STATE_PRESSED and self.beginModifierInteraction(button, modifiers, lx, ly)) {
            return;
        }

        if (self.hitTest(lx, ly)) |hit| {
            if (state == c.WL_POINTER_BUTTON_STATE_PRESSED) {
                if (hit.view) |view| {
                    self.focusView(view);
                }
            }

            if (!c.wlr_seat_pointer_surface_has_focus(self.seat, hit.surface)) {
                c.wlr_seat_pointer_notify_enter(self.seat, hit.surface, hit.sx, hit.sy);
            }

            _ = c.wlr_seat_pointer_notify_button(
                self.seat,
                time_msec,
                button,
                state,
            );
            return;
        }

        c.wlr_seat_pointer_notify_clear_focus(self.seat);
        if (state == c.WL_POINTER_BUTTON_STATE_PRESSED) {
            self.clearFocus();
        }
    }

    fn focusView(self: *XdgManager, view: *View) void {
        if (view.workspaceIndex() != self.workspaces.current) {
            self.activateWorkspace(view.workspaceIndex());
        }

        if (self.focused_view) |focused_view| {
            if (focused_view != view) {
                focused_view.unfocus();
            }
        }

        self.focused_view = view;
        view.focus();
    }

    fn clearFocus(self: *XdgManager) void {
        if (self.focused_view) |focused_view| {
            focused_view.unfocus();
            self.focused_view = null;
        }
    }

    fn findLauncherView(self: *XdgManager) ?*View {
        for (self.views.items) |view| {
            if (view.isLauncher() and view.mappedVisible()) {
                return view;
            }
        }
        return null;
    }

    fn syncWorkspaceVisibility(self: *XdgManager) void {
        for (self.views.items) |view| {
            view.setWorkspaceVisible(view.workspaceIndex() == self.workspaces.current);
        }

        if (self.focused_view) |view| {
            if (view.workspaceIndex() != self.workspaces.current) {
                self.clearFocus();
            }
        }
    }

    const Hit = struct {
        surface: [*c]c.struct_wlr_surface,
        sx: f64,
        sy: f64,
        view: ?*View,
    };

    fn hitTest(self: *XdgManager, lx: f64, ly: f64) ?Hit {
        var sx: f64 = 0;
        var sy: f64 = 0;
        const node = c.wlr_scene_node_at(&self.window_root.*.node, lx, ly, &sx, &sy) orelse return null;
        if (node.*.type != c.WLR_SCENE_NODE_BUFFER) return null;

        const scene_buffer = c.wlr_scene_buffer_from_node(node);
        const scene_surface = c.wlr_scene_surface_try_from_buffer(scene_buffer) orelse return null;

        return .{
            .surface = scene_surface.*.surface,
            .sx = sx,
            .sy = sy,
            .view = viewFromNode(node),
        };
    }

    fn viewFromNode(node: [*c]c.struct_wlr_scene_node) ?*View {
        var current: ?[*c]c.struct_wlr_scene_node = node;
        while (current) |scene_node| {
            if (scene_node.*.data) |raw_view| {
                const view: *View = @ptrCast(@alignCast(raw_view));
                return view;
            }

            const parent = scene_node.*.parent orelse return null;
            current = &parent.*.node;
        }

        return null;
    }

    fn handleNewToplevel(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const manager: *XdgManager = @ptrCast(@as(*allowzero XdgManager, @fieldParentPtr("new_toplevel", listener)));
        const raw_toplevel = data orelse return;
        const toplevel: [*c]c.struct_wlr_xdg_toplevel = @ptrCast(@alignCast(raw_toplevel));

        manager.registerView(toplevel) catch |err| {
            log.err("failed to register toplevel: {}", .{err});
        };
    }

    fn unregisterViewCallback(ctx: ?*anyopaque, view: *View) void {
        const raw_manager = ctx orelse return;
        const manager: *XdgManager = @ptrCast(@alignCast(raw_manager));
        manager.unregisterView(view);
    }

    fn handleViewRequestMove(ctx: ?*anyopaque, view: *View, serial: u32) void {
        const raw_manager = ctx orelse return;
        const manager: *XdgManager = @ptrCast(@alignCast(raw_manager));
        manager.beginInteractiveMove(view, serial);
    }

    fn handleViewRequestResize(ctx: ?*anyopaque, view: *View, serial: u32, edges: u32) void {
        const raw_manager = ctx orelse return;
        const manager: *XdgManager = @ptrCast(@alignCast(raw_manager));
        manager.beginInteractiveResize(view, serial, edges);
    }

    fn beginInteractiveMove(self: *XdgManager, view: *View, serial: u32) void {
        if (!view.canStartInteractive()) return;
        if (!c.wlr_seat_validate_pointer_grab_serial(self.seat, view.xdg_surface.*.surface, serial)) {
            return;
        }

        self.focusView(view);
        self.interactive.beginMove(view, self.cursor_lx, self.cursor_ly);
    }

    fn beginInteractiveResize(self: *XdgManager, view: *View, serial: u32, edges: u32) void {
        if (!view.canStartInteractive()) return;
        if (!c.wlr_seat_validate_pointer_grab_serial(self.seat, view.xdg_surface.*.surface, serial)) {
            return;
        }

        self.focusView(view);
        self.interactive.beginResize(view, edges, self.cursor_lx, self.cursor_ly);
    }

    fn beginModifierInteraction(self: *XdgManager, button: u32, modifiers: u32, lx: f64, ly: f64) bool {
        if ((modifiers & c.WLR_MODIFIER_LOGO) == 0) return false;
        const hit = self.hitTest(lx, ly) orelse return false;
        const view = hit.view orelse return false;
        if (!view.canStartInteractive()) return false;

        self.focusView(view);

        switch (button) {
            0x110 => {
                self.interactive.beginMoveCompositor(view, lx, ly);
                return true;
            },
            0x111 => {
                const edges = self.resizeEdgesForView(view, hit.sx, hit.sy);
                self.interactive.beginResizeCompositor(view, edges, lx, ly);
                return true;
            },
            else => return false,
        }
    }

    fn resizeEdgesForView(self: *XdgManager, view: *View, sx: f64, sy: f64) u32 {
        _ = self;

        const width = @max(view.effectiveWidth(), view.minWidth());
        const height = @max(view.effectiveHeight(), view.minHeight());
        const horizontal_margin = @as(f64, @floatFromInt(@max(@divTrunc(width, 3), 48)));
        const vertical_margin = @as(f64, @floatFromInt(@max(@divTrunc(height, 3), 40)));

        var edges: u32 = 0;
        if (sx <= horizontal_margin) {
            edges |= c.WLR_EDGE_LEFT;
        } else if (sx >= @as(f64, @floatFromInt(width)) - horizontal_margin) {
            edges |= c.WLR_EDGE_RIGHT;
        } else if (sx < @as(f64, @floatFromInt(width)) / 2.0) {
            edges |= c.WLR_EDGE_LEFT;
        } else {
            edges |= c.WLR_EDGE_RIGHT;
        }

        if (sy <= vertical_margin) {
            edges |= c.WLR_EDGE_TOP;
        } else if (sy >= @as(f64, @floatFromInt(height)) - vertical_margin) {
            edges |= c.WLR_EDGE_BOTTOM;
        } else if (sy < @as(f64, @floatFromInt(height)) / 2.0) {
            edges |= c.WLR_EDGE_TOP;
        } else {
            edges |= c.WLR_EDGE_BOTTOM;
        }

        return edges;
    }

    fn sanitizeTitle(buffer: []u8, title: []const u8) usize {
        const max_len = @min(buffer.len, title.len);
        var out: usize = 0;
        for (title[0..max_len]) |char| {
            if (char == '\n' or char == '\r' or char == '\t') {
                buffer[out] = ' ';
            } else {
                buffer[out] = char;
            }
            out += 1;
        }
        return out;
    }
};
