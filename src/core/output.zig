const std = @import("std");
const c = @import("../wl.zig").c;
const BackgroundNodes = @import("../render/background.zig").BackgroundNodes;
const WallpaperAsset = @import("../render/wallpaper.zig").WallpaperAsset;

const log = std.log.scoped(.axia_output);
const nested_width = 1366;
const nested_height = 680;

pub const DestroyCallback = *const fn (?*anyopaque, *Output) void;

pub const Output = struct {
    allocator: std.mem.Allocator,
    display: *c.struct_wl_display,
    renderer: [*c]c.struct_wlr_renderer,
    buffer_allocator: [*c]c.struct_wlr_allocator,
    output_layout: [*c]c.struct_wlr_output_layout,
    scene: [*c]c.struct_wlr_scene,
    scene_output_layout: ?*c.struct_wlr_scene_output_layout,
    background_parent: [*c]c.struct_wlr_scene_tree,
    wallpaper_asset: ?*WallpaperAsset,
    wlr_output: [*c]c.struct_wlr_output,
    scene_output: ?[*c]c.struct_wlr_scene_output = null,
    background: ?BackgroundNodes = null,
    destroy_ctx: ?*anyopaque,
    destroy_cb: DestroyCallback,
    destroy: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    frame: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),

    pub fn create(
        allocator: std.mem.Allocator,
        display: *c.struct_wl_display,
        renderer: [*c]c.struct_wlr_renderer,
        buffer_allocator: [*c]c.struct_wlr_allocator,
        output_layout: [*c]c.struct_wlr_output_layout,
        scene: [*c]c.struct_wlr_scene,
        scene_output_layout: ?*c.struct_wlr_scene_output_layout,
        background_parent: [*c]c.struct_wlr_scene_tree,
        wallpaper_asset: ?*WallpaperAsset,
        wlr_output: [*c]c.struct_wlr_output,
        destroy_ctx: ?*anyopaque,
        destroy_cb: DestroyCallback,
    ) !*Output {
        const output = try allocator.create(Output);
        output.* = .{
            .allocator = allocator,
            .display = display,
            .renderer = renderer,
            .buffer_allocator = buffer_allocator,
            .output_layout = output_layout,
            .scene = scene,
            .scene_output_layout = scene_output_layout,
            .background_parent = background_parent,
            .wallpaper_asset = wallpaper_asset,
            .wlr_output = wlr_output,
            .destroy_ctx = destroy_ctx,
            .destroy_cb = destroy_cb,
        };
        return output;
    }

    pub fn setup(self: *Output) !void {
        try self.configure();

        const layout_output = c.wlr_output_layout_add_auto(self.output_layout, self.wlr_output) orelse {
            return error.OutputLayoutAddFailed;
        };

        const scene_output = c.wlr_scene_output_create(self.scene, self.wlr_output) orelse {
            return error.SceneOutputCreateFailed;
        };
        errdefer c.wlr_scene_output_destroy(scene_output);
        self.scene_output = scene_output;
        const scene_output_layout = self.scene_output_layout orelse return error.SceneOutputLayoutMissing;
        c.wlr_scene_output_layout_add_output(scene_output_layout, layout_output, scene_output);

        try self.ensureBackground();

        self.destroy.notify = destroyNotify;
        self.frame.notify = frameNotify;
        c.wl_signal_add(&self.wlr_output.*.events.destroy, &self.destroy);
        c.wl_signal_add(&self.wlr_output.*.events.frame, &self.frame);

        log.info(
            "configured output {s} at {}x{}",
            .{
                std.mem.span(self.wlr_output.*.name),
                self.wlr_output.*.width,
                self.wlr_output.*.height,
            },
        );
    }

    pub fn detach(self: *Output) void {
        if (self.background) |*background| {
            background.destroy();
            self.background = null;
        }
        if (self.scene_output) |scene_output| {
            c.wlr_scene_output_destroy(scene_output);
            self.scene_output = null;
        }
        c.wlr_output_layout_remove(self.output_layout, self.wlr_output);
        c.wl_list_remove(&self.frame.link);
        c.wl_list_remove(&self.destroy.link);
    }

    pub fn setWallpaper(self: *Output, wallpaper_asset: ?*WallpaperAsset) !void {
        self.wallpaper_asset = wallpaper_asset;
        if (self.background) |*background| {
            background.destroy();
            self.background = null;
        }

        try self.ensureBackground();

        if (self.scene_output) |scene_output| {
            if (!c.wlr_scene_output_commit(scene_output, null)) {
                return error.SceneOutputCommitFailed;
            }
        }
    }

    fn configure(self: *Output) !void {
        if (!c.wlr_output_init_render(self.wlr_output, self.buffer_allocator, self.renderer)) {
            return error.OutputRenderInitFailed;
        }

        var state = std.mem.zeroes(c.struct_wlr_output_state);
        c.wlr_output_state_init(&state);
        defer c.wlr_output_state_finish(&state);

        c.wlr_output_state_set_enabled(&state, true);

        const preferred_mode = c.wlr_output_preferred_mode(self.wlr_output);
        if (preferred_mode != null) {
            c.wlr_output_state_set_mode(&state, preferred_mode);
        } else if (c.wlr_output_is_wl(self.wlr_output)) {
            c.wlr_output_state_set_custom_mode(
                &state,
                nested_width,
                nested_height,
                0,
            );
        }

        if (!c.wlr_output_commit_state(self.wlr_output, &state)) {
            return error.OutputCommitFailed;
        }

        if (c.wlr_output_is_wl(self.wlr_output)) {
            c.wlr_wl_output_set_title(self.wlr_output, "Axia-DE");
            c.wlr_wl_output_set_app_id(self.wlr_output, "axia-de");
        }
    }

    fn renderFrame(self: *Output) !void {
        try self.ensureBackground();

        const scene_output = self.scene_output orelse return error.SceneOutputMissing;
        if (!c.wlr_scene_output_commit(scene_output, null)) {
            return error.SceneOutputCommitFailed;
        }

        var now: c.struct_timespec = undefined;
        if (c.clock_gettime(c.CLOCK_MONOTONIC, &now) == 0) {
            c.wlr_scene_output_send_frame_done(scene_output, &now);
        }
    }

    fn ensureBackground(self: *Output) !void {
        var box = std.mem.zeroes(c.struct_wlr_box);
        c.wlr_output_layout_get_box(self.output_layout, self.wlr_output, &box);

        if (self.background == null) {
            self.background = try BackgroundNodes.create(self.background_parent, self.wallpaper_asset);
        }

        self.background.?.update(box);
    }

    fn destroyNotify(listener: [*c]c.struct_wl_listener, _: ?*anyopaque) callconv(.c) void {
        const output: *Output = @ptrCast(@as(*allowzero Output, @fieldParentPtr("destroy", listener)));
        output.detach();
        output.destroy_cb(output.destroy_ctx, output);
        output.allocator.destroy(output);
    }

    fn frameNotify(listener: [*c]c.struct_wl_listener, _: ?*anyopaque) callconv(.c) void {
        const output: *Output = @ptrCast(@as(*allowzero Output, @fieldParentPtr("frame", listener)));
        output.renderFrame() catch |err| {
            log.err("failed to render output frame: {}", .{err});
        };
    }
};
