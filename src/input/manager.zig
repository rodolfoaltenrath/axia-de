const std = @import("std");
const c = @import("../wl.zig").c;
const PointerManager = @import("pointer.zig").PointerManager;
const MotionCallback = @import("pointer.zig").MotionCallback;
const ButtonCallback = @import("pointer.zig").ButtonCallback;

const log = std.log.scoped(.axia_input);

pub const ShortcutCallback = *const fn (?*anyopaque, u32, c.xkb_keysym_t) bool;

const Keyboard = struct {
    manager: *InputManager,
    device: [*c]c.struct_wlr_input_device,
    keyboard: [*c]c.struct_wlr_keyboard,
    destroy: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    modifiers: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    key: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),

    fn init(manager: *InputManager, device: [*c]c.struct_wlr_input_device) !*Keyboard {
        const keyboard = c.wlr_keyboard_from_input_device(device);
        if (keyboard == null) {
            return error.KeyboardCastFailed;
        }

        const wrapper = try manager.allocator.create(Keyboard);
        errdefer manager.allocator.destroy(wrapper);

        const xkb_context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse {
            return error.XkbContextCreateFailed;
        };
        defer c.xkb_context_unref(xkb_context);

        const keymap = c.xkb_keymap_new_from_names(
            xkb_context,
            null,
            c.XKB_KEYMAP_COMPILE_NO_FLAGS,
        ) orelse {
            return error.XkbKeymapCreateFailed;
        };
        defer c.xkb_keymap_unref(keymap);

        if (!c.wlr_keyboard_set_keymap(keyboard, keymap)) {
            return error.KeyboardKeymapSetFailed;
        }

        c.wlr_keyboard_set_repeat_info(keyboard, 25, 600);

        wrapper.* = .{
            .manager = manager,
            .device = device,
            .keyboard = keyboard,
        };

        wrapper.destroy.notify = destroyNotify;
        wrapper.modifiers.notify = handleModifiers;
        wrapper.key.notify = handleKey;

        c.wl_signal_add(&device.*.events.destroy, &wrapper.destroy);
        c.wl_signal_add(&keyboard.*.events.modifiers, &wrapper.modifiers);
        c.wl_signal_add(&keyboard.*.events.key, &wrapper.key);

        c.wlr_seat_set_keyboard(manager.seat, keyboard);

        return wrapper;
    }

    fn destroyNotify(listener: [*c]c.struct_wl_listener, _: ?*anyopaque) callconv(.c) void {
        const keyboard: *Keyboard = @ptrCast(@as(*allowzero Keyboard, @fieldParentPtr("destroy", listener)));
        c.wl_list_remove(&keyboard.key.link);
        c.wl_list_remove(&keyboard.modifiers.link);
        c.wl_list_remove(&keyboard.destroy.link);
        keyboard.manager.unregisterKeyboard(keyboard);
        keyboard.manager.allocator.destroy(keyboard);
    }

    fn handleModifiers(listener: [*c]c.struct_wl_listener, _: ?*anyopaque) callconv(.c) void {
        const keyboard: *Keyboard = @ptrCast(@as(*allowzero Keyboard, @fieldParentPtr("modifiers", listener)));
        keyboard.manager.current_modifiers = c.wlr_keyboard_get_modifiers(keyboard.keyboard);
        c.wlr_seat_set_keyboard(keyboard.manager.seat, keyboard.keyboard);
        c.wlr_seat_keyboard_notify_modifiers(keyboard.manager.seat, &keyboard.keyboard.*.modifiers);
    }

    fn handleKey(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const keyboard: *Keyboard = @ptrCast(@as(*allowzero Keyboard, @fieldParentPtr("key", listener)));
        const raw_event = data orelse return;
        const event: *c.struct_wlr_keyboard_key_event = @ptrCast(@alignCast(raw_event));

        const translated_keycode = event.keycode + 8;
        var syms: [*c]const c.xkb_keysym_t = undefined;
        const syms_len = c.xkb_state_key_get_syms(
            keyboard.keyboard.*.xkb_state,
            translated_keycode,
            &syms,
        );

        var handled = false;
        if (event.state == c.WL_KEYBOARD_KEY_STATE_PRESSED and syms_len > 0) {
            const modifiers = c.wlr_keyboard_get_modifiers(keyboard.keyboard);
            keyboard.manager.current_modifiers = modifiers;
            const slice = syms[0..@intCast(syms_len)];
            for (slice) |sym| {
                if (keyboard.manager.shortcut_cb) |callback| {
                    if (callback(keyboard.manager.shortcut_ctx, modifiers, sym)) {
                        handled = true;
                        break;
                    }
                }
                if (sym == c.XKB_KEY_Escape) {
                    log.info("Escape pressed, terminating Axia-DE", .{});
                    c.wl_display_terminate(keyboard.manager.display);
                    handled = true;
                    break;
                }
            }
        }

        if (event.state == c.WL_KEYBOARD_KEY_STATE_RELEASED) {
            keyboard.manager.current_modifiers = c.wlr_keyboard_get_modifiers(keyboard.keyboard);
        }

        if (!handled) {
            c.wlr_seat_set_keyboard(keyboard.manager.seat, keyboard.keyboard);
            c.wlr_seat_keyboard_notify_key(
                keyboard.manager.seat,
                event.time_msec,
                event.keycode,
                event.state,
            );
        }
    }
};

pub const InputManager = struct {
    allocator: std.mem.Allocator,
    display: *c.struct_wl_display,
    seat: [*c]c.struct_wlr_seat,
    keyboards: std.ArrayListUnmanaged(*Keyboard) = .empty,
    pointer: PointerManager,
    current_modifiers: u32 = 0,
    new_input: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    listeners_ready: bool = false,
    shortcut_ctx: ?*anyopaque = null,
    shortcut_cb: ?ShortcutCallback = null,

    pub fn init(
        allocator: std.mem.Allocator,
        display: *c.struct_wl_display,
        output_layout: [*c]c.struct_wlr_output_layout,
    ) !InputManager {
        const seat = c.wlr_seat_create(display, "seat0");
        if (seat == null) {
            return error.SeatCreateFailed;
        }

        var pointer = try PointerManager.init(allocator, seat, output_layout);
        errdefer pointer.deinit();

        return .{
            .allocator = allocator,
            .display = display,
            .seat = seat,
            .pointer = pointer,
        };
    }

    pub fn setupListeners(self: *InputManager, backend: [*c]c.struct_wlr_backend) void {
        self.new_input.notify = handleNewInput;
        c.wl_signal_add(&backend.*.events.new_input, &self.new_input);
        self.listeners_ready = true;
        self.pointer.setCapabilitiesNotifier(self, capabilitiesChanged);
        self.pointer.setupListeners();
    }

    pub fn setPointerCallbacks(
        self: *InputManager,
        ctx: ?*anyopaque,
        motion_callback: MotionCallback,
        button_callback: ButtonCallback,
    ) void {
        self.pointer.setEventCallbacks(ctx, motion_callback, button_callback);
    }

    pub fn setShortcutHandler(
        self: *InputManager,
        ctx: ?*anyopaque,
        callback: ShortcutCallback,
    ) void {
        self.shortcut_ctx = ctx;
        self.shortcut_cb = callback;
    }

    pub fn currentModifiers(self: *const InputManager) u32 {
        return self.current_modifiers;
    }

    pub fn deinit(self: *InputManager) void {
        if (self.listeners_ready) {
            c.wl_list_remove(&self.new_input.link);
        }

        for (self.keyboards.items) |keyboard| {
            c.wl_list_remove(&keyboard.key.link);
            c.wl_list_remove(&keyboard.modifiers.link);
            c.wl_list_remove(&keyboard.destroy.link);
            self.allocator.destroy(keyboard);
        }
        self.keyboards.deinit(self.allocator);

        self.pointer.deinit();
        c.wlr_seat_destroy(self.seat);
    }

    fn handleNewInput(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const manager: *InputManager = @ptrCast(@as(*allowzero InputManager, @fieldParentPtr("new_input", listener)));
        const raw_device = data orelse return;
        const device: [*c]c.struct_wlr_input_device = @ptrCast(@alignCast(raw_device));

        if (device.*.type == c.WLR_INPUT_DEVICE_KEYBOARD) {
            manager.registerKeyboard(device) catch |err| {
                log.err("failed to register keyboard: {}", .{err});
            };
        } else if (device.*.type == c.WLR_INPUT_DEVICE_POINTER) {
            manager.registerPointer(device) catch |err| {
                log.err("failed to register pointer: {}", .{err});
            };
        }

        manager.updateCapabilities();
    }

    fn registerKeyboard(self: *InputManager, device: [*c]c.struct_wlr_input_device) !void {
        const keyboard = try Keyboard.init(self, device);
        errdefer self.allocator.destroy(keyboard);

        try self.keyboards.append(self.allocator, keyboard);
        log.info("keyboard connected: {s}", .{std.mem.span(device.*.name)});
    }

    fn unregisterKeyboard(self: *InputManager, target: *Keyboard) void {
        for (self.keyboards.items, 0..) |keyboard, index| {
            if (keyboard == target) {
                _ = self.keyboards.swapRemove(index);
                break;
            }
        }
        self.updateCapabilities();
    }

    fn updateCapabilities(self: *InputManager) void {
        var caps: u32 = 0;
        if (self.keyboards.items.len > 0) {
            caps |= c.WL_SEAT_CAPABILITY_KEYBOARD;
        }
        if (self.pointer.count() > 0) {
            caps |= c.WL_SEAT_CAPABILITY_POINTER;
        }
        c.wlr_seat_set_capabilities(self.seat, caps);
    }

    fn registerPointer(self: *InputManager, device: [*c]c.struct_wlr_input_device) !void {
        try self.pointer.registerPointer(device);
    }

    fn capabilitiesChanged(ctx: ?*anyopaque) void {
        const raw_manager = ctx orelse return;
        const manager: *InputManager = @ptrCast(@alignCast(raw_manager));
        manager.updateCapabilities();
    }
};
