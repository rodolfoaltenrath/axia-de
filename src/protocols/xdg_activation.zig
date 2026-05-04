const std = @import("std");
const c = @import("../wl.zig").c;

pub const FocusSurfaceCallback = *const fn (?*anyopaque, [*c]c.struct_wlr_surface) bool;

const log = std.log.scoped(.axia_xdg_activation);

pub const Manager = struct {
    manager: [*c]c.struct_wlr_xdg_activation_v1,
    ctx: ?*anyopaque = null,
    focus_surface_cb: ?FocusSurfaceCallback = null,
    request_activate: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    listeners_ready: bool = false,

    pub fn init(display: *c.struct_wl_display) !Manager {
        const manager = c.wlr_xdg_activation_v1_create(display);
        if (manager == null) return error.XdgActivationCreateFailed;
        manager.*.token_timeout_msec = 30_000;

        var self = Manager{
            .manager = manager,
        };
        self.request_activate.notify = handleRequestActivate;
        c.wl_signal_add(&manager.*.events.request_activate, &self.request_activate);
        self.listeners_ready = true;
        return self;
    }

    pub fn setFocusCallback(
        self: *Manager,
        ctx: ?*anyopaque,
        callback: FocusSurfaceCallback,
    ) void {
        self.ctx = ctx;
        self.focus_surface_cb = callback;
    }

    pub fn deinit(self: *Manager) void {
        if (self.listeners_ready) {
            c.wl_list_remove(&self.request_activate.link);
        }
    }

    fn handleRequestActivate(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const self: *Manager = @ptrCast(@as(*allowzero Manager, @fieldParentPtr("request_activate", listener)));
        const raw_event = data orelse return;
        const event: *c.struct_wlr_xdg_activation_v1_request_activate_event = @ptrCast(@alignCast(raw_event));

        if (self.focus_surface_cb) |callback| {
            _ = callback(self.ctx, event.surface);
        } else {
            log.warn("activation request ignored because no focus callback is registered", .{});
        }
    }
};
