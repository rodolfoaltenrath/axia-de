const std = @import("std");
const c = @import("../wl.zig").c;
const CairoBuffer = @import("../render/cairo_buffer.zig").CairoBuffer;
const files = @import("files.zig");
const model = @import("model.zig");
const render = @import("render.zig");

const log = std.log.scoped(.axia_settings);

const btn_left: u32 = 0x110;
const btn_right: u32 = 0x111;

pub const ApplyWallpaperCallback = *const fn (?*anyopaque, []const u8) void;

pub const SettingsManager = struct {
    allocator: std.mem.Allocator,
    output_layout: [*c]c.struct_wlr_output_layout,
    overlay_root: [*c]c.struct_wlr_scene_tree,
    primary_output: ?[*c]c.struct_wlr_output = null,
    tree: ?[*c]c.struct_wlr_scene_tree = null,
    scene_buffer: ?[*c]c.struct_wlr_scene_buffer = null,
    buffer: ?*CairoBuffer = null,
    visible: bool = false,
    x: i32 = 0,
    y: i32 = 0,
    page: model.Page = .wallpapers,
    hovered_index: ?usize = null,
    current_wallpaper_path: ?[]u8 = null,
    browser: files.Browser,
    apply_ctx: ?*anyopaque = null,
    apply_wallpaper_cb: ?ApplyWallpaperCallback = null,

    pub fn init(
        allocator: std.mem.Allocator,
        output_layout: [*c]c.struct_wlr_output_layout,
        overlay_root: [*c]c.struct_wlr_scene_tree,
    ) SettingsManager {
        return .{
            .allocator = allocator,
            .output_layout = output_layout,
            .overlay_root = overlay_root,
            .browser = files.Browser.init(allocator),
        };
    }

    pub fn setPrimaryOutput(self: *SettingsManager, output: [*c]c.struct_wlr_output) void {
        self.primary_output = output;
    }

    pub fn setApplyWallpaperCallback(self: *SettingsManager, ctx: ?*anyopaque, callback: ApplyWallpaperCallback) void {
        self.apply_ctx = ctx;
        self.apply_wallpaper_cb = callback;
    }

    pub fn setCurrentWallpaperPath(self: *SettingsManager, path: ?[]const u8) !void {
        if (self.current_wallpaper_path) |existing| {
            self.allocator.free(existing);
            self.current_wallpaper_path = null;
        }
        if (path) |value| {
            self.current_wallpaper_path = try self.allocator.dupe(u8, value);
        }
        if (self.visible) try self.redraw();
    }

    pub fn open(self: *SettingsManager, page: model.Page) !void {
        try self.ensureNodes();
        if (page == .wallpapers) {
            try self.browser.ensureDefaultDirectory();
        }
        self.page = page;
        self.hovered_index = null;
        self.visible = true;

        const position = self.centeredPosition(@intCast(render.panel_width), @intCast(render.panel_height));
        self.x = position.x;
        self.y = position.y;

        if (self.tree) |tree| {
            c.wlr_scene_node_set_enabled(&tree.*.node, true);
            c.wlr_scene_node_set_position(&tree.*.node, self.x, self.y);
        }

        try self.redraw();
        log.info("settings opened", .{});
    }

    pub fn close(self: *SettingsManager) void {
        self.visible = false;
        self.hovered_index = null;
        if (self.tree) |tree| {
            c.wlr_scene_node_set_enabled(&tree.*.node, false);
        }
    }

    pub fn deinit(self: *SettingsManager) void {
        self.close();
        if (self.current_wallpaper_path) |path| self.allocator.free(path);
        self.browser.deinit();
    }

    pub fn handlePointerMotion(self: *SettingsManager, lx: f64, ly: f64) bool {
        if (!self.visible) return false;
        const local_x = lx - @as(f64, @floatFromInt(self.x));
        const local_y = ly - @as(f64, @floatFromInt(self.y));
        if (!panelBounds().contains(local_x, local_y)) {
            if (self.hovered_index != null) {
                self.hovered_index = null;
                self.redraw() catch {};
            }
            return false;
        }

        const hovered = switch (self.page) {
            .wallpapers => render.wallpaperHitTest(local_x, local_y),
            else => null,
        };
        if (hovered != self.hovered_index) {
            self.hovered_index = hovered;
            self.redraw() catch {};
        }
        return true;
    }

    pub fn handlePointerButton(self: *SettingsManager, button: u32, state: c.enum_wl_pointer_button_state, lx: f64, ly: f64) bool {
        if (!self.visible) return false;
        if (state != c.WL_POINTER_BUTTON_STATE_PRESSED) return false;

        const local_x = lx - @as(f64, @floatFromInt(self.x));
        const local_y = ly - @as(f64, @floatFromInt(self.y));
        const inside = panelBounds().contains(local_x, local_y);

        if (!inside) {
            self.close();
            return false;
        }

        if (button == btn_right) {
            self.close();
            return true;
        }
        if (button != btn_left) return true;

        if (render.controls().close.contains(local_x, local_y)) {
            self.close();
            return true;
        }

        switch (self.page) {
            .wallpapers => {
                if (render.browserHomeRect().contains(local_x, local_y)) {
                    self.browser.openHome() catch |err| {
                        log.err("failed to open home directory: {}", .{err});
                    };
                    try self.redraw();
                    return true;
                }
                if (render.browserPicturesRect().contains(local_x, local_y)) {
                    self.browser.openPictures() catch |err| {
                        log.err("failed to open pictures directory: {}", .{err});
                    };
                    try self.redraw();
                    return true;
                }
                if (render.browserDownloadsRect().contains(local_x, local_y)) {
                    self.browser.openDownloads() catch |err| {
                        log.err("failed to open downloads directory: {}", .{err});
                    };
                    try self.redraw();
                    return true;
                }
                if (render.browserUpRect().contains(local_x, local_y)) {
                    self.browser.goParent() catch |err| {
                        log.err("failed to open parent directory: {}", .{err});
                    };
                    try self.redraw();
                    return true;
                }
                if (render.browserPrevRect().contains(local_x, local_y)) {
                    self.browser.previousPage();
                    try self.redraw();
                    return true;
                }
                if (render.browserNextRect().contains(local_x, local_y)) {
                    self.browser.nextPage();
                    try self.redraw();
                    return true;
                }
                if (render.browserEntryHitTest(local_x, local_y, self.browser.snapshot().count)) |entry_index| {
                    const entry = self.browser.visibleEntry(entry_index) orelse return true;
                    switch (entry.kind) {
                        .directory => {
                            self.browser.openDirectory(entry.path) catch |err| {
                                log.err("failed to open directory: {}", .{err});
                                return true;
                            };
                            self.redraw() catch |err| {
                                log.err("failed to redraw settings: {}", .{err});
                            };
                        },
                        .image => {
                            if (self.apply_wallpaper_cb) |callback| {
                                callback(self.apply_ctx, entry.path);
                            }
                        },
                    }
                    return true;
                }
                const index = render.wallpaperHitTest(local_x, local_y) orelse return true;
                const preset = model.wallpaper_presets[index];
                if (self.apply_wallpaper_cb) |callback| {
                    callback(self.apply_ctx, preset.path);
                }
                return true;
            },
            else => {
                self.close();
                return true;
            },
        }
    }

    fn ensureNodes(self: *SettingsManager) !void {
        if (self.tree != null) return;

        const tree = c.wlr_scene_tree_create(self.overlay_root) orelse return error.SettingsTreeCreateFailed;
        errdefer c.wlr_scene_node_destroy(&tree.*.node);

        const buffer = try CairoBuffer.init(self.allocator, render.panel_width, render.panel_height);
        errdefer buffer.deinit();

        const scene_buffer = c.wlr_scene_buffer_create(tree, buffer.wlrBuffer()) orelse {
            return error.SettingsBufferCreateFailed;
        };

        self.tree = tree;
        self.buffer = buffer;
        self.scene_buffer = scene_buffer;
        c.wlr_scene_node_set_enabled(&tree.*.node, false);
    }

    fn redraw(self: *SettingsManager) !void {
        const buffer = self.buffer orelse return;
        render.drawPanel(buffer.cr, .{
            .page = self.page,
            .hovered_index = self.hovered_index,
            .current_wallpaper_path = self.current_wallpaper_path,
            .browser = self.browser.snapshot(),
        });
        c.cairo_surface_flush(buffer.surface);
        if (self.scene_buffer) |scene_buffer| {
            c.wlr_scene_buffer_set_buffer(scene_buffer, buffer.wlrBuffer());
        }
    }

    fn centeredPosition(self: *SettingsManager, width: i32, height: i32) c.struct_wlr_box {
        var box = std.mem.zeroes(c.struct_wlr_box);
        if (self.primary_output) |output| {
            c.wlr_output_layout_get_box(self.output_layout, output, &box);
        }
        if (box.width <= 0 or box.height <= 0) {
            box = .{ .x = 0, .y = 0, .width = 1366, .height = 680 };
        }
        return .{
            .x = box.x + @divTrunc(box.width - width, 2),
            .y = box.y + @divTrunc(box.height - height, 2),
            .width = width,
            .height = height,
        };
    }

    fn panelBounds() render.Rect {
        return .{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(render.panel_width),
            .height = @floatFromInt(render.panel_height),
        };
    }
};
