const c = @import("../wl.zig").c;

pub const SceneManager = struct {
    scene: [*c]c.struct_wlr_scene,
    output_layout_link: ?*c.struct_wlr_scene_output_layout,
    background_tree: [*c]c.struct_wlr_scene_tree,
    dock_glass_tree: [*c]c.struct_wlr_scene_tree,
    bottom_layer_tree: [*c]c.struct_wlr_scene_tree,
    window_tree: [*c]c.struct_wlr_scene_tree,
    top_glass_tree: [*c]c.struct_wlr_scene_tree,
    top_layer_tree: [*c]c.struct_wlr_scene_tree,
    overlay_layer_tree: [*c]c.struct_wlr_scene_tree,

    pub fn init(output_layout: [*c]c.struct_wlr_output_layout) !SceneManager {
        const scene = c.wlr_scene_create() orelse return error.SceneCreateFailed;
        errdefer c.wlr_scene_node_destroy(&scene.*.tree.node);

        const output_layout_link = c.wlr_scene_attach_output_layout(scene, output_layout) orelse {
            return error.SceneOutputLayoutAttachFailed;
        };

        const background_tree = c.wlr_scene_tree_create(&scene.*.tree) orelse {
            return error.SceneBackgroundTreeCreateFailed;
        };

        const dock_glass_tree = c.wlr_scene_tree_create(&scene.*.tree) orelse {
            return error.SceneDockGlassTreeCreateFailed;
        };

        const bottom_layer_tree = c.wlr_scene_tree_create(&scene.*.tree) orelse {
            return error.SceneBottomLayerTreeCreateFailed;
        };

        const window_tree = c.wlr_scene_tree_create(&scene.*.tree) orelse {
            return error.SceneWindowTreeCreateFailed;
        };

        const top_glass_tree = c.wlr_scene_tree_create(&scene.*.tree) orelse {
            return error.SceneTopGlassTreeCreateFailed;
        };

        const top_layer_tree = c.wlr_scene_tree_create(&scene.*.tree) orelse {
            return error.SceneTopLayerTreeCreateFailed;
        };

        const overlay_layer_tree = c.wlr_scene_tree_create(&scene.*.tree) orelse {
            return error.SceneOverlayLayerTreeCreateFailed;
        };

        return .{
            .scene = scene,
            .output_layout_link = output_layout_link,
            .background_tree = background_tree,
            .dock_glass_tree = dock_glass_tree,
            .bottom_layer_tree = bottom_layer_tree,
            .window_tree = window_tree,
            .top_glass_tree = top_glass_tree,
            .top_layer_tree = top_layer_tree,
            .overlay_layer_tree = overlay_layer_tree,
        };
    }

    pub fn deinit(self: *SceneManager) void {
        _ = self.output_layout_link;
        c.wlr_scene_node_destroy(&self.scene.*.tree.node);
    }

    pub fn backgroundRoot(self: *SceneManager) [*c]c.struct_wlr_scene_tree {
        return self.background_tree;
    }

    pub fn windowRoot(self: *SceneManager) [*c]c.struct_wlr_scene_tree {
        return self.window_tree;
    }

    pub fn bottomLayerRoot(self: *SceneManager) [*c]c.struct_wlr_scene_tree {
        return self.bottom_layer_tree;
    }

    pub fn dockGlassEffectRoot(self: *SceneManager) [*c]c.struct_wlr_scene_tree {
        return self.dock_glass_tree;
    }

    pub fn topLayerRoot(self: *SceneManager) [*c]c.struct_wlr_scene_tree {
        return self.top_layer_tree;
    }

    pub fn glassEffectRoot(self: *SceneManager) [*c]c.struct_wlr_scene_tree {
        return self.top_glass_tree;
    }

    pub fn overlayLayerRoot(self: *SceneManager) [*c]c.struct_wlr_scene_tree {
        return self.overlay_layer_tree;
    }
};
