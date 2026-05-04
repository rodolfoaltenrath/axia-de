const c = @import("../wl.zig").c;

pub const Manager = struct {
    manager: [*c]c.struct_wlr_relative_pointer_manager_v1,
    seat: [*c]c.struct_wlr_seat,

    pub fn init(display: *c.struct_wl_display, seat: [*c]c.struct_wlr_seat) !Manager {
        const manager = c.wlr_relative_pointer_manager_v1_create(display);
        if (manager == null) return error.RelativePointerManagerCreateFailed;

        return .{
            .manager = manager,
            .seat = seat,
        };
    }

    pub fn sendRelativeMotion(
        self: *Manager,
        time_msec: u32,
        dx: f64,
        dy: f64,
        dx_unaccel: f64,
        dy_unaccel: f64,
    ) void {
        c.wlr_relative_pointer_manager_v1_send_relative_motion(
            self.manager,
            self.seat,
            @as(u64, time_msec) * 1000,
            dx,
            dy,
            dx_unaccel,
            dy_unaccel,
        );
    }

    pub fn deinit(self: *Manager) void {
        _ = self;
    }
};
