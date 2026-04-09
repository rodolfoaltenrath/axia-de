const std = @import("std");
const c = @import("../wl.zig").c;
const chrome = @import("../render/window_chrome.zig");
const ipc = @import("../ipc/server.zig");
const settings_model = @import("../settings/model.zig");
const CairoBuffer = @import("../render/cairo_buffer.zig").CairoBuffer;
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
    overlay_root: [*c]c.struct_wlr_scene_tree,
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
    preview_tree: ?[*c]c.struct_wlr_scene_tree = null,
    preview_frame_buffer: ?*CairoBuffer = null,
    snap_preview_tree: ?[*c]c.struct_wlr_scene_tree = null,
    snap_target: SnapTarget = .none,
    hovered_chrome_view: ?*View = null,
    new_toplevel: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    listeners_ready: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        seat: [*c]c.struct_wlr_seat,
        output_layout: [*c]c.struct_wlr_output_layout,
        window_root: [*c]c.struct_wlr_scene_tree,
        overlay_root: [*c]c.struct_wlr_scene_tree,
        display: *c.struct_wl_display,
    ) !XdgManager {
        const shell = c.wlr_xdg_shell_create(display, 6);
        if (shell == null) return error.XdgShellCreateFailed;

        return .{
            .allocator = allocator,
            .seat = seat,
            .output_layout = output_layout,
            .window_root = window_root,
            .overlay_root = overlay_root,
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

    pub fn populateRuntimeApps(self: *const XdgManager, runtime: *settings_model.RuntimeState) void {
        for (self.views.items) |view| {
            if (!view.mappedState()) continue;

            const app_id = view.appId();
            if (app_id.len == 0) continue;

            if (findRuntimeApp(runtime, app_id)) |existing_index| {
                var existing = &runtime.apps[existing_index];
                if (self.focused_view == view) existing.focused = true;
                if (existing.title_len == 0 or self.focused_view == view) {
                    existing.title_len = copyText(&existing.title, view.title());
                }
                continue;
            }

            if (runtime.app_count >= runtime.apps.len) break;
            const app = &runtime.apps[runtime.app_count];
            app.id_len = copyText(&app.id, app_id);
            app.title_len = copyText(&app.title, view.title());
            app.focused = self.focused_view == view;
            runtime.app_count += 1;
        }
    }

    pub fn focusAppById(self: *XdgManager, app_id: []const u8) bool {
        if (app_id.len == 0) return false;

        var index = self.views.items.len;
        while (index > 0) {
            index -= 1;
            const view = self.views.items[index];
            if (!view.mappedState()) continue;
            if (!std.mem.eql(u8, view.appId(), app_id)) continue;
            self.focusView(view);
            return true;
        }

        return false;
    }

    pub fn closeAppById(self: *XdgManager, app_id: []const u8) bool {
        if (app_id.len == 0) return false;

        var index = self.views.items.len;
        while (index > 0) {
            index -= 1;
            const view = self.views.items[index];
            if (!view.mappedState()) continue;
            if (!std.mem.eql(u8, view.appId(), app_id)) continue;
            if (self.focused_view == view) {
                self.clearFocus();
            }
            c.wlr_xdg_toplevel_send_close(view.toplevel);
            return true;
        }

        return false;
    }

    pub fn showAppPreview(self: *XdgManager, app_id: []const u8, anchor_x: i32) !void {
        const view = self.findPreviewView(app_id) orelse {
            self.hideAppPreview();
            return;
        };

        self.hideAppPreview();

        const preview_max_width: i32 = 320;
        const preview_max_height: i32 = 200;
        const preview_padding: i32 = 10;
        const width = @max(view.effectiveWidth(), 1);
        const height = @max(view.effectiveHeight(), 1);
        const scale = @min(
            1.0,
            @min(
                @as(f64, @floatFromInt(preview_max_width)) / @as(f64, @floatFromInt(width)),
                @as(f64, @floatFromInt(preview_max_height)) / @as(f64, @floatFromInt(height)),
            ),
        );
        const scaled_width: i32 = @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(width)) * scale))));
        const scaled_height: i32 = @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(height)) * scale))));
        const outer_width = scaled_width + preview_padding * 2;
        const outer_height = scaled_height + preview_padding * 2;

        const tree = c.wlr_scene_tree_create(self.overlay_root) orelse return error.PreviewTreeCreateFailed;
        errdefer c.wlr_scene_node_destroy(&tree.*.node);

        const frame_buffer = try self.createPreviewFrameBuffer(@intCast(outer_width), @intCast(outer_height));
        errdefer frame_buffer.deinit();
        _ = c.wlr_scene_buffer_create(tree, frame_buffer.wlrBuffer()) orelse return error.PreviewRectCreateFailed;

        if (view.workspaceIndex() == self.workspaces.current and !view.isMinimized()) {
            const content_tree = c.wlr_scene_subsurface_tree_create(tree, view.xdg_surface.*.surface) orelse return error.PreviewSurfaceCreateFailed;
            c.wlr_scene_node_set_position(&content_tree.*.node, preview_padding, preview_padding);

            var clip = c.struct_wlr_box{
                .x = 0,
                .y = 0,
                .width = width,
                .height = height,
            };
            c.wlr_scene_subsurface_tree_set_clip(&content_tree.*.node, &clip);
            scaleSceneTree(content_tree, scale);
        } else {
            const content_tree = c.wlr_scene_tree_create(tree) orelse return error.PreviewSurfaceCreateFailed;
            try self.snapshotPreviewBuffers(content_tree, view, scale, preview_padding);
        }

        const output_area = self.outputArea();
        const margin: i32 = 16;
        const x = std.math.clamp(
            anchor_x - @divTrunc(outer_width, 2),
            output_area.x + margin,
            output_area.x + output_area.width - outer_width - margin,
        );
        const y = output_area.y + output_area.height - outer_height - 92;
        c.wlr_scene_node_set_position(&tree.*.node, x, y);
        c.wlr_scene_node_raise_to_top(&tree.*.node);

        self.preview_tree = tree;
        self.preview_frame_buffer = frame_buffer;
    }

    pub fn hideAppPreview(self: *XdgManager) void {
        if (self.preview_tree) |tree| {
            c.wlr_scene_node_destroy(&tree.*.node);
            self.preview_tree = null;
        }
        if (self.preview_frame_buffer) |buffer| {
            buffer.deinit();
            self.preview_frame_buffer = null;
        }
    }

    pub fn setupListeners(self: *XdgManager) void {
        self.new_toplevel.notify = handleNewToplevel;
        c.wl_signal_add(&self.shell.*.events.new_toplevel, &self.new_toplevel);
        self.listeners_ready = true;
    }

    pub fn deinit(self: *XdgManager) void {
        self.hideAppPreview();
        self.hideSnapPreview();
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

        if (self.isLauncherToplevel(toplevel) or self.isAppGridToplevel(toplevel)) {
            view.restore_width = 760;
            view.restore_height = 432;
            const centered = self.initialPositionForSpecialSurface(toplevel);
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
        if (self.isLauncherToplevel(toplevel) or self.isAppGridToplevel(toplevel)) {
            return self.initialPositionForSpecialSurface(toplevel);
        }

        return .{ .x = self.next_x, .y = self.next_y };
    }

    fn initialPositionForSpecialSurface(self: *const XdgManager, toplevel: [*c]c.struct_wlr_xdg_toplevel) Position {
        const special_width: i32 = if (self.isAppGridToplevel(toplevel)) 1280 else 760;
        const special_height: i32 = if (self.isAppGridToplevel(toplevel)) 820 else 432;
        const output_area = self.outputArea();
        return .{
            .x = output_area.x + @divTrunc(output_area.width - special_width, 2),
            .y = output_area.y + @divTrunc(output_area.height - special_height, 2),
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

    fn isAppGridToplevel(self: *const XdgManager, toplevel: [*c]c.struct_wlr_xdg_toplevel) bool {
        _ = self;
        if (toplevel.*.app_id != null and std.mem.eql(u8, std.mem.span(toplevel.*.app_id), "axia-app-grid")) {
            return true;
        }
        if (toplevel.*.title != null and std.mem.eql(u8, std.mem.span(toplevel.*.title), "Todos os aplicativos")) {
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

    fn createPreviewFrameBuffer(self: *XdgManager, width: u32, height: u32) !*CairoBuffer {
        const buffer = try CairoBuffer.init(self.allocator, width, height);
        const cr = buffer.cr;

        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
        c.cairo_set_source_rgba(cr, 0, 0, 0, 0);
        c.cairo_paint(cr);
        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);

        const outer_x = 0.5;
        const outer_y = 0.5;
        const outer_w = @as(f64, @floatFromInt(width)) - 1.0;
        const outer_h = @as(f64, @floatFromInt(height)) - 1.0;
        drawRoundedPreviewRect(cr, outer_x, outer_y, outer_w, outer_h, 12.0);
        c.cairo_set_source_rgba(cr, 0.08, 0.09, 0.12, 0.92);
        c.cairo_fill_preserve(cr);
        c.cairo_set_line_width(cr, 1.6);
        c.cairo_set_source_rgba(cr, 0.30, 0.90, 1.0, 0.95);
        c.cairo_stroke(cr);

        drawRoundedPreviewRect(cr, 2.0, 2.0, @as(f64, @floatFromInt(width)) - 4.0, @as(f64, @floatFromInt(height)) - 4.0, 10.5);
        c.cairo_set_line_width(cr, 1.0);
        c.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.12);
        c.cairo_stroke(cr);

        c.cairo_surface_flush(buffer.surface);
        return buffer;
    }

    fn drawRoundedPreviewRect(cr: *c.cairo_t, x: f64, y: f64, width: f64, height: f64, radius: f64) void {
        const clamped = @min(radius, @min(width, height) / 2.0);
        c.cairo_new_sub_path(cr);
        c.cairo_arc(cr, x + width - clamped, y + clamped, clamped, -std.math.pi / 2.0, 0);
        c.cairo_arc(cr, x + width - clamped, y + height - clamped, clamped, 0, std.math.pi / 2.0);
        c.cairo_arc(cr, x + clamped, y + height - clamped, clamped, std.math.pi / 2.0, std.math.pi);
        c.cairo_arc(cr, x + clamped, y + clamped, clamped, std.math.pi, 3.0 * std.math.pi / 2.0);
        c.cairo_close_path(cr);
    }

    fn unregisterView(self: *XdgManager, target: *View) void {
        if (self.focused_view == target) {
            self.focused_view = null;
        }
        if (self.hovered_chrome_view == target) {
            self.hovered_chrome_view = null;
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
            self.updateSnapPreview(lx, ly);
            return;
        }

        self.hideSnapPreview();

        const hit = self.hitTest(lx, ly);
        self.updateChromeHover(hit);

        if (hit) |resolved| {
            if (resolved.kind == .surface) {
                const surface = resolved.surface orelse return;
                if (!c.wlr_seat_pointer_surface_has_focus(self.seat, surface)) {
                    c.wlr_seat_pointer_notify_enter(self.seat, surface, resolved.sx, resolved.sy);
                } else {
                    c.wlr_seat_pointer_notify_motion(self.seat, time_msec, resolved.sx, resolved.sy);
                }
                return;
            }
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
                self.applySnapIfNeeded();
                self.interactive.finish();
                self.hideSnapPreview();
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

            switch (hit.kind) {
                .surface => {
                    const surface = hit.surface orelse return;
                    if (!c.wlr_seat_pointer_surface_has_focus(self.seat, surface)) {
                        c.wlr_seat_pointer_notify_enter(self.seat, surface, hit.sx, hit.sy);
                    }

                    _ = c.wlr_seat_pointer_notify_button(
                        self.seat,
                        time_msec,
                        button,
                        state,
                    );
                },
                .titlebar => {
                    if (state == c.WL_POINTER_BUTTON_STATE_PRESSED and button == 0x110) {
                        const view = hit.view orelse return;
                        self.interactive.beginMoveCompositor(view, lx, ly);
                    }
                },
                .resize => {
                    if (state == c.WL_POINTER_BUTTON_STATE_PRESSED and button == 0x110) {
                        const view = hit.view orelse return;
                        self.interactive.beginResizeCompositor(view, hit.resize_edges, lx, ly);
                    }
                },
                .minimize => {
                    if (state == c.WL_POINTER_BUTTON_STATE_PRESSED and button == 0x110) {
                        const view = hit.view orelse return;
                        view.requestMinimize();
                    }
                },
                .maximize => {
                    if (state == c.WL_POINTER_BUTTON_STATE_PRESSED and button == 0x110) {
                        const view = hit.view orelse return;
                        view.toggleMaximized();
                    }
                },
                .close => {
                    if (state == c.WL_POINTER_BUTTON_STATE_PRESSED and button == 0x110) {
                        const view = hit.view orelse return;
                        c.wlr_xdg_toplevel_send_close(view.toplevel);
                    }
                },
            }
            return;
        }

        self.updateChromeHover(null);
        c.wlr_seat_pointer_notify_clear_focus(self.seat);
        if (state == c.WL_POINTER_BUTTON_STATE_PRESSED) {
            self.clearFocus();
        }
    }

    fn focusView(self: *XdgManager, view: *View) void {
        if (view.workspaceIndex() != self.workspaces.current) {
            self.activateWorkspace(view.workspaceIndex());
        }

        view.restoreFromMinimized();

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

    fn findPreviewView(self: *XdgManager, app_id: []const u8) ?*View {
        var index = self.views.items.len;
        while (index > 0) {
            index -= 1;
            const view = self.views.items[index];
            if (!view.mappedState()) continue;
            if (std.mem.eql(u8, view.appId(), app_id)) return view;
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

    const SnapTarget = enum {
        none,
        full,
        top_half,
        left_half,
        right_half,
        top_left,
        top_right,
    };

    const SnapPreviewSpec = struct {
        target: SnapTarget,
        rect: c.struct_wlr_box,
    };

    fn updateSnapPreview(self: *XdgManager, lx: f64, ly: f64) void {
        if (!self.interactive.moving()) {
            self.hideSnapPreview();
            return;
        }

        const spec = self.snapSpecAt(lx, ly) orelse {
            self.hideSnapPreview();
            return;
        };

        if (self.snap_target == spec.target and self.snap_preview_tree != null) return;
        self.showSnapPreview(spec) catch {};
    }

    fn snapSpecAt(self: *const XdgManager, lx: f64, ly: f64) ?SnapPreviewSpec {
        const area = self.usable_area;
        if (area.width <= 0 or area.height <= 0) return null;

        const top_hard_zone = @as(f64, @floatFromInt(area.y)) + 8.0;
        const top_soft_zone = @as(f64, @floatFromInt(area.y)) + 60.0;
        const side_zone = 18.0;
        const left_edge = @as(f64, @floatFromInt(area.x));
        const right_edge = @as(f64, @floatFromInt(area.x + area.width));

        if (ly <= top_hard_zone) {
            return .{ .target = .full, .rect = area };
        }

        if (ly <= top_soft_zone) {
            if (lx <= left_edge + side_zone) {
                return .{ .target = .top_left, .rect = snapRect(area, .top_left) };
            }
            if (lx >= right_edge - side_zone) {
                return .{ .target = .top_right, .rect = snapRect(area, .top_right) };
            }
            return .{ .target = .top_half, .rect = snapRect(area, .top_half) };
        }

        if (lx <= left_edge + side_zone) {
            return .{ .target = .left_half, .rect = snapRect(area, .left_half) };
        }
        if (lx >= right_edge - side_zone) {
            return .{ .target = .right_half, .rect = snapRect(area, .right_half) };
        }

        return null;
    }

    fn snapRect(area: c.struct_wlr_box, target: SnapTarget) c.struct_wlr_box {
        const half_width = @divTrunc(area.width, 2);
        const half_height = @divTrunc(area.height, 2);
        return switch (target) {
            .none => area,
            .full => area,
            .top_half => .{
                .x = area.x,
                .y = area.y,
                .width = area.width,
                .height = half_height,
            },
            .left_half => .{
                .x = area.x,
                .y = area.y,
                .width = half_width,
                .height = area.height,
            },
            .right_half => .{
                .x = area.x + half_width,
                .y = area.y,
                .width = area.width - half_width,
                .height = area.height,
            },
            .top_left => .{
                .x = area.x,
                .y = area.y,
                .width = half_width,
                .height = half_height,
            },
            .top_right => .{
                .x = area.x + half_width,
                .y = area.y,
                .width = area.width - half_width,
                .height = half_height,
            },
        };
    }

    fn showSnapPreview(self: *XdgManager, spec: SnapPreviewSpec) !void {
        self.hideSnapPreview();

        const tree = c.wlr_scene_tree_create(self.overlay_root) orelse return;
        errdefer c.wlr_scene_node_destroy(&tree.*.node);

        const fill_color = [4]f32{ 0.24, 0.62, 0.90, 0.18 };
        const border_color = [4]f32{ 0.40, 0.88, 0.98, 0.82 };
        const border: i32 = 2;

        c.wlr_scene_node_set_position(&tree.*.node, spec.rect.x, spec.rect.y);
        _ = c.wlr_scene_rect_create(tree, spec.rect.width, spec.rect.height, &fill_color) orelse return;
        _ = c.wlr_scene_rect_create(tree, spec.rect.width, border, &border_color) orelse return;
        const bottom = c.wlr_scene_rect_create(tree, spec.rect.width, border, &border_color) orelse return;
        c.wlr_scene_node_set_position(&bottom.*.node, 0, spec.rect.height - border);
        const left = c.wlr_scene_rect_create(tree, border, spec.rect.height, &border_color) orelse return;
        c.wlr_scene_node_set_position(&left.*.node, 0, 0);
        const right = c.wlr_scene_rect_create(tree, border, spec.rect.height, &border_color) orelse return;
        c.wlr_scene_node_set_position(&right.*.node, spec.rect.width - border, 0);
        c.wlr_scene_node_raise_to_top(&tree.*.node);

        self.snap_preview_tree = tree;
        self.snap_target = spec.target;
    }

    fn hideSnapPreview(self: *XdgManager) void {
        if (self.snap_preview_tree) |tree| {
            c.wlr_scene_node_destroy(&tree.*.node);
            self.snap_preview_tree = null;
        }
        self.snap_target = .none;
    }

    fn applySnapIfNeeded(self: *XdgManager) void {
        if (self.snap_target == .none) return;
        const view = self.interactive.view orelse return;
        const rect = snapRect(self.usable_area, self.snap_target);
        view.applyTiledRect(rect, snapEdges(self.snap_target));
    }

    fn snapEdges(target: SnapTarget) u32 {
        return switch (target) {
            .none => 0,
            .full => c.WLR_EDGE_TOP | c.WLR_EDGE_BOTTOM | c.WLR_EDGE_LEFT | c.WLR_EDGE_RIGHT,
            .top_half => c.WLR_EDGE_TOP | c.WLR_EDGE_LEFT | c.WLR_EDGE_RIGHT,
            .left_half => c.WLR_EDGE_TOP | c.WLR_EDGE_BOTTOM | c.WLR_EDGE_LEFT,
            .right_half => c.WLR_EDGE_TOP | c.WLR_EDGE_BOTTOM | c.WLR_EDGE_RIGHT,
            .top_left => c.WLR_EDGE_TOP | c.WLR_EDGE_LEFT,
            .top_right => c.WLR_EDGE_TOP | c.WLR_EDGE_RIGHT,
        };
    }

    const Hit = struct {
        kind: enum {
            surface,
            titlebar,
            minimize,
            maximize,
            close,
            resize,
        },
        surface: ?[*c]c.struct_wlr_surface = null,
        sx: f64 = 0,
        sy: f64 = 0,
        local_x: f64 = 0,
        local_y: f64 = 0,
        resize_edges: u32 = 0,
        view: ?*View,
    };

    fn hitTest(self: *XdgManager, lx: f64, ly: f64) ?Hit {
        var sx: f64 = 0;
        var sy: f64 = 0;
        const node = c.wlr_scene_node_at(&self.window_root.*.node, lx, ly, &sx, &sy) orelse return null;
        const view = viewFromNode(node);

        if (node.*.type == c.WLR_SCENE_NODE_BUFFER) {
            const scene_buffer = c.wlr_scene_buffer_from_node(node);
            if (c.wlr_scene_surface_try_from_buffer(scene_buffer)) |scene_surface| {
                return .{
                    .kind = .surface,
                    .surface = scene_surface.*.surface,
                    .sx = sx,
                    .sy = sy,
                    .view = view,
                    .local_x = if (view) |matched| matched.localCoords(lx, ly).x else sx,
                    .local_y = if (view) |matched| matched.localCoords(lx, ly).y else sy,
                };
            }
        }

        if (view) |matched_view| {
            const local = matched_view.localCoords(lx, ly);
            if (matched_view.compositorChromeVisible()) {
                const control = matched_view.chromeControlAt(local.x, local.y);
                if (control != .none) {
                    return .{
                        .kind = switch (control) {
                            .minimize => .minimize,
                            .maximize => .maximize,
                            .close => .close,
                            .none => unreachable,
                        },
                        .view = matched_view,
                        .local_x = local.x,
                        .local_y = local.y,
                    };
                }

                const resize_edges = matched_view.chromeResizeEdges(local.x, local.y);
                if (resize_edges != 0) {
                    return .{
                        .kind = .resize,
                        .view = matched_view,
                        .local_x = local.x,
                        .local_y = local.y,
                        .resize_edges = resize_edges,
                    };
                }

                if (matched_view.isInChromeTitlebar(local.x, local.y)) {
                    return .{
                        .kind = .titlebar,
                        .view = matched_view,
                        .local_x = local.x,
                        .local_y = local.y,
                    };
                }
            }
        }

        return null;
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
                const edges = if (hit.kind == .resize)
                    hit.resize_edges
                else
                    self.resizeEdgesForView(view, hit.local_x, hit.local_y);
                self.interactive.beginResizeCompositor(view, edges, lx, ly);
                return true;
            },
            else => return false,
        }
    }

    fn resizeEdgesForView(self: *XdgManager, view: *View, sx: f64, sy: f64) u32 {
        _ = self;

        const width = @max(view.outerWidth(), view.minWidth());
        const height = @max(view.outerHeight(), view.minHeight());
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

    fn updateChromeHover(self: *XdgManager, hit: ?Hit) void {
        var next_view: ?*View = null;
        var next_control: chrome.HoveredControl = .none;

        if (hit) |resolved| {
            if (resolved.view) |view| {
                next_view = view;
                next_control = switch (resolved.kind) {
                    .minimize => .minimize,
                    .maximize => .maximize,
                    .close => .close,
                    else => .none,
                };
            }
        }

        if (self.hovered_chrome_view) |previous| {
            if (previous != next_view or next_control == .none) {
                previous.setChromeHovered(.none);
            }
        }

        if (next_view) |view| {
            view.setChromeHovered(next_control);
        }

        self.hovered_chrome_view = next_view;
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

    fn copyText(dest: []u8, src: []const u8) usize {
        const len = @min(dest.len, src.len);
        @memcpy(dest[0..len], src[0..len]);
        return len;
    }

    fn findRuntimeApp(runtime: *const settings_model.RuntimeState, app_id: []const u8) ?usize {
        for (0..runtime.app_count) |index| {
            if (std.mem.eql(u8, runtime.apps[index].idText(), app_id)) return index;
        }
        return null;
    }

    fn snapshotPreviewBuffers(self: *XdgManager, target: [*c]c.struct_wlr_scene_tree, view: *View, scale: f64, padding: i32) !void {
        _ = self;
        const source_tree = view.scene_tree orelse return;
        const node = &source_tree.*.node;
        const was_enabled = node.*.enabled;
        if (!was_enabled) {
            c.wlr_scene_node_set_enabled(node, true);
        }
        defer if (!was_enabled) c.wlr_scene_node_set_enabled(node, false);

        var context = PreviewCloneContext{
            .target = target,
            .origin_x = view.x,
            .origin_y = view.y,
            .scale = scale,
            .padding = padding,
        };
        c.wlr_scene_node_for_each_buffer(node, clonePreviewBuffer, &context);
    }

    const PreviewCloneContext = struct {
        target: [*c]c.struct_wlr_scene_tree,
        origin_x: i32,
        origin_y: i32,
        scale: f64,
        padding: i32,
    };

    fn clonePreviewBuffer(buffer: ?*c.struct_wlr_scene_buffer, sx: c_int, sy: c_int, raw_ctx: ?*anyopaque) callconv(.c) void {
        const scene_buffer = buffer orelse return;
        const source = scene_buffer.*.buffer orelse return;
        const raw_context = raw_ctx orelse return;
        const context: *PreviewCloneContext = @ptrCast(@alignCast(raw_context));

        const clone = c.wlr_scene_buffer_create(context.target, source) orelse return;
        c.wlr_scene_node_set_position(
            &clone.*.node,
            context.padding + @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(sx - context.origin_x)) * context.scale))),
            context.padding + @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(sy - context.origin_y)) * context.scale))),
        );
        c.wlr_scene_buffer_set_dest_size(
            clone,
            @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(scene_buffer.*.buffer_width)) * context.scale)))),
            @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(scene_buffer.*.buffer_height)) * context.scale)))),
        );
        c.wlr_scene_buffer_set_filter_mode(clone, c.WLR_SCALE_FILTER_BILINEAR);
    }

    fn scaleSceneTree(tree: [*c]c.struct_wlr_scene_tree, scale: f64) void {
        var link = tree.*.children.next;
        while (link != &tree.*.children) : (link = link.*.next) {
            const node: *c.struct_wlr_scene_node = @ptrCast(@alignCast(@as(*allowzero c.struct_wlr_scene_node, @fieldParentPtr("link", link))));
            c.wlr_scene_node_set_position(
                node,
                @intFromFloat(@round(@as(f64, @floatFromInt(node.*.x)) * scale)),
                @intFromFloat(@round(@as(f64, @floatFromInt(node.*.y)) * scale)),
            );

            switch (node.*.type) {
                c.WLR_SCENE_NODE_TREE => {
                    const child_tree: *c.struct_wlr_scene_tree = @ptrCast(@alignCast(@as(*allowzero c.struct_wlr_scene_tree, @fieldParentPtr("node", node))));
                    scaleSceneTree(child_tree, scale);
                },
                c.WLR_SCENE_NODE_BUFFER => {
                    const buffer: *c.struct_wlr_scene_buffer = @ptrCast(@alignCast(@as(*allowzero c.struct_wlr_scene_buffer, @fieldParentPtr("node", node))));
                    c.wlr_scene_buffer_set_dest_size(
                        buffer,
                        @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(buffer.*.buffer_width)) * scale)))),
                        @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(buffer.*.buffer_height)) * scale)))),
                    );
                    c.wlr_scene_buffer_set_filter_mode(buffer, c.WLR_SCALE_FILTER_BILINEAR);
                },
                else => {},
            }
        }
    }
};
