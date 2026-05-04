const std = @import("std");
const c = @import("../wl.zig").c;
const LayerSurface = @import("surface.zig").LayerSurface;

const log = std.log.scoped(.axia_layers);

pub const LayoutCallback = *const fn (?*anyopaque, c.struct_wlr_box) void;
pub const SurfaceStateCallback = *const fn (?*anyopaque, *LayerSurface) void;

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
    surface_state_ctx: ?*anyopaque = null,
    surface_state_cb: ?SurfaceStateCallback = null,
    surfaces: std.ArrayListUnmanaged(*LayerSurface) = .empty,
    relayout_pending: bool = false,
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
        self.scheduleRelayout();
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

    pub fn setSurfaceStateCallback(self: *LayerManager, ctx: ?*anyopaque, callback: SurfaceStateCallback) void {
        self.surface_state_ctx = ctx;
        self.surface_state_cb = callback;
    }

    pub fn getUsableArea(self: *const LayerManager) c.struct_wlr_box {
        return self.usable_area;
    }

    pub fn surfacesSlice(self: *const LayerManager) []const *LayerSurface {
        return self.surfaces.items;
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

    pub fn handlePointerMotion(self: *LayerManager, time_msec: u32, lx: f64, ly: f64) bool {
        if (self.hitTest(lx, ly)) |hit| {
            if (!c.wlr_seat_pointer_surface_has_focus(self.seat, hit.surface)) {
                c.wlr_seat_pointer_notify_enter(self.seat, hit.surface, hit.sx, hit.sy);
            } else {
                c.wlr_seat_pointer_notify_motion(self.seat, time_msec, hit.sx, hit.sy);
            }
            return true;
        }
        return false;
    }

    pub fn handlePointerButton(
        self: *LayerManager,
        time_msec: u32,
        button: u32,
        state: c.enum_wl_pointer_button_state,
        lx: f64,
        ly: f64,
    ) bool {
        if (self.hitTest(lx, ly)) |hit| {
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
            layer_surface.*.output = self.resolveOutput() orelse return error.PrimaryOutputMissing;
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
        log.info("new layer surface registered", .{});
        self.scheduleRelayout();
    }

    fn unregisterSurface(self: *LayerManager, target: *LayerSurface) void {
        if (self.surface_state_cb) |callback| {
            callback(self.surface_state_ctx, target);
        }
        for (self.surfaces.items, 0..) |surface, index| {
            if (surface == target) {
                _ = self.surfaces.swapRemove(index);
                break;
            }
        }
        self.scheduleRelayout();
    }

    fn relayout(self: *LayerManager) void {
        const output = self.resolveOutput() orelse return;

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
        const output = self.resolveOutput() orelse return;
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

    fn hitTest(self: *LayerManager, lx: f64, ly: f64) ?Hit {
        return self.hitTestTree(self.overlay_root, lx, ly) orelse
            self.hitTestTree(self.top_root, lx, ly) orelse
            self.hitTestTree(self.bottom_root, lx, ly);
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
            if (err == error.PrimaryOutputMissing) {
                log.warn("deferring layer surface registration until an output is available", .{});
                return;
            }
            log.err("failed to register layer surface: {}", .{err});
        };
    }

    fn resolveOutput(self: *const LayerManager) ?[*c]c.struct_wlr_output {
        if (self.primary_output) |output| return output;
        if (c.wlr_output_layout_get_center_output(self.output_layout)) |output| return output;

        const head = &self.output_layout.*.outputs;
        const first = head.*.next orelse return null;
        if (first == head) return null;

        const layout_output: *c.struct_wlr_output_layout_output =
            @ptrCast(@alignCast(@as(*allowzero c.struct_wlr_output_layout_output, @fieldParentPtr("link", first))));
        return layout_output.output;
    }

    fn unregisterSurfaceCallback(ctx: ?*anyopaque, surface: *LayerSurface) void {
        const raw_manager = ctx orelse return;
        const manager: *LayerManager = @ptrCast(@alignCast(raw_manager));
        manager.unregisterSurface(surface);
    }

    fn handleSurfaceCommit(ctx: ?*anyopaque, surface: *LayerSurface) void {
        const raw_manager = ctx orelse return;
        const manager: *LayerManager = @ptrCast(@alignCast(raw_manager));
        _ = surface;
        manager.scheduleRelayout();
    }

    fn scheduleRelayout(self: *LayerManager) void {
        if (self.relayout_pending) return;
        self.relayout_pending = true;
        _ = c.wl_event_loop_add_idle(self.event_loop, handleRelayoutIdle, self);
    }

    fn handleRelayoutIdle(data: ?*anyopaque) callconv(.c) void {
        const raw_manager = data orelse return;
        const manager: *LayerManager = @ptrCast(@alignCast(raw_manager));
        manager.relayout_pending = false;
        manager.relayout();
    }
};
