const std = @import("std");
const c = @import("../wl.zig").c;

const log = std.log.scoped(.axia_cursor_shape);

pub const Manager = struct {
    seat: [*c]c.struct_wlr_seat,
    cursor: [*c]c.struct_wlr_cursor,
    xcursor_manager: [*c]c.struct_wlr_xcursor_manager,
    manager: [*c]c.struct_wlr_cursor_shape_manager_v1,
    request_set_cursor: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    request_set_shape: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    listeners_ready: bool = false,

    pub fn init(
        display: *c.struct_wl_display,
        seat: [*c]c.struct_wlr_seat,
        cursor: [*c]c.struct_wlr_cursor,
        xcursor_manager: [*c]c.struct_wlr_xcursor_manager,
    ) !Manager {
        const manager = c.wlr_cursor_shape_manager_v1_create(display, 1);
        if (manager == null) return error.CursorShapeManagerCreateFailed;

        return .{
            .seat = seat,
            .cursor = cursor,
            .xcursor_manager = xcursor_manager,
            .manager = manager,
        };
    }

    pub fn setupListeners(self: *Manager) void {
        self.request_set_cursor.notify = handleRequestSetCursor;
        self.request_set_shape.notify = handleRequestSetShape;
        c.wl_signal_add(&self.seat.*.events.request_set_cursor, &self.request_set_cursor);
        c.wl_signal_add(&self.manager.*.events.request_set_shape, &self.request_set_shape);
        self.listeners_ready = true;
    }

    pub fn resetToDefault(self: *Manager) void {
        c.wlr_cursor_set_xcursor(self.cursor, self.xcursor_manager, "default");
    }

    pub fn deinit(self: *Manager) void {
        if (self.listeners_ready) {
            c.wl_list_remove(&self.request_set_shape.link);
            c.wl_list_remove(&self.request_set_cursor.link);
        }
    }

    fn cursorRequestAllowed(self: *Manager, seat_client: ?*c.struct_wlr_seat_client, serial: u32) bool {
        const focused_client = self.seat.*.pointer_state.focused_client;
        const client = seat_client orelse return false;
        if (focused_client == null or focused_client != client) return false;
        return c.wlr_seat_client_validate_event_serial(client, serial);
    }

    fn handleRequestSetCursor(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const manager: *Manager = @ptrCast(@as(*allowzero Manager, @fieldParentPtr("request_set_cursor", listener)));
        const raw_event = data orelse return;
        const event: *c.struct_wlr_seat_pointer_request_set_cursor_event = @ptrCast(@alignCast(raw_event));

        if (!manager.cursorRequestAllowed(event.seat_client, event.serial)) return;
        c.wlr_cursor_set_surface(manager.cursor, event.surface, event.hotspot_x, event.hotspot_y);
    }

    fn handleRequestSetShape(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const manager: *Manager = @ptrCast(@as(*allowzero Manager, @fieldParentPtr("request_set_shape", listener)));
        const raw_event = data orelse return;
        const event: *c.struct_wlr_cursor_shape_manager_v1_request_set_shape_event = @ptrCast(@alignCast(raw_event));

        if (event.device_type != c.WLR_CURSOR_SHAPE_MANAGER_V1_DEVICE_TYPE_POINTER) return;
        if (!manager.cursorRequestAllowed(event.seat_client, event.serial)) return;

        const shape_name = c.wlr_cursor_shape_v1_name(event.shape) orelse {
            log.warn("client requested unsupported cursor shape {}", .{event.shape});
            return;
        };
        c.wlr_cursor_set_xcursor(manager.cursor, manager.xcursor_manager, shape_name);
    }
};
