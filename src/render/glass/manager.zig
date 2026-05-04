const std = @import("std");
const c = @import("../../wl.zig").c;
const style = @import("style.zig");
const region = @import("region.zig");
const pipeline = @import("pipeline.zig");
const WallpaperAsset = @import("../wallpaper.zig").WallpaperAsset;

pub const GlassKind = style.GlassKind;
pub const GlassQuality = style.GlassQuality;
pub const GlassStyle = style.GlassStyle;
pub const GlassRegion = region.GlassRegion;

pub const Manager = struct {
    allocator: std.mem.Allocator,
    output_layout: [*c]c.struct_wlr_output_layout,
    scene: [*c]c.struct_wlr_scene,
    backdrop_bottom_root: [*c]c.struct_wlr_scene_tree,
    backdrop_window_root: [*c]c.struct_wlr_scene_tree,
    root: [*c]c.struct_wlr_scene_tree,
    quality: GlassQuality = .high,
    regions: std.ArrayListUnmanaged(GlassRegion) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        output_layout: [*c]c.struct_wlr_output_layout,
        scene: [*c]c.struct_wlr_scene,
        backdrop_bottom_root: [*c]c.struct_wlr_scene_tree,
        backdrop_window_root: [*c]c.struct_wlr_scene_tree,
        root: [*c]c.struct_wlr_scene_tree,
    ) Manager {
        return .{
            .allocator = allocator,
            .output_layout = output_layout,
            .scene = scene,
            .backdrop_bottom_root = backdrop_bottom_root,
            .backdrop_window_root = backdrop_window_root,
            .root = root,
        };
    }

    pub fn deinit(self: *Manager) void {
        for (self.regions.items) |*entry| {
            entry.deinit();
        }
        self.regions.deinit(self.allocator);
    }

    pub fn rootNode(self: *const Manager) [*c]c.struct_wlr_scene_tree {
        return self.root;
    }

    pub fn setQuality(self: *Manager, quality: GlassQuality) void {
        if (self.quality == quality) return;
        self.quality = quality;
        for (self.regions.items) |*entry| {
            entry.setStyle(style.styleFor(entry.kind, quality));
        }
    }

    pub fn registerRegion(
        self: *Manager,
        kind: GlassKind,
        output: [*c]c.struct_wlr_output,
        box: c.struct_wlr_box,
    ) !void {
        try self.registerRegionInstance(kind, 0, output, box);
    }

    pub fn registerRegionInstance(
        self: *Manager,
        kind: GlassKind,
        instance_id: usize,
        output: [*c]c.struct_wlr_output,
        box: c.struct_wlr_box,
    ) !void {
        if (self.findRegion(kind, instance_id, output)) |entry| {
            entry.updateBox(box);
            entry.setEnabled(true);
            entry.setStyle(style.styleFor(kind, self.quality));
            return;
        }

        try self.regions.append(self.allocator, .{
            .kind = kind,
            .instance_id = instance_id,
            .output = output,
            .box = box,
            .style = style.styleFor(kind, self.quality),
        });
    }

    pub fn updateRegion(
        self: *Manager,
        kind: GlassKind,
        output: [*c]c.struct_wlr_output,
        box: c.struct_wlr_box,
    ) void {
        self.updateRegionInstance(kind, 0, output, box);
    }

    pub fn updateRegionInstance(
        self: *Manager,
        kind: GlassKind,
        instance_id: usize,
        output: [*c]c.struct_wlr_output,
        box: c.struct_wlr_box,
    ) void {
        if (self.findRegion(kind, instance_id, output)) |entry| {
            entry.updateBox(box);
        }
    }

    pub fn removeRegion(self: *Manager, kind: GlassKind, output: [*c]c.struct_wlr_output) void {
        self.removeRegionInstance(kind, 0, output);
    }

    pub fn removeRegionInstance(
        self: *Manager,
        kind: GlassKind,
        instance_id: usize,
        output: [*c]c.struct_wlr_output,
    ) void {
        for (self.regions.items, 0..) |entry, index| {
            if (entry.kind == kind and entry.instance_id == instance_id and entry.output == output) {
                self.regions.items[index].deinit();
                _ = self.regions.swapRemove(index);
                return;
            }
        }
    }

    pub fn removeDynamicInstancesForOutput(
        self: *Manager,
        kind: GlassKind,
        output: [*c]c.struct_wlr_output,
    ) void {
        var index: usize = 0;
        while (index < self.regions.items.len) {
            const entry = self.regions.items[index];
            if (entry.kind == kind and entry.output == output and entry.instance_id != 0) {
                self.regions.items[index].deinit();
                _ = self.regions.swapRemove(index);
                continue;
            }
            index += 1;
        }
    }

    pub fn setRegionEnabled(
        self: *Manager,
        kind: GlassKind,
        output: [*c]c.struct_wlr_output,
        enabled: bool,
    ) void {
        self.setRegionEnabledInstance(kind, 0, output, enabled);
    }

    pub fn setRegionEnabledInstance(
        self: *Manager,
        kind: GlassKind,
        instance_id: usize,
        output: [*c]c.struct_wlr_output,
        enabled: bool,
    ) void {
        if (self.findRegion(kind, instance_id, output)) |entry| {
            entry.setEnabled(enabled);
        }
    }

    pub fn markDamage(self: *Manager, output: [*c]c.struct_wlr_output, damage: c.struct_wlr_box) void {
        for (self.regions.items) |*entry| {
            if (entry.output != output or !entry.enabled) continue;
            if (entry.intersectsDamage(damage)) {
                entry.dirty = true;
            }
        }
    }

    pub fn markOutputDirty(self: *Manager, output: [*c]c.struct_wlr_output) void {
        for (self.regions.items) |*entry| {
            if (entry.output == output and entry.enabled) {
                entry.dirty = true;
            }
        }
    }

    pub fn clearOutputDirty(self: *Manager, output: [*c]c.struct_wlr_output) void {
        for (self.regions.items) |*entry| {
            if (entry.output == output) {
                entry.dirty = false;
            }
        }
    }

    pub fn refreshOutput(self: *Manager, output: [*c]c.struct_wlr_output, wallpaper: ?*WallpaperAsset) !void {
        const output_box = self.outputArea(output);
        for (self.regions.items) |*entry| {
            if (entry.output != output or !entry.enabled or !entry.dirty) continue;
            try self.renderRegion(entry, output_box, wallpaper);
            entry.dirty = false;
        }
    }

    pub fn regionFor(
        self: *Manager,
        kind: GlassKind,
        output: [*c]c.struct_wlr_output,
    ) ?*GlassRegion {
        return self.findRegion(kind, 0, output);
    }

    pub fn regionForInstance(
        self: *Manager,
        kind: GlassKind,
        instance_id: usize,
        output: [*c]c.struct_wlr_output,
    ) ?*GlassRegion {
        return self.findRegion(kind, instance_id, output);
    }

    pub fn outputArea(self: *const Manager, output: [*c]c.struct_wlr_output) c.struct_wlr_box {
        var box = std.mem.zeroes(c.struct_wlr_box);
        c.wlr_output_layout_get_box(self.output_layout, output, &box);
        return box;
    }

    fn findRegion(
        self: *Manager,
        kind: GlassKind,
        instance_id: usize,
        output: [*c]c.struct_wlr_output,
    ) ?*GlassRegion {
        for (self.regions.items) |*entry| {
            if (entry.kind == kind and entry.instance_id == instance_id and entry.output == output) return entry;
        }
        return null;
    }

    fn renderRegion(
        self: *Manager,
        entry: *GlassRegion,
        output_box: c.struct_wlr_box,
        wallpaper: ?*WallpaperAsset,
    ) !void {
        const next_buffer = try pipeline.renderBackdrop(
            self.allocator,
            wallpaper,
            output_box,
            entry.box,
            entry.style,
            self.sceneBackdropContext(entry.output),
        );
        errdefer next_buffer.deinit();

        if (entry.tree == null) {
            entry.tree = c.wlr_scene_tree_create(self.root) orelse return error.GlassRegionTreeCreateFailed;
        }
        const tree = entry.tree.?;
        c.wlr_scene_node_set_position(&tree.*.node, entry.box.x, entry.box.y);

        if (entry.scene_buffer == null) {
            entry.scene_buffer = c.wlr_scene_buffer_create(tree, next_buffer.wlrBuffer()) orelse {
                return error.GlassSceneBufferCreateFailed;
            };
        } else {
            c.wlr_scene_buffer_set_buffer(entry.scene_buffer.?, next_buffer.wlrBuffer());
        }

        c.wlr_scene_buffer_set_dest_size(entry.scene_buffer.?, @max(entry.box.width, 1), @max(entry.box.height, 1));
        c.wlr_scene_buffer_set_filter_mode(entry.scene_buffer.?, c.WLR_SCALE_FILTER_BILINEAR);
        c.wlr_scene_node_set_enabled(&tree.*.node, entry.enabled);

        if (entry.buffer) |old_buffer| {
            old_buffer.deinit();
        }
        entry.buffer = next_buffer;
    }

    fn sceneBackdropContext(self: *const Manager, output: [*c]c.struct_wlr_output) ?pipeline.SceneBackdropContext {
        const scene_output = c.wlr_scene_get_scene_output(self.scene, output) orelse return null;
        return .{
            .scene_output = scene_output,
            .bottom_root = self.backdrop_bottom_root,
            .window_root = self.backdrop_window_root,
        };
    }
};
