const std = @import("std");
const c = @import("../../wl.zig").c;
const style = @import("style.zig");
const CairoBuffer = @import("../cairo_buffer.zig").CairoBuffer;

pub const GlassKind = style.GlassKind;
pub const GlassStyle = style.GlassStyle;

pub const GlassRegion = struct {
    kind: GlassKind,
    instance_id: usize = 0,
    output: [*c]c.struct_wlr_output,
    box: c.struct_wlr_box,
    dirty: bool = true,
    enabled: bool = true,
    style: GlassStyle,
    tree: ?[*c]c.struct_wlr_scene_tree = null,
    scene_buffer: ?[*c]c.struct_wlr_scene_buffer = null,
    buffer: ?*CairoBuffer = null,

    pub fn updateBox(self: *GlassRegion, box: c.struct_wlr_box) void {
        if (boxesEqual(self.box, box)) return;

        const moved_only = self.box.width == box.width and self.box.height == box.height;
        self.box = box;
        if (self.tree) |tree| {
            c.wlr_scene_node_set_position(&tree.*.node, box.x, box.y);
        }
        if (!moved_only) {
            self.dirty = true;
        }
    }

    pub fn setEnabled(self: *GlassRegion, enabled: bool) void {
        if (self.enabled != enabled) {
            self.enabled = enabled;
            self.dirty = true;
        }
    }

    pub fn setStyle(self: *GlassRegion, next_style: GlassStyle) void {
        if (!std.meta.eql(self.style, next_style)) {
            self.style = next_style;
            self.dirty = true;
        }
    }

    pub fn intersectsDamage(self: GlassRegion, damage: c.struct_wlr_box) bool {
        return boxIntersects(self.box, damage);
    }

    pub fn deinit(self: *GlassRegion) void {
        if (self.tree) |tree| {
            c.wlr_scene_node_destroy(&tree.*.node);
            self.tree = null;
            self.scene_buffer = null;
        }
        if (self.buffer) |buffer| {
            buffer.deinit();
            self.buffer = null;
        }
    }
};

pub fn boxesEqual(a: c.struct_wlr_box, b: c.struct_wlr_box) bool {
    return a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height;
}

pub fn boxIntersects(a: c.struct_wlr_box, b: c.struct_wlr_box) bool {
    const ax2 = a.x + a.width;
    const ay2 = a.y + a.height;
    const bx2 = b.x + b.width;
    const by2 = b.y + b.height;

    return a.x < bx2 and ax2 > b.x and a.y < by2 and ay2 > b.y;
}
