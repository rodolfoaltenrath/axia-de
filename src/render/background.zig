const std = @import("std");
const c = @import("../wl.zig").c;
const WallpaperAsset = @import("wallpaper.zig").WallpaperAsset;

pub const BackgroundNodes = struct {
    tree: [*c]c.struct_wlr_scene_tree,
    wallpaper: ?[*c]c.struct_wlr_scene_buffer,
    base: [*c]c.struct_wlr_scene_rect,
    top_strip: [*c]c.struct_wlr_scene_rect,
    left_column: [*c]c.struct_wlr_scene_rect,
    lower_shelf: [*c]c.struct_wlr_scene_rect,
    accent_block: [*c]c.struct_wlr_scene_rect,
    glow_line: [*c]c.struct_wlr_scene_rect,

    pub fn create(
        parent: [*c]c.struct_wlr_scene_tree,
        wallpaper_asset: ?*WallpaperAsset,
    ) !BackgroundNodes {
        const tree = c.wlr_scene_tree_create(parent) orelse return error.BackgroundTreeCreateFailed;
        errdefer c.wlr_scene_node_destroy(&tree.*.node);

        const wallpaper = if (wallpaper_asset) |asset|
            c.wlr_scene_buffer_create(tree, asset.buffer())
        else
            null;
        if (wallpaper_asset != null and wallpaper == null) return error.BackgroundBufferCreateFailed;

        const base = c.wlr_scene_rect_create(tree, 1, 1, &palette.base) orelse return error.BackgroundRectCreateFailed;
        const top_strip = c.wlr_scene_rect_create(tree, 1, 1, &palette.top_strip) orelse return error.BackgroundRectCreateFailed;
        const left_column = c.wlr_scene_rect_create(tree, 1, 1, &palette.left_column) orelse return error.BackgroundRectCreateFailed;
        const lower_shelf = c.wlr_scene_rect_create(tree, 1, 1, &palette.lower_shelf) orelse return error.BackgroundRectCreateFailed;
        const accent_block = c.wlr_scene_rect_create(tree, 1, 1, &palette.accent_block) orelse return error.BackgroundRectCreateFailed;
        const glow_line = c.wlr_scene_rect_create(tree, 1, 1, &palette.glow_line) orelse return error.BackgroundRectCreateFailed;

        return .{
            .tree = tree,
            .wallpaper = wallpaper,
            .base = base,
            .top_strip = top_strip,
            .left_column = left_column,
            .lower_shelf = lower_shelf,
            .accent_block = accent_block,
            .glow_line = glow_line,
        };
    }

    pub fn destroy(self: *BackgroundNodes) void {
        c.wlr_scene_node_destroy(&self.tree.*.node);
    }

    pub fn update(self: *BackgroundNodes, box: c.struct_wlr_box) void {
        c.wlr_scene_node_set_position(&self.tree.*.node, box.x, box.y);

        if (self.wallpaper) |scene_buffer| {
            c.wlr_scene_node_set_position(&scene_buffer.*.node, 0, 0);
            c.wlr_scene_buffer_set_dest_size(scene_buffer, @max(box.width, 1), @max(box.height, 1));
            setRect(self.base, 0, 0, box.width, box.height, palette.wallpaper_scrim);
        } else {
            setRect(self.base, 0, 0, box.width, box.height, palette.base);
        }

        const top_height = clamp(@divTrunc(box.height, 4), 92, 180);
        setRect(self.top_strip, 0, 0, box.width, top_height, palette.top_strip);

        const left_width = clamp(@divTrunc(box.width, 5), 180, 320);
        setRect(self.left_column, 0, top_height - 20, left_width, box.height - (top_height - 20), palette.left_column);

        const shelf_height = clamp(@divTrunc(box.height, 3), 180, 280);
        const shelf_y = box.height - shelf_height - 36;
        setRect(self.lower_shelf, 56, shelf_y, box.width - 112, shelf_height, palette.lower_shelf);

        const accent_width = clamp(@divTrunc(box.width, 4), 180, 300);
        const accent_height = clamp(@divTrunc(box.height, 6), 88, 148);
        const accent_x = box.width - accent_width - 84;
        const accent_y = box.height - accent_height - 96;
        setRect(self.accent_block, accent_x, accent_y, accent_width, accent_height, palette.accent_block);

        const glow_width = box.width;
        const glow_y = top_height + 46;
        setRect(self.glow_line, 0, glow_y, glow_width, 2, palette.glow_line);
    }
};

fn setRect(
    rect: [*c]c.struct_wlr_scene_rect,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    color: [4]f32,
) void {
    c.wlr_scene_rect_set_size(rect, @max(width, 1), @max(height, 1));
    c.wlr_scene_rect_set_color(rect, &color);
    c.wlr_scene_node_set_position(&rect.*.node, x, y);
}

fn clamp(value: i32, min_value: i32, max_value: i32) i32 {
    return std.math.clamp(value, min_value, max_value);
}

const palette = struct {
    const base = [4]f32{ 0.035, 0.040, 0.048, 1.0 };
    const wallpaper_scrim = [4]f32{ 0.018, 0.024, 0.036, 0.22 };
    const top_strip = [4]f32{ 0.040, 0.045, 0.060, 0.28 };
    const left_column = [4]f32{ 0.055, 0.070, 0.110, 0.18 };
    const lower_shelf = [4]f32{ 0.160, 0.120, 0.090, 0.10 };
    const accent_block = [4]f32{ 0.160, 0.250, 0.320, 0.14 };
    const glow_line = [4]f32{ 0.420, 0.820, 0.980, 0.28 };
};
