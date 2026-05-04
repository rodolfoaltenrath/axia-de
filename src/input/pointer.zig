const std = @import("std");
const c = @import("../wl.zig").c;

const log = std.log.scoped(.axia_pointer);

pub const CapabilitiesCallback = *const fn (?*anyopaque) void;
pub const ActivityCallback = *const fn (?*anyopaque) void;
pub const MotionCallback = *const fn (?*anyopaque, u32, f64, f64, f64, f64, f64, f64, f64, f64) void;
pub const ButtonCallback = *const fn (?*anyopaque, u32, u32, c.enum_wl_pointer_button_state, f64, f64) void;

const PointerDevice = struct {
    manager: *PointerManager,
    device: [*c]c.struct_wlr_input_device,
    destroy: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),

    fn init(manager: *PointerManager, device: [*c]c.struct_wlr_input_device) !*PointerDevice {
        const wrapper = try manager.allocator.create(PointerDevice);
        wrapper.* = .{
            .manager = manager,
            .device = device,
        };

        c.wlr_cursor_attach_input_device(manager.cursor, device);

        wrapper.destroy.notify = destroyNotify;
        c.wl_signal_add(&device.*.events.destroy, &wrapper.destroy);

        return wrapper;
    }

    fn destroyNotify(listener: [*c]c.struct_wl_listener, _: ?*anyopaque) callconv(.c) void {
        const pointer: *PointerDevice = @ptrCast(@as(*allowzero PointerDevice, @fieldParentPtr("destroy", listener)));
        c.wl_list_remove(&pointer.destroy.link);
        c.wlr_cursor_detach_input_device(pointer.manager.cursor, pointer.device);
        pointer.manager.unregisterPointer(pointer);
        pointer.manager.allocator.destroy(pointer);
    }
};

pub const PointerManager = struct {
    allocator: std.mem.Allocator,
    seat: [*c]c.struct_wlr_seat,
    output_layout: [*c]c.struct_wlr_output_layout,
    cursor: [*c]c.struct_wlr_cursor,
    xcursor_manager: [*c]c.struct_wlr_xcursor_manager,
    pointers: std.ArrayListUnmanaged(*PointerDevice) = .empty,
    motion: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    motion_absolute: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    button: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    axis: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    frame: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    listeners_ready: bool = false,
    capabilities_ctx: ?*anyopaque = null,
    capabilities_cb: ?CapabilitiesCallback = null,
    activity_ctx: ?*anyopaque = null,
    activity_cb: ?ActivityCallback = null,
    event_ctx: ?*anyopaque = null,
    motion_cb: ?MotionCallback = null,
    button_cb: ?ButtonCallback = null,

    pub fn init(
        allocator: std.mem.Allocator,
        seat: [*c]c.struct_wlr_seat,
        output_layout: [*c]c.struct_wlr_output_layout,
    ) !PointerManager {
        const cursor = c.wlr_cursor_create() orelse return error.CursorCreateFailed;
        errdefer c.wlr_cursor_destroy(cursor);

        c.wlr_cursor_attach_output_layout(cursor, output_layout);

        const xcursor_manager = c.wlr_xcursor_manager_create(null, 24) orelse {
            return error.XCursorManagerCreateFailed;
        };
        errdefer c.wlr_xcursor_manager_destroy(xcursor_manager);

        if (!c.wlr_xcursor_manager_load(xcursor_manager, 1.0)) {
            return error.XCursorManagerLoadFailed;
        }

        var manager = PointerManager{
            .allocator = allocator,
            .seat = seat,
            .output_layout = output_layout,
            .cursor = cursor,
            .xcursor_manager = xcursor_manager,
        };
        manager.setDefaultCursor();

        return manager;
    }

    pub fn setCapabilitiesNotifier(
        self: *PointerManager,
        ctx: ?*anyopaque,
        callback: CapabilitiesCallback,
    ) void {
        self.capabilities_ctx = ctx;
        self.capabilities_cb = callback;
    }

    pub fn setEventCallbacks(
        self: *PointerManager,
        ctx: ?*anyopaque,
        motion_callback: MotionCallback,
        button_callback: ButtonCallback,
    ) void {
        self.event_ctx = ctx;
        self.motion_cb = motion_callback;
        self.button_cb = button_callback;
    }

    pub fn setActivityNotifier(
        self: *PointerManager,
        ctx: ?*anyopaque,
        callback: ActivityCallback,
    ) void {
        self.activity_ctx = ctx;
        self.activity_cb = callback;
    }

    pub fn setupListeners(self: *PointerManager) void {
        self.motion.notify = handleMotion;
        self.motion_absolute.notify = handleMotionAbsolute;
        self.button.notify = handleButton;
        self.axis.notify = handleAxis;
        self.frame.notify = handleFrame;

        c.wl_signal_add(&self.cursor.*.events.motion, &self.motion);
        c.wl_signal_add(&self.cursor.*.events.motion_absolute, &self.motion_absolute);
        c.wl_signal_add(&self.cursor.*.events.button, &self.button);
        c.wl_signal_add(&self.cursor.*.events.axis, &self.axis);
        c.wl_signal_add(&self.cursor.*.events.frame, &self.frame);
        self.listeners_ready = true;
    }

    pub fn deinit(self: *PointerManager) void {
        if (self.listeners_ready) {
            c.wl_list_remove(&self.frame.link);
            c.wl_list_remove(&self.axis.link);
            c.wl_list_remove(&self.button.link);
            c.wl_list_remove(&self.motion_absolute.link);
            c.wl_list_remove(&self.motion.link);
        }

        for (self.pointers.items) |pointer| {
            c.wl_list_remove(&pointer.destroy.link);
            c.wlr_cursor_detach_input_device(self.cursor, pointer.device);
            self.allocator.destroy(pointer);
        }
        self.pointers.deinit(self.allocator);

        c.wlr_xcursor_manager_destroy(self.xcursor_manager);
        c.wlr_cursor_destroy(self.cursor);
    }

    pub fn registerPointer(self: *PointerManager, device: [*c]c.struct_wlr_input_device) !void {
        const pointer = try PointerDevice.init(self, device);
        errdefer self.allocator.destroy(pointer);

        try self.pointers.append(self.allocator, pointer);
        self.setDefaultCursor();
        self.notifyCapabilitiesChanged();

        log.info("pointer connected: {s}", .{std.mem.span(device.*.name)});
    }

    pub fn count(self: *const PointerManager) usize {
        return self.pointers.items.len;
    }

    pub fn resetCursorToDefault(self: *PointerManager) void {
        self.setDefaultCursor();
    }

    fn unregisterPointer(self: *PointerManager, target: *PointerDevice) void {
        for (self.pointers.items, 0..) |pointer, index| {
            if (pointer == target) {
                _ = self.pointers.swapRemove(index);
                break;
            }
        }

        self.notifyCapabilitiesChanged();
    }

    fn notifyCapabilitiesChanged(self: *PointerManager) void {
        if (self.capabilities_cb) |callback| {
            callback(self.capabilities_ctx);
        }
    }

    fn setDefaultCursor(self: *PointerManager) void {
        c.wlr_cursor_set_xcursor(self.cursor, self.xcursor_manager, "default");
    }

    fn notifyActivity(self: *PointerManager) void {
        if (self.activity_cb) |callback| {
            callback(self.activity_ctx);
        }
    }

    fn handleMotion(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const manager: *PointerManager = @ptrCast(@as(*allowzero PointerManager, @fieldParentPtr("motion", listener)));
        const raw_event = data orelse return;
        const event: *c.struct_wlr_pointer_motion_event = @ptrCast(@alignCast(raw_event));

        manager.notifyActivity();
        const old_x = manager.cursor.*.x;
        const old_y = manager.cursor.*.y;
        c.wlr_cursor_move(manager.cursor, &event.pointer.*.base, event.delta_x, event.delta_y);
        if (manager.motion_cb) |callback| {
            callback(
                manager.event_ctx,
                event.time_msec,
                old_x,
                old_y,
                manager.cursor.*.x,
                manager.cursor.*.y,
                event.delta_x,
                event.delta_y,
                event.unaccel_dx,
                event.unaccel_dy,
            );
        } else {
            c.wlr_seat_pointer_notify_clear_focus(manager.seat);
        }
    }

    fn handleMotionAbsolute(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const manager: *PointerManager = @ptrCast(@as(*allowzero PointerManager, @fieldParentPtr("motion_absolute", listener)));
        const raw_event = data orelse return;
        const event: *c.struct_wlr_pointer_motion_absolute_event = @ptrCast(@alignCast(raw_event));

        manager.notifyActivity();
        const old_x = manager.cursor.*.x;
        const old_y = manager.cursor.*.y;
        c.wlr_cursor_warp_absolute(manager.cursor, &event.pointer.*.base, event.x, event.y);
        if (manager.motion_cb) |callback| {
            const dx = manager.cursor.*.x - old_x;
            const dy = manager.cursor.*.y - old_y;
            callback(
                manager.event_ctx,
                event.time_msec,
                old_x,
                old_y,
                manager.cursor.*.x,
                manager.cursor.*.y,
                dx,
                dy,
                dx,
                dy,
            );
        } else {
            c.wlr_seat_pointer_notify_clear_focus(manager.seat);
        }
    }

    fn handleButton(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const manager: *PointerManager = @ptrCast(@as(*allowzero PointerManager, @fieldParentPtr("button", listener)));
        const raw_event = data orelse return;
        const event: *c.struct_wlr_pointer_button_event = @ptrCast(@alignCast(raw_event));

        manager.notifyActivity();
        if (manager.button_cb) |callback| {
            callback(
                manager.event_ctx,
                event.time_msec,
                event.button,
                event.state,
                manager.cursor.*.x,
                manager.cursor.*.y,
            );
        } else {
            _ = c.wlr_seat_pointer_notify_button(manager.seat, event.time_msec, event.button, event.state);
        }
    }

    fn handleAxis(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const manager: *PointerManager = @ptrCast(@as(*allowzero PointerManager, @fieldParentPtr("axis", listener)));
        const raw_event = data orelse return;
        const event: *c.struct_wlr_pointer_axis_event = @ptrCast(@alignCast(raw_event));

        manager.notifyActivity();
        c.wlr_seat_pointer_notify_axis(
            manager.seat,
            event.time_msec,
            event.orientation,
            event.delta,
            event.delta_discrete,
            event.source,
            event.relative_direction,
        );
    }

    fn handleFrame(listener: [*c]c.struct_wl_listener, _: ?*anyopaque) callconv(.c) void {
        const manager: *PointerManager = @ptrCast(@as(*allowzero PointerManager, @fieldParentPtr("frame", listener)));
        c.wlr_seat_pointer_notify_frame(manager.seat);
    }
};
