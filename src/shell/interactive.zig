const c = @import("../wl.zig").c;
const View = @import("view.zig").View;

pub const InteractiveMode = enum {
    none,
    move,
    resize,
};

pub const InteractiveState = struct {
    mode: InteractiveMode = .none,
    view: ?*View = null,
    forward_button_events: bool = false,
    grab_lx: f64 = 0,
    grab_ly: f64 = 0,
    grab_x: i32 = 0,
    grab_y: i32 = 0,
    grab_width: i32 = 0,
    grab_height: i32 = 0,
    resize_edges: u32 = 0,

    pub fn active(self: *const InteractiveState) bool {
        return self.mode != .none and self.view != null;
    }

    pub fn beginMove(self: *InteractiveState, view: *View, lx: f64, ly: f64) void {
        self.beginMoveWithMode(view, lx, ly, true);
    }

    pub fn beginMoveCompositor(self: *InteractiveState, view: *View, lx: f64, ly: f64) void {
        self.beginMoveWithMode(view, lx, ly, false);
    }

    pub fn beginResize(self: *InteractiveState, view: *View, edges: u32, lx: f64, ly: f64) void {
        self.beginResizeWithMode(view, edges, lx, ly, true);
    }

    pub fn beginResizeCompositor(self: *InteractiveState, view: *View, edges: u32, lx: f64, ly: f64) void {
        self.beginResizeWithMode(view, edges, lx, ly, false);
    }

    pub fn shouldForwardButtons(self: *const InteractiveState) bool {
        return self.forward_button_events;
    }

    fn beginMoveWithMode(self: *InteractiveState, view: *View, lx: f64, ly: f64, forward_button_events: bool) void {
        self.finish();
        self.mode = .move;
        self.view = view;
        self.forward_button_events = forward_button_events;
        self.grab_lx = lx;
        self.grab_ly = ly;
        self.grab_x = view.x;
        self.grab_y = view.y;
        self.grab_width = view.effectiveWidth();
        self.grab_height = view.effectiveHeight();
        self.resize_edges = 0;
    }

    fn beginResizeWithMode(self: *InteractiveState, view: *View, edges: u32, lx: f64, ly: f64, forward_button_events: bool) void {
        self.finish();
        self.mode = .resize;
        self.view = view;
        self.forward_button_events = forward_button_events;
        self.grab_lx = lx;
        self.grab_ly = ly;
        self.grab_x = view.x;
        self.grab_y = view.y;
        self.grab_width = view.effectiveWidth();
        self.grab_height = view.effectiveHeight();
        self.resize_edges = edges;
        _ = c.wlr_xdg_toplevel_set_resizing(view.toplevel, true);
    }

    pub fn update(self: *InteractiveState, lx: f64, ly: f64) bool {
        const view = self.view orelse return false;

        switch (self.mode) {
            .none => return false,
            .move => {
                const next_x = self.grab_x + @as(i32, @intFromFloat(lx - self.grab_lx));
                const next_y = self.grab_y + @as(i32, @intFromFloat(ly - self.grab_ly));
                view.setPosition(next_x, next_y);
                return true;
            },
            .resize => {
                var left = self.grab_x;
                var top = self.grab_y;
                var right = self.grab_x + self.grab_width;
                var bottom = self.grab_y + self.grab_height;

                const cursor_x = @as(i32, @intFromFloat(lx));
                const cursor_y = @as(i32, @intFromFloat(ly));
                const min_width = view.minWidth();
                const min_height = view.minHeight();

                if ((self.resize_edges & c.WLR_EDGE_LEFT) != 0) {
                    left = @min(cursor_x, right - min_width);
                }
                if ((self.resize_edges & c.WLR_EDGE_RIGHT) != 0) {
                    right = @max(cursor_x, left + min_width);
                }
                if ((self.resize_edges & c.WLR_EDGE_TOP) != 0) {
                    top = @min(cursor_y, bottom - min_height);
                }
                if ((self.resize_edges & c.WLR_EDGE_BOTTOM) != 0) {
                    bottom = @max(cursor_y, top + min_height);
                }

                view.setPosition(left, top);
                view.setSize(right - left, bottom - top);
                return true;
            },
        }
    }

    pub fn finish(self: *InteractiveState) void {
        if (self.view) |view| {
            _ = c.wlr_xdg_toplevel_set_resizing(view.toplevel, false);
        }

        self.mode = .none;
        self.view = null;
        self.forward_button_events = false;
        self.resize_edges = 0;
    }
};
