const c = @import("../wl.zig").c;

pub const Manager = struct {
    manager: [*c]c.struct_wlr_tearing_control_manager_v1,

    pub fn init(display: *c.struct_wl_display) !Manager {
        const manager = c.wlr_tearing_control_manager_v1_create(display, 1);
        if (manager == null) return error.TearingControlManagerCreateFailed;

        return .{
            .manager = manager,
        };
    }

    pub fn surfaceHint(
        self: *const Manager,
        surface: [*c]c.struct_wlr_surface,
    ) @TypeOf(c.wlr_tearing_control_manager_v1_surface_hint_from_surface(self.manager, surface)) {
        return c.wlr_tearing_control_manager_v1_surface_hint_from_surface(self.manager, surface);
    }

    pub fn deinit(self: *Manager) void {
        _ = self;
    }
};
