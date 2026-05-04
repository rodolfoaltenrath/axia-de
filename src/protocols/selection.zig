const std = @import("std");
const c = @import("../wl.zig").c;

pub const Manager = struct {
    seat: [*c]c.struct_wlr_seat,
    primary_selection: [*c]c.struct_wlr_primary_selection_v1_device_manager,
    data_control: [*c]c.struct_wlr_data_control_manager_v1,
    request_set_selection: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    request_set_primary_selection: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    listeners_ready: bool = false,

    pub fn init(display: *c.struct_wl_display, seat: [*c]c.struct_wlr_seat) !Manager {
        const primary_selection = c.wlr_primary_selection_v1_device_manager_create(display);
        if (primary_selection == null) return error.PrimarySelectionManagerCreateFailed;

        const data_control = c.wlr_data_control_manager_v1_create(display);
        if (data_control == null) return error.DataControlManagerCreateFailed;

        return .{
            .seat = seat,
            .primary_selection = primary_selection,
            .data_control = data_control,
        };
    }

    pub fn setupListeners(self: *Manager) void {
        self.request_set_selection.notify = handleRequestSetSelection;
        self.request_set_primary_selection.notify = handleRequestSetPrimarySelection;
        c.wl_signal_add(&self.seat.*.events.request_set_selection, &self.request_set_selection);
        c.wl_signal_add(&self.seat.*.events.request_set_primary_selection, &self.request_set_primary_selection);
        self.listeners_ready = true;
    }

    pub fn deinit(self: *Manager) void {
        if (self.listeners_ready) {
            c.wl_list_remove(&self.request_set_primary_selection.link);
            c.wl_list_remove(&self.request_set_selection.link);
        }
        _ = self.primary_selection;
        _ = self.data_control;
    }

    fn handleRequestSetSelection(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const manager: *Manager = @ptrCast(@as(*allowzero Manager, @fieldParentPtr("request_set_selection", listener)));
        const raw_event = data orelse return;
        const event: *c.struct_wlr_seat_request_set_selection_event = @ptrCast(@alignCast(raw_event));
        c.wlr_seat_set_selection(manager.seat, event.source, event.serial);
    }

    fn handleRequestSetPrimarySelection(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const manager: *Manager = @ptrCast(@as(*allowzero Manager, @fieldParentPtr("request_set_primary_selection", listener)));
        const raw_event = data orelse return;
        const event: *c.struct_wlr_seat_request_set_primary_selection_event = @ptrCast(@alignCast(raw_event));
        c.wlr_seat_set_primary_selection(manager.seat, event.source, event.serial);
    }
};
