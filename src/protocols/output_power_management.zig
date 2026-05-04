const std = @import("std");
const c = @import("../wl.zig").c;

const log = std.log.scoped(.axia_output_power);

pub const ModeAppliedCallback = *const fn (?*anyopaque, [*c]c.struct_wlr_output, bool) void;

pub const Manager = struct {
    manager: [*c]c.struct_wlr_output_power_manager_v1,
    ctx: ?*anyopaque = null,
    mode_applied_cb: ?ModeAppliedCallback = null,
    set_mode: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    listeners_ready: bool = false,

    pub fn init(display: *c.struct_wl_display) !Manager {
        const manager = c.wlr_output_power_manager_v1_create(display);
        if (manager == null) return error.OutputPowerManagerCreateFailed;

        return .{
            .manager = manager,
        };
    }

    pub fn setupListeners(self: *Manager) void {
        self.set_mode.notify = handleSetMode;
        c.wl_signal_add(&self.manager.*.events.set_mode, &self.set_mode);
        self.listeners_ready = true;
    }

    pub fn setModeAppliedCallback(
        self: *Manager,
        ctx: ?*anyopaque,
        callback: ModeAppliedCallback,
    ) void {
        self.ctx = ctx;
        self.mode_applied_cb = callback;
    }

    pub fn deinit(self: *Manager) void {
        if (self.listeners_ready) {
            c.wl_list_remove(&self.set_mode.link);
        }
    }

    fn handleSetMode(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const self: *Manager = @ptrCast(@as(*allowzero Manager, @fieldParentPtr("set_mode", listener)));
        const raw_event = data orelse return;
        const event: *c.struct_wlr_output_power_v1_set_mode_event = @ptrCast(@alignCast(raw_event));
        const output = event.output;

        const enabled = switch (event.mode) {
            c.ZWLR_OUTPUT_POWER_V1_MODE_OFF => false,
            c.ZWLR_OUTPUT_POWER_V1_MODE_ON => true,
            else => {
                log.warn("ignoring unsupported output power mode {}", .{event.mode});
                return;
            },
        };

        var state = std.mem.zeroes(c.struct_wlr_output_state);
        c.wlr_output_state_init(&state);
        defer c.wlr_output_state_finish(&state);

        c.wlr_output_state_set_enabled(&state, enabled);

        if (!c.wlr_output_test_state(output, &state)) {
            log.warn(
                "output {s} rejected power mode {s} during test",
                .{ std.mem.span(output.*.name), if (enabled) "on" else "off" },
            );
            return;
        }

        if (!c.wlr_output_commit_state(output, &state)) {
            log.warn(
                "failed to commit output power mode {s} for {s}",
                .{ if (enabled) "on" else "off", std.mem.span(output.*.name) },
            );
            return;
        }

        log.info(
            "output {s} power mode set to {s}",
            .{ std.mem.span(output.*.name), if (enabled) "on" else "off" },
        );

        if (self.mode_applied_cb) |callback| {
            callback(self.ctx, output, enabled);
        }
    }
};
