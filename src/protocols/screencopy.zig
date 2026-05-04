const c = @import("../wl.zig").c;

pub const Manager = struct {
    manager: [*c]c.struct_wlr_screencopy_manager_v1,

    pub fn init(display: *c.struct_wl_display) !Manager {
        const manager = c.wlr_screencopy_manager_v1_create(display);
        if (manager == null) return error.ScreencopyManagerCreateFailed;
        return .{ .manager = manager };
    }

    pub fn deinit(self: *Manager) void {
        _ = self;
    }
};
