const std = @import("std");
const c = @import("../wl.zig").c;

pub const DestroyCallback = *const fn (?*anyopaque, *LayerSurface) void;
pub const CommitCallback = *const fn (?*anyopaque, *LayerSurface) void;

pub const LayerSurface = struct {
    allocator: std.mem.Allocator,
    output_layout: [*c]c.struct_wlr_output_layout,
    layer_surface: [*c]c.struct_wlr_layer_surface_v1,
    scene_layer_surface: [*c]c.struct_wlr_scene_layer_surface_v1,
    destroy_ctx: ?*anyopaque,
    destroy_cb: DestroyCallback,
    commit_ctx: ?*anyopaque,
    commit_cb: CommitCallback,
    initial_relayout_done: bool = false,
    commit: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    destroy: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),

    pub fn create(
        allocator: std.mem.Allocator,
        output_layout: [*c]c.struct_wlr_output_layout,
        parent: [*c]c.struct_wlr_scene_tree,
        layer_surface: [*c]c.struct_wlr_layer_surface_v1,
        destroy_ctx: ?*anyopaque,
        destroy_cb: DestroyCallback,
        commit_ctx: ?*anyopaque,
        commit_cb: CommitCallback,
    ) !*LayerSurface {
        const scene_layer_surface = c.wlr_scene_layer_surface_v1_create(parent, layer_surface) orelse {
            return error.SceneLayerSurfaceCreateFailed;
        };

        const surface = try allocator.create(LayerSurface);
        surface.* = .{
            .allocator = allocator,
            .output_layout = output_layout,
            .layer_surface = layer_surface,
            .scene_layer_surface = scene_layer_surface,
            .destroy_ctx = destroy_ctx,
            .destroy_cb = destroy_cb,
            .commit_ctx = commit_ctx,
            .commit_cb = commit_cb,
        };

        surface.commit.notify = handleCommit;
        surface.destroy.notify = handleDestroy;
        c.wl_signal_add(&layer_surface.*.surface.*.events.commit, &surface.commit);
        c.wl_signal_add(&layer_surface.*.events.destroy, &surface.destroy);
        return surface;
    }

    pub fn detach(self: *LayerSurface) void {
        c.wl_list_remove(&self.destroy.link);
        c.wl_list_remove(&self.commit.link);
    }

    pub fn layer(self: *const LayerSurface) u32 {
        if (self.layer_surface.*.initialized) {
            return self.layer_surface.*.current.layer;
        }
        return self.layer_surface.*.pending.layer;
    }

    pub fn reconfigure(self: *LayerSurface, full_area: c.struct_wlr_box, usable_area: *c.struct_wlr_box) void {
        if (!self.layer_surface.*.initialized) return;
        c.wlr_scene_layer_surface_v1_configure(
            self.scene_layer_surface,
            &full_area,
            usable_area,
        );
    }

    fn handleCommit(listener: [*c]c.struct_wl_listener, _: ?*anyopaque) callconv(.c) void {
        const surface: *LayerSurface = @ptrCast(@as(*allowzero LayerSurface, @fieldParentPtr("commit", listener)));
        surface.commit_cb(surface.commit_ctx, surface);
    }

    fn handleDestroy(listener: [*c]c.struct_wl_listener, _: ?*anyopaque) callconv(.c) void {
        const surface: *LayerSurface = @ptrCast(@as(*allowzero LayerSurface, @fieldParentPtr("destroy", listener)));
        surface.detach();
        surface.destroy_cb(surface.destroy_ctx, surface);
        surface.allocator.destroy(surface);
    }
};
