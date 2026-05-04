const std = @import("std");
const c = @import("../wl.zig").c;
const LayerSurface = @import("surface.zig").LayerSurface;

const log = std.log.scoped(.axia_layers);

pub const LayoutCallback = *const fn (?*anyopaque, c.struct_wlr_box) void;

pub const LayerManager = struct {
    allocator: std.mem.Allocator,
    event_loop: *c.struct_wl_event_loop,
    seat: [*c]c.struct_wlr_seat,
    output_layout: [*c]c.struct_wlr_output_layout,
    background_root: [*c]c.struct_wlr_scene_tree,
    bottom_root: [*c]c.struct_wlr_scene_tree,
    top_root: [*c]c.struct_wlr_scene_tree,
    overlay_root: [*c]c.struct_wlr_scene_tree,
    layer_shell: [*c]c.struct_wlr_layer_shell_v1,
    primary_output: ?[*c]c.struct_wlr_output = null,
    usable_area: c.struct_wlr_box = std.mem.zeroes(c.struct_wlr_box),
    layout_ctx: ?*anyopaque = null,
    layout_cb: ?LayoutCallback = null,
    surfaces: std.ArrayListUnmanaged(*LayerSurface) = .empty,
    new_surface: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    listeners_ready: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        event_loop: *c.struct_wl_event_loop,
        seat: [*c]c.struct_wlr_seat,
        output_layout: [*c]c.struct_wlr_output_layout,
        background_root: [*c]c.struct_wlr_scene_tree,
        bottom_root: [*c]c.struct_wlr_scene_tree,
        top_root: [*c]c.struct_wlr_scene_tree,
        overlay_root: [*c]c.struct_wlr_scene_tree,
        layer_shell: [*c]c.struct_wlr_layer_shell_v1,
    ) !LayerManager {
        return .{
            .allocator = allocator,
            .event_loop = event_loop,
            .seat = seat,
            .output_layout = output_layout,
            .background_root = background_root,
            .bottom_root = bottom_root,
            .top_root = top_root,
            .overlay_root = overlay_root,
            .layer_shell = layer_shell,
        };
    }

    pub fn setPrimaryOutput(self: *LayerManager, output: [*c]c.struct_wlr_output) void {
        self.primary_output = output;
        self.relayout();
    }

    pub fn setupListeners(self: *LayerManager) void {
        self.new_surface.notify = handleNewSurface;
        c.wl_signal_add(&self.layer_shell.*.events.new_surface, &self.new_surface);
        self.listeners_ready = true;
    }

    pub fn setLayoutCallback(self: *LayerManager, ctx: ?*anyopaque, callback: LayoutCallback) void {
        self.layout_ctx = ctx;
        self.layout_cb = callback;
    }

    pub fn getUsableArea(self: *const LayerManager) c.struct_wlr_box {
        return self.usable_area;
    }

    pub fn deinit(self: *LayerManager) void {
        if (self.listeners_ready) {
            c.wl_list_remove(&self.new_surface.link);
        }

        for (self.surfaces.items) |surface| {
            surface.detach();
            self.allocator.destroy(surface);
        }
        self.surfaces.deinit(self.allocator);
    }

    const PointerBand = enum {
        above_windows,
        below_windows,
    };

    pub fn handlePointerMotionAboveWindows(self: *LayerManager, time_msec: u32, lx: f64, ly: f64) bool {
        return self.handlePointerMotionForBand(.above_windows, time_msec, lx, ly);
    }

    pub fn handlePointerMotionBelowWindows(self: *LayerManager, time_msec: u32, lx: f64, ly: f64) bool {
        return self.handlePointerMotionForBand(.below_windows, time_msec, lx, ly);
    }

    fn handlePointerMotionForBand(self: *LayerManager, band: PointerBand, time_msec: u32, lx: f64, ly: f64) bool {
        if (self.hitTest(band, lx, ly)) |hit| {
            if (!c.wlr_seat_pointer_surface_has_focus(self.seat, hit.surface)) {
                c.wlr_seat_pointer_notify_enter(self.seat, hit.surface, hit.sx, hit.sy);
            } else {
                c.wlr_seat_pointer_notify_motion(self.seat, time_msec, hit.sx, hit.sy);
            }
            return true;
        }
        return false;
    }

    pub fn handlePointerButtonAboveWindows(
        self: *LayerManager,
        time_msec: u32,
        button: u32,
        state: c.enum_wl_pointer_button_state,
        lx: f64,
        ly: f64,
    ) bool {
        return self.handlePointerButtonForBand(.above_windows, time_msec, button, state, lx, ly);
    }

    pub fn handlePointerButtonBelowWindows(
        self: *LayerManager,
        time_msec: u32,
        button: u32,
        state: c.enum_wl_pointer_button_state,
        lx: f64,
        ly: f64,
    ) bool {
        return self.handlePointerButtonForBand(.below_windows, time_msec, button, state, lx, ly);
    }

    fn handlePointerButtonForBand(
        self: *LayerManager,
        band: PointerBand,
        time_msec: u32,
        button: u32,
        state: c.enum_wl_pointer_button_state,
        lx: f64,
        ly: f64,
    ) bool {
        if (self.hitTest(band, lx, ly)) |hit| {
            if (!c.wlr_seat_pointer_surface_has_focus(self.seat, hit.surface)) {
                c.wlr_seat_pointer_notify_enter(self.seat, hit.surface, hit.sx, hit.sy);
            }
            _ = c.wlr_seat_pointer_notify_button(self.seat, time_msec, button, state);
            return true;
        }
        return false;
    }

    fn registerSurface(self: *LayerManager, layer_surface: [*c]c.struct_wlr_layer_surface_v1) !void {
        if (layer_surface.*.output == null) {
            layer_surface.*.output = self.primary_output orelse return error.PrimaryOutputMissing;
        }

        const parent = self.rootForLayer(layer_surface.*.pending.layer);
        const surface = try LayerSurface.create(
            self.allocator,
            self.output_layout,
            parent,
            layer_surface,
            self,
            unregisterSurfaceCallback,
            self,
            handleSurfaceCommit,
        );
        errdefer self.allocator.destroy(surface);

        try self.surfaces.append(self.allocator, surface);
        _ = c.wl_event_loop_add_idle(self.event_loop, handleRelayoutIdle, self);
        log.info("new layer surface registered", .{});
    }

    fn unregisterSurface(self: *LayerManager, target: *LayerSurface) void {
        for (self.surfaces.items, 0..) |surface, index| {
            if (surface == target) {
                _ = self.surfaces.swapRemove(index);
                break;
            }
        }
        self.relayout();
    }

    fn relayout(self: *LayerManager) void {
        const output = self.primary_output orelse return;

        var full_area = std.mem.zeroes(c.struct_wlr_box);
        c.wlr_output_layout_get_box(self.output_layout, output, &full_area);
        if (full_area.width <= 0 or full_area.height <= 0) return;

        var usable_area = full_area;
        self.relayoutLayer(c.ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND, full_area, &usable_area);
        self.relayoutLayer(c.ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM, full_area, &usable_area);
        self.relayoutLayer(c.ZWLR_LAYER_SHELL_V1_LAYER_TOP, full_area, &usable_area);
        self.relayoutLayer(c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, full_area, &usable_area);
        self.usable_area = usable_area;
        if (self.layout_cb) |callback| {
            callback(self.layout_ctx, usable_area);
        }
    }

    fn relayoutLayer(self: *LayerManager, layer: u32, full_area: c.struct_wlr_box, usable_area: *c.struct_wlr_box) void {
        const output = self.primary_output orelse return;
        for (self.surfaces.items) |surface| {
            if (surface.layer() != layer) continue;
            if (surface.layer_surface.*.output != output) continue;
            surface.reconfigure(full_area, usable_area);
        }
    }

    fn rootForLayer(self: *LayerManager, layer: u32) [*c]c.struct_wlr_scene_tree {
        return switch (layer) {
            c.ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND => self.background_root,
            c.ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM => self.bottom_root,
            c.ZWLR_LAYER_SHELL_V1_LAYER_TOP => self.top_root,
            c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY => self.overlay_root,
            else => self.top_root,
        };
    }

    const Hit = struct {
        surface: [*c]c.struct_wlr_surface,
        sx: f64,
        sy: f64,
    };

    fn hitTest(self: *LayerManager, band: PointerBand, lx: f64, ly: f64) ?Hit {
        return switch (band) {
            .above_windows => self.hitTestTree(self.overlay_root, lx, ly) orelse
                self.hitTestTree(self.top_root, lx, ly),
            .below_windows => self.hitTestTree(self.bottom_root, lx, ly),
        };
    }

    fn hitTestTree(self: *LayerManager, tree: [*c]c.struct_wlr_scene_tree, lx: f64, ly: f64) ?Hit {
        _ = self;
        var sx: f64 = 0;
        var sy: f64 = 0;
        const node = c.wlr_scene_node_at(&tree.*.node, lx, ly, &sx, &sy) orelse return null;
        if (node.*.type != c.WLR_SCENE_NODE_BUFFER) return null;

        const scene_buffer = c.wlr_scene_buffer_from_node(node);
        const scene_surface = c.wlr_scene_surface_try_from_buffer(scene_buffer) orelse return null;
        const layer_surface = c.wlr_layer_surface_v1_try_from_wlr_surface(scene_surface.*.surface) orelse return null;
        if (!layer_surface.*.surface.*.mapped) return null;

        return .{
            .surface = scene_surface.*.surface,
            .sx = sx,
            .sy = sy,
        };
    }

    fn handleNewSurface(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const manager: *LayerManager = @ptrCast(@as(*allowzero LayerManager, @fieldParentPtr("new_surface", listener)));
        const raw_surface = data orelse return;
        const layer_surface: [*c]c.struct_wlr_layer_surface_v1 = @ptrCast(@alignCast(raw_surface));

        manager.registerSurface(layer_surface) catch |err| {
            log.err("failed to register layer surface: {}", .{err});
        };
    }

    fn unregisterSurfaceCallback(ctx: ?*anyopaque, surface: *LayerSurface) void {
        const raw_manager = ctx orelse return;
        const manager: *LayerManager = @ptrCast(@alignCast(raw_manager));
        manager.unregisterSurface(surface);
    }

    fn handleSurfaceCommit(ctx: ?*anyopaque, _: *LayerSurface) void {
        _ = ctx;
    }

    fn handleRelayoutIdle(data: ?*anyopaque) callconv(.c) void {
        const raw_manager = data orelse return;
        const manager: *LayerManager = @ptrCast(@alignCast(raw_manager));
        manager.relayout();
    }
};
