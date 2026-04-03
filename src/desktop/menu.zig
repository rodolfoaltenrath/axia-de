const std = @import("std");
const c = @import("../wl.zig").c;
const CairoBuffer = @import("../render/cairo_buffer.zig").CairoBuffer;
const actions = @import("actions.zig");
const render = @import("render.zig");

const log = std.log.scoped(.axia_desktop);

const btn_left: u32 = 0x110;
const btn_right: u32 = 0x111;

pub const ActionCallback = *const fn (?*anyopaque, actions.Action) void;

pub const DesktopMenu = struct {
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
    page: actions.Page = .root,
    hovered_index: ?usize = null,
    action_ctx: ?*anyopaque = null,
    action_cb: ?ActionCallback = null,

    pub fn init(
        allocator: std.mem.Allocator,
        output_layout: [*c]c.struct_wlr_output_layout,
        overlay_root: [*c]c.struct_wlr_scene_tree,
    ) DesktopMenu {
        return .{
            .allocator = allocator,
            .output_layout = output_layout,
            .overlay_root = overlay_root,
        };
    }

    pub fn setPrimaryOutput(self: *DesktopMenu, output: [*c]c.struct_wlr_output) void {
        self.primary_output = output;
    }

    pub fn setActionCallback(self: *DesktopMenu, ctx: ?*anyopaque, callback: ActionCallback) void {
        self.action_ctx = ctx;
        self.action_cb = callback;
    }

    pub fn deinit(self: *DesktopMenu) void {
        self.hide();
    }

    pub fn isVisible(self: *const DesktopMenu) bool {
        return self.visible;
    }

    pub fn showAt(self: *DesktopMenu, lx: f64, ly: f64) !void {
        try self.ensureNodes();

        const width: i32 = @intCast(render.menu_width);
        const height: i32 = @intCast(render.menu_height);
        const position = self.clampPosition(@intFromFloat(lx), @intFromFloat(ly), width, height);

        self.x = position.x;
        self.y = position.y;
        self.page = .root;
        self.hovered_index = null;
        self.visible = true;

        if (self.tree) |tree| {
            c.wlr_scene_node_set_enabled(&tree.*.node, true);
            c.wlr_scene_node_set_position(&tree.*.node, self.x, self.y);
        }

        try self.redraw();
        log.info("desktop menu opened", .{});
    }

    pub fn hide(self: *DesktopMenu) void {
        self.visible = false;
        self.hovered_index = null;
        if (self.tree) |tree| {
            c.wlr_scene_node_set_enabled(&tree.*.node, false);
        }
    }

    pub fn handlePointerMotion(self: *DesktopMenu, lx: f64, ly: f64) bool {
        if (!self.visible) return false;
        const local_x = lx - @as(f64, @floatFromInt(self.x));
        const local_y = ly - @as(f64, @floatFromInt(self.y));

        if (!menuBounds().contains(local_x, local_y)) {
            if (self.hovered_index != null) {
                self.hovered_index = null;
                self.redraw() catch {};
            }
            return false;
        }

        const hovered = render.hitTest(actions.specFor(self.page).items, local_x, local_y);
        if (hovered != self.hovered_index) {
            self.hovered_index = hovered;
            self.redraw() catch {};
        }
        return true;
    }

    pub fn handlePointerButton(
        self: *DesktopMenu,
        button: u32,
        state: c.enum_wl_pointer_button_state,
        lx: f64,
        ly: f64,
    ) bool {
        if (!self.visible) return false;
        if (state != c.WL_POINTER_BUTTON_STATE_PRESSED) return false;

        const local_x = lx - @as(f64, @floatFromInt(self.x));
        const local_y = ly - @as(f64, @floatFromInt(self.y));
        const inside = menuBounds().contains(local_x, local_y);

        if (!inside) {
            self.hide();
            return false;
        }

        if (button == btn_right) {
            self.hide();
            return true;
        }

        if (button != btn_left) return true;

        const item = blk: {
            const spec = actions.specFor(self.page);
            const index = render.hitTest(spec.items, local_x, local_y) orelse return true;
            break :blk spec.items[index];
        };

        switch (item.kind) {
            .navigate => {
                if (item.target) |target| {
                    self.page = target;
                    self.hovered_index = null;
                    self.redraw() catch |err| {
                        log.err("failed to redraw desktop menu: {}", .{err});
                    };
                }
            },
            .back => {
                self.page = .root;
                self.hovered_index = null;
                self.redraw() catch |err| {
                    log.err("failed to redraw desktop menu: {}", .{err});
                };
            },
            .action => {
                if (item.action) |action| {
                    if (self.action_cb) |callback| {
                        callback(self.action_ctx, action);
                    }
                }
                self.hide();
            },
            .disabled, .separator => {},
        }
        return true;
    }

    fn ensureNodes(self: *DesktopMenu) !void {
        if (self.tree != null) return;

        const tree = c.wlr_scene_tree_create(self.overlay_root) orelse return error.DesktopMenuTreeCreateFailed;
        errdefer c.wlr_scene_node_destroy(&tree.*.node);

        const buffer = try CairoBuffer.init(self.allocator, render.menu_width, render.menu_height);
        errdefer buffer.deinit();

        const scene_buffer = c.wlr_scene_buffer_create(tree, buffer.wlrBuffer()) orelse {
            return error.DesktopMenuBufferNodeCreateFailed;
        };

        self.tree = tree;
        self.buffer = buffer;
        self.scene_buffer = scene_buffer;
        c.wlr_scene_node_set_enabled(&tree.*.node, false);
    }

    fn redraw(self: *DesktopMenu) !void {
        const buffer = self.buffer orelse return;
        render.drawMenu(buffer.cr, self.page, self.hovered_index);
        c.cairo_surface_flush(buffer.surface);
        if (self.scene_buffer) |scene_buffer| {
            c.wlr_scene_buffer_set_buffer(scene_buffer, buffer.wlrBuffer());
        }
    }

    fn clampPosition(self: *DesktopMenu, x: i32, y: i32, width: i32, height: i32) c.struct_wlr_box {
        var box = std.mem.zeroes(c.struct_wlr_box);
        if (self.primary_output) |output| {
            c.wlr_output_layout_get_box(self.output_layout, output, &box);
        }

        if (box.width <= 0 or box.height <= 0) {
            box = .{ .x = 0, .y = 0, .width = 1366, .height = 680 };
        }

        const clamped_x = std.math.clamp(x, box.x + 8, box.x + box.width - width - 8);
        const clamped_y = std.math.clamp(y, box.y + 8, box.y + box.height - height - 8);
        return .{
            .x = clamped_x,
            .y = clamped_y,
            .width = width,
            .height = height,
        };
    }

    fn menuBounds() render.Rect {
        return .{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(render.menu_width),
            .height = @floatFromInt(render.menu_height),
        };
    }
};
