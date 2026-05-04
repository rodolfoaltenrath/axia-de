const c = @import("../wl.zig").c;

pub const Manager = struct {
    manager: [*c]c.struct_wlr_content_type_manager_v1,

    pub fn init(display: *c.struct_wl_display) !Manager {
        const manager = c.wlr_content_type_manager_v1_create(display, 1);
        if (manager == null) return error.ContentTypeManagerCreateFailed;

        return .{
            .manager = manager,
        };
    }

    pub fn surfaceContentType(
        self: *const Manager,
        surface: [*c]c.struct_wlr_surface,
    ) @TypeOf(c.wlr_surface_get_content_type_v1(self.manager, surface)) {
        return c.wlr_surface_get_content_type_v1(self.manager, surface);
    }

    pub fn deinit(self: *Manager) void {
        _ = self;
    }
};
