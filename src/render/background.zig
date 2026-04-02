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

        hideRect(self.top_strip);
        hideRect(self.left_column);
        hideRect(self.lower_shelf);
        hideRect(self.accent_block);
        hideRect(self.glow_line);
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

fn hideRect(rect: [*c]c.struct_wlr_scene_rect) void {
    const transparent = [4]f32{ 0.0, 0.0, 0.0, 0.0 };
    c.wlr_scene_rect_set_size(rect, 1, 1);
    c.wlr_scene_rect_set_color(rect, &transparent);
    c.wlr_scene_node_set_position(&rect.*.node, 0, 0);
}

const palette = struct {
    const base = [4]f32{ 0.035, 0.040, 0.048, 1.0 };
    const wallpaper_scrim = [4]f32{ 0.0, 0.0, 0.0, 0.04 };
    const top_strip = transparent;
    const left_column = transparent;
    const lower_shelf = transparent;
    const accent_block = transparent;
    const glow_line = transparent;
    const transparent = [4]f32{ 0.0, 0.0, 0.0, 0.0 };
};
