const c = @import("../wl.zig").c;

pub const Manager = struct {
    notifier: [*c]c.struct_wlr_idle_notifier_v1,

    pub fn init(display: *c.struct_wl_display) !Manager {
        const notifier = c.wlr_idle_notifier_v1_create(display);
        if (notifier == null) return error.IdleNotifierCreateFailed;

        return .{
            .notifier = notifier,
        };
    }

    pub fn notifyActivity(self: *Manager, seat: [*c]c.struct_wlr_seat) void {
        c.wlr_idle_notifier_v1_notify_activity(self.notifier, seat);
    }

    pub fn setInhibited(self: *Manager, inhibited: bool) void {
        c.wlr_idle_notifier_v1_set_inhibited(self.notifier, inhibited);
    }

    pub fn deinit(self: *Manager) void {
        _ = self;
    }
};
