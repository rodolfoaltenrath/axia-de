const std = @import("std");
const c = @import("../wl.zig").c;
const Output = @import("../core/output.zig").Output;

pub const LayoutAppliedCallback = *const fn (?*anyopaque) void;

const log = std.log.scoped(.axia_output_management);

pub const Manager = struct {
    backend: [*c]c.struct_wlr_backend,
    output_layout: [*c]c.struct_wlr_output_layout,
    manager: [*c]c.struct_wlr_output_manager_v1,
    ctx: ?*anyopaque = null,
    layout_applied_cb: ?LayoutAppliedCallback = null,
    apply: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    test_listener: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    listeners_ready: bool = false,

    pub fn init(
        display: *c.struct_wl_display,
        backend: [*c]c.struct_wlr_backend,
        output_layout: [*c]c.struct_wlr_output_layout,
    ) !Manager {
        const manager = c.wlr_output_manager_v1_create(display);
        if (manager == null) return error.OutputManagerCreateFailed;

        var self = Manager{
            .backend = backend,
            .output_layout = output_layout,
            .manager = manager,
        };
        self.apply.notify = handleApply;
        self.test_listener.notify = handleTest;
        c.wl_signal_add(&manager.*.events.apply, &self.apply);
        c.wl_signal_add(&manager.*.events.@"test", &self.test_listener);
        self.listeners_ready = true;
        return self;
    }

    pub fn setLayoutAppliedCallback(
        self: *Manager,
        ctx: ?*anyopaque,
        callback: LayoutAppliedCallback,
    ) void {
        self.ctx = ctx;
        self.layout_applied_cb = callback;
    }

    pub fn publishCurrentConfiguration(self: *Manager, outputs: []const *Output) !void {
        const config = c.wlr_output_configuration_v1_create() orelse {
            return error.OutputConfigurationCreateFailed;
        };
        errdefer c.wlr_output_configuration_v1_destroy(config);

        for (outputs) |output| {
            const head = c.wlr_output_configuration_head_v1_create(config, output.wlr_output) orelse {
                return error.OutputConfigurationHeadCreateFailed;
            };

            if (c.wlr_output_layout_get(self.output_layout, output.wlr_output)) |layout_output| {
                head.*.state.enabled = output.wlr_output.*.enabled;
                head.*.state.x = layout_output.*.x;
                head.*.state.y = layout_output.*.y;
            } else {
                head.*.state.enabled = false;
            }
        }

        c.wlr_output_manager_v1_set_configuration(self.manager, config);
    }

    pub fn deinit(self: *Manager) void {
        if (self.listeners_ready) {
            c.wl_list_remove(&self.test_listener.link);
            c.wl_list_remove(&self.apply.link);
        }
    }

    fn handleApply(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const self: *Manager = @ptrCast(@as(*allowzero Manager, @fieldParentPtr("apply", listener)));
        const raw_config = data orelse return;
        const config: [*c]c.struct_wlr_output_configuration_v1 = @ptrCast(@alignCast(raw_config));
        self.handleConfiguration(config, true);
    }

    fn handleTest(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const self: *Manager = @ptrCast(@as(*allowzero Manager, @fieldParentPtr("test_listener", listener)));
        const raw_config = data orelse return;
        const config: [*c]c.struct_wlr_output_configuration_v1 = @ptrCast(@alignCast(raw_config));
        self.handleConfiguration(config, false);
    }

    fn handleConfiguration(self: *Manager, config: [*c]c.struct_wlr_output_configuration_v1, commit: bool) void {
        var states_len: usize = 0;
        const states = c.wlr_output_configuration_v1_build_state(config, &states_len);
        if (states == null) {
            c.wlr_output_configuration_v1_send_failed(config);
            c.wlr_output_configuration_v1_destroy(config);
            return;
        }
        defer {
            var index: usize = 0;
            while (index < states_len) : (index += 1) {
                c.wlr_output_state_finish(&states[index].base);
            }
            c.free(states);
        }

        const tested = c.wlr_backend_test(self.backend, states, states_len);
        if (!tested) {
            c.wlr_output_configuration_v1_send_failed(config);
            c.wlr_output_configuration_v1_destroy(config);
            return;
        }

        if (commit and !c.wlr_backend_commit(self.backend, states, states_len)) {
            c.wlr_output_configuration_v1_send_failed(config);
            c.wlr_output_configuration_v1_destroy(config);
            return;
        }

        if (commit) {
            self.applyLayoutChanges(config);
            if (self.layout_applied_cb) |callback| {
                callback(self.ctx);
            }
        }

        c.wlr_output_configuration_v1_send_succeeded(config);
        c.wlr_output_configuration_v1_destroy(config);
    }

    fn applyLayoutChanges(self: *Manager, config: [*c]c.struct_wlr_output_configuration_v1) void {
        var link = config.*.heads.next;
        while (link != &config.*.heads) {
            const head: *c.struct_wlr_output_configuration_head_v1 =
                @ptrCast(@alignCast(@as(
                    *allowzero c.struct_wlr_output_configuration_head_v1,
                    @fieldParentPtr("link", link),
                )));
            link = link.*.next;

            if (head.state.output == null) continue;
            if (head.state.enabled) {
                _ = c.wlr_output_layout_add(
                    self.output_layout,
                    head.state.output,
                    head.state.x,
                    head.state.y,
                );
            } else {
                c.wlr_output_layout_remove(self.output_layout, head.state.output);
            }
        }

        log.info("output layout updated via output-management", .{});
    }
};
