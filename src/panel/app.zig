const std = @import("std");
const c = @import("wl.zig").c;
const buffer_mod = @import("buffer.zig");
const calendar = @import("calendar.zig");
const ipc = @import("ipc.zig");
const launcher = @import("launcher.zig");
const render = @import("render.zig");
const workspaces = @import("workspaces.zig");

const log = std.log.scoped(.axia_panel);
const default_output_width: u32 = 1366;

const SurfaceRole = enum {
    panel,
    clock_popup,
    launcher_popup,
    workspace_popup,
};

const SurfaceState = struct {
    role: SurfaceRole,
    wl_surface: ?*c.struct_wl_surface = null,
    layer_surface: ?*c.struct_zwlr_layer_surface_v1 = null,
    width: u32 = 0,
    height: u32 = 0,
    configured: bool = false,
    mapped: bool = false,
    buffer: ?buffer_mod.ShmBuffer = null,
    dirty: bool = false,
    layer_listener: c.struct_zwlr_layer_surface_v1_listener = undefined,
    surface_listener: c.struct_wl_surface_listener = undefined,
    logged_configure: bool = false,
    logged_draw: bool = false,

    fn destroy(self: *SurfaceState) void {
        if (self.buffer) |*buffer| {
            buffer.deinit();
            self.buffer = null;
        }
        if (self.layer_surface) |layer_surface| {
            c.zwlr_layer_surface_v1_destroy(layer_surface);
            self.layer_surface = null;
        }
        if (self.wl_surface) |wl_surface| {
            c.wl_surface_destroy(wl_surface);
            self.wl_surface = null;
        }
        self.configured = false;
        self.mapped = false;
    }
};

pub const App = struct {
    allocator: std.mem.Allocator,
    display: *c.struct_wl_display,
    registry: *c.struct_wl_registry,
    compositor: ?*c.struct_wl_compositor = null,
    shm: ?*c.struct_wl_shm = null,
    layer_shell: ?*c.struct_zwlr_layer_shell_v1 = null,
    seat: ?*c.struct_wl_seat = null,
    pointer: ?*c.struct_wl_pointer = null,
    output_name: ?[]u8 = null,
    ipc_socket_path: ?[]u8 = null,
    running: bool = true,
    clock_popup_visible: bool = false,
    launcher_popup_visible: bool = false,
    workspace_popup_visible: bool = false,
    now: calendar.DateTime = .{ .tm = std.mem.zeroes(c.struct_tm) },
    displayed_minute_stamp: i64 = 0,
    month_cursor: calendar.MonthCursor = .{ .year = 1970, .month = 1 },
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    pointer_role: ?SurfaceRole = null,
    panel_hovered: render.HoverTarget = .none,
    panel: SurfaceState = .{ .role = .panel },
    popup: SurfaceState = .{ .role = .clock_popup },
    launcher_popup: SurfaceState = .{ .role = .launcher_popup },
    workspace_popup: SurfaceState = .{ .role = .workspace_popup },
    workspace_state: ipc.WorkspaceState = .{},
    registry_listener: c.struct_wl_registry_listener = undefined,
    seat_listener: c.struct_wl_seat_listener = undefined,
    pointer_listener: c.struct_wl_pointer_listener = undefined,

    const panel_height: u32 = 40;
    const popup_width: u32 = 376;
    const popup_height: u32 = 442;

    pub fn create(allocator: std.mem.Allocator) !*App {
        const app = try allocator.create(App);
        errdefer allocator.destroy(app);

        _ = c.setlocale(c.LC_TIME, "");

        const display = c.wl_display_connect(null) orelse return error.WaylandConnectFailed;
        errdefer c.wl_display_disconnect(display);

        const registry = c.wl_display_get_registry(display) orelse return error.RegistryGetFailed;

        app.* = .{
            .allocator = allocator,
            .display = display,
            .registry = registry,
        };
        app.ipc_socket_path = std.process.getEnvVarOwned(allocator, "AXIA_IPC_SOCKET") catch null;
        app.now = calendar.DateTime.now();
        app.displayed_minute_stamp = app.now.minuteStamp();
        app.month_cursor = .{
            .year = app.now.year(),
            .month = app.now.month(),
        };

        app.registry_listener = .{
            .global = handleGlobal,
            .global_remove = handleGlobalRemove,
        };
        _ = c.wl_registry_add_listener(registry, &app.registry_listener, app);

        if (c.wl_display_roundtrip(display) < 0) return error.RoundtripFailed;
        if (c.wl_display_roundtrip(display) < 0) return error.RoundtripFailed;

        if (app.compositor == null or app.shm == null or app.layer_shell == null) {
            return error.RequiredGlobalsMissing;
        }

        try app.createPanelSurface();
        return app;
    }

    pub fn deinit(self: *App) void {
        self.workspace_popup.destroy();
        self.launcher_popup.destroy();
        self.popup.destroy();
        self.panel.destroy();

        if (self.pointer) |pointer| c.wl_pointer_destroy(pointer);
        if (self.seat) |seat| c.wl_seat_destroy(seat);
        if (self.layer_shell) |layer_shell| c.zwlr_layer_shell_v1_destroy(layer_shell);
        if (self.shm) |shm| c.wl_shm_destroy(shm);
        if (self.compositor) |compositor| c.wl_compositor_destroy(compositor);
        c.wl_registry_destroy(self.registry);
        c.wl_display_disconnect(self.display);
        if (self.ipc_socket_path) |socket_path| self.allocator.free(socket_path);
        if (self.output_name) |name| self.allocator.free(name);
    }

    pub fn destroy(self: *App) void {
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }

    pub fn run(self: *App) !void {
        while (self.running) {
            self.tickClock();
            try self.redrawIfNeeded();

            if (c.wl_display_dispatch_pending(self.display) < 0) {
                return error.DisplayDispatchFailed;
            }
            if (c.wl_display_flush(self.display) < 0) {
                return error.DisplayFlushFailed;
            }

            const fd = c.wl_display_get_fd(self.display);
            var pollfd = c.struct_pollfd{
                .fd = fd,
                .events = c.POLLIN,
                .revents = 0,
            };

            const timeout_ms: c_int = 1000;
            const result = c.poll(&pollfd, 1, timeout_ms);
            if (result < 0 and std.posix.errno(result) != .INTR) {
                return error.PollFailed;
            }
            if (result > 0 and (pollfd.revents & c.POLLIN) != 0) {
                if (c.wl_display_dispatch(self.display) < 0) {
                    return error.DisplayDispatchFailed;
                }
            }
        }
    }

    fn createPanelSurface(self: *App) !void {
        const compositor = self.compositor orelse return error.CompositorMissing;
        const layer_shell = self.layer_shell orelse return error.LayerShellMissing;

        const wl_surface = c.wl_compositor_create_surface(compositor) orelse return error.SurfaceCreateFailed;
        errdefer c.wl_surface_destroy(wl_surface);

        const layer_surface = c.zwlr_layer_shell_v1_get_layer_surface(
            layer_shell,
            wl_surface,
            null,
            c.ZWLR_LAYER_SHELL_V1_LAYER_TOP,
            "axia-panel",
        ) orelse return error.LayerSurfaceCreateFailed;

        c.zwlr_layer_surface_v1_set_anchor(
            layer_surface,
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
                c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
                c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT,
        );
        c.zwlr_layer_surface_v1_set_size(layer_surface, 0, panel_height);
        c.zwlr_layer_surface_v1_set_exclusive_zone(layer_surface, panel_height);
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(
            layer_surface,
            c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE,
        );

        self.panel.wl_surface = wl_surface;
        self.panel.layer_surface = layer_surface;
        self.panel.dirty = true;
        self.installSurfaceListeners(&self.panel);
        log.info("panel surface requested", .{});

        c.wl_surface_commit(wl_surface);
    }

    fn createClockPopup(self: *App) !void {
        if (self.popup.layer_surface != null) return;

        const compositor = self.compositor orelse return error.CompositorMissing;
        const layer_shell = self.layer_shell orelse return error.LayerShellMissing;

        const wl_surface = c.wl_compositor_create_surface(compositor) orelse return error.SurfaceCreateFailed;
        errdefer c.wl_surface_destroy(wl_surface);

        const layer_surface = c.zwlr_layer_shell_v1_get_layer_surface(
            layer_shell,
            wl_surface,
            null,
            c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
            "axia-panel-clock",
        ) orelse return error.LayerSurfaceCreateFailed;

        c.zwlr_layer_surface_v1_set_anchor(layer_surface, c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP);
        c.zwlr_layer_surface_v1_set_margin(layer_surface, panel_height + 8, 0, 0, 0);
        c.zwlr_layer_surface_v1_set_size(layer_surface, popup_width, popup_height);
        c.zwlr_layer_surface_v1_set_exclusive_zone(layer_surface, 0);
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(
            layer_surface,
            c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE,
        );

        self.popup.wl_surface = wl_surface;
        self.popup.layer_surface = layer_surface;
        self.popup.dirty = true;
        self.installSurfaceListeners(&self.popup);

        c.wl_surface_commit(wl_surface);
    }

    fn destroyClockPopup(self: *App) void {
        self.popup.destroy();
    }

    fn createWorkspacePopup(self: *App) !void {
        if (self.workspace_popup.layer_surface != null) return;

        const compositor = self.compositor orelse return error.CompositorMissing;
        const layer_shell = self.layer_shell orelse return error.LayerShellMissing;

        const wl_surface = c.wl_compositor_create_surface(compositor) orelse return error.SurfaceCreateFailed;
        errdefer c.wl_surface_destroy(wl_surface);

        const layer_surface = c.zwlr_layer_shell_v1_get_layer_surface(
            layer_shell,
            wl_surface,
            null,
            c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
            "axia-panel-workspaces",
        ) orelse return error.LayerSurfaceCreateFailed;

        c.zwlr_layer_surface_v1_set_anchor(
            layer_surface,
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT,
        );
        c.zwlr_layer_surface_v1_set_margin(layer_surface, panel_height + 8, 0, 0, 16);
        c.zwlr_layer_surface_v1_set_size(layer_surface, workspaces.popup_width, workspaces.popup_height);
        c.zwlr_layer_surface_v1_set_exclusive_zone(layer_surface, 0);
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(
            layer_surface,
            c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE,
        );

        self.workspace_popup.wl_surface = wl_surface;
        self.workspace_popup.layer_surface = layer_surface;
        self.workspace_popup.dirty = true;
        self.installSurfaceListeners(&self.workspace_popup);

        c.wl_surface_commit(wl_surface);
    }

    fn destroyWorkspacePopup(self: *App) void {
        self.workspace_popup.destroy();
    }

    fn createLauncherPopup(self: *App) !void {
        if (self.launcher_popup.layer_surface != null) return;

        const compositor = self.compositor orelse return error.CompositorMissing;
        const layer_shell = self.layer_shell orelse return error.LayerShellMissing;

        const wl_surface = c.wl_compositor_create_surface(compositor) orelse return error.SurfaceCreateFailed;
        errdefer c.wl_surface_destroy(wl_surface);

        const layer_surface = c.zwlr_layer_shell_v1_get_layer_surface(
            layer_shell,
            wl_surface,
            null,
            c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
            "axia-panel-launcher",
        ) orelse return error.LayerSurfaceCreateFailed;

        c.zwlr_layer_surface_v1_set_anchor(
            layer_surface,
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT,
        );
        c.zwlr_layer_surface_v1_set_margin(layer_surface, panel_height + 8, 0, 0, 16);
        c.zwlr_layer_surface_v1_set_size(layer_surface, launcher.popup_width, launcher.popup_height);
        c.zwlr_layer_surface_v1_set_exclusive_zone(layer_surface, 0);
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(
            layer_surface,
            c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE,
        );

        self.launcher_popup.wl_surface = wl_surface;
        self.launcher_popup.layer_surface = layer_surface;
        self.launcher_popup.dirty = true;
        self.installSurfaceListeners(&self.launcher_popup);

        c.wl_surface_commit(wl_surface);
    }

    fn destroyLauncherPopup(self: *App) void {
        self.launcher_popup.destroy();
    }

    fn installSurfaceListeners(self: *App, surface: *SurfaceState) void {
        _ = self;
        surface.layer_listener = .{
            .configure = handleLayerConfigure,
            .closed = handleLayerClosed,
        };
        surface.surface_listener = .{
            .enter = handleSurfaceEnter,
            .leave = handleSurfaceLeave,
            .preferred_buffer_scale = handlePreferredBufferScale,
            .preferred_buffer_transform = handlePreferredBufferTransform,
        };
        _ = c.zwlr_layer_surface_v1_add_listener(surface.layer_surface.?, &surface.layer_listener, surface);
        _ = c.wl_surface_add_listener(surface.wl_surface.?, &surface.surface_listener, surface);
    }

    fn redrawIfNeeded(self: *App) !void {
        if (self.panel.dirty) try self.drawSurface(&self.panel);
        if (self.clock_popup_visible and self.popup.dirty) try self.drawSurface(&self.popup);
        if (self.launcher_popup_visible and self.launcher_popup.dirty) try self.drawSurface(&self.launcher_popup);
        if (self.workspace_popup_visible and self.workspace_popup.dirty) try self.drawSurface(&self.workspace_popup);
    }

    fn drawSurface(self: *App, surface: *SurfaceState) !void {
        const shm = self.shm orelse return error.ShmMissing;
        if (!surface.configured or surface.width == 0 or surface.height == 0) return;

        if (surface.buffer) |*buffer| {
            if (buffer.width != surface.width or buffer.height != surface.height) {
                buffer.deinit();
                surface.buffer = null;
            }
        }

        if (surface.buffer == null) {
            surface.buffer = try buffer_mod.ShmBuffer.init(shm, surface.width, surface.height);
        }

        const buffer = &surface.buffer.?;
        switch (surface.role) {
            .panel => render.drawPanel(buffer.cr, surface.width, surface.height, self.now, self.panel_hovered),
            .clock_popup => render.drawCalendarPopup(buffer.cr, surface.width, surface.height, self.month_cursor, self.now),
            .launcher_popup => launcher.drawPopup(buffer.cr, surface.width, surface.height),
            .workspace_popup => workspaces.drawPopup(buffer.cr, surface.width, surface.height, self.workspace_state),
        }

        c.cairo_surface_flush(buffer.surface);
        c.wl_surface_attach(surface.wl_surface.?, buffer.buffer, 0, 0);
        c.wl_surface_damage_buffer(surface.wl_surface.?, 0, 0, @intCast(surface.width), @intCast(surface.height));
        c.wl_surface_commit(surface.wl_surface.?);
        surface.dirty = false;
        if (!surface.logged_draw) {
            surface.logged_draw = true;
            log.info("drawn {s} surface at {}x{}", .{
                switch (surface.role) {
                    .panel => "panel",
                    .clock_popup => "clock-popup",
                    .launcher_popup => "launcher-popup",
                    .workspace_popup => "workspace-popup",
                },
                surface.width,
                surface.height,
            });
        }
    }

    fn tickClock(self: *App) void {
        const now = calendar.DateTime.now();
        const new_stamp = now.minuteStamp();
        if (new_stamp == self.displayed_minute_stamp) return;

        self.now = now;
        self.displayed_minute_stamp = new_stamp;
        self.panel.dirty = true;
        if (self.clock_popup_visible) self.popup.dirty = true;
        if (self.launcher_popup_visible) self.launcher_popup.dirty = true;
        if (self.workspace_popup_visible) self.workspace_popup.dirty = true;
    }

    fn setSeat(self: *App, seat: *c.struct_wl_seat) void {
        self.seat = seat;
        self.seat_listener = .{
            .capabilities = handleSeatCapabilities,
            .name = handleSeatName,
        };
        _ = c.wl_seat_add_listener(seat, &self.seat_listener, self);
    }

    fn handleClick(self: *App, button: u32, x: f64, y: f64) void {
        if (self.pointer_role == .workspace_popup and self.workspace_popup_visible) {
            if (workspaces.hitTest(x, y, self.workspace_state.count)) |index| {
                if (button == 0x112) {
                    self.moveFocusedToWorkspace(index);
                } else {
                    self.activateWorkspace(index);
                }
                self.toggleWorkspacePopup();
            }
            return;
        }

        if (self.pointer_role == .clock_popup and self.clock_popup_visible) {
            const popup_metrics = render.popupMetrics(popup_width, popup_height);
            if (popup_metrics.prev_month.contains(x, y)) {
                self.month_cursor.previous();
                self.popup.dirty = true;
                return;
            }
            if (popup_metrics.next_month.contains(x, y)) {
                self.month_cursor.next();
                self.popup.dirty = true;
                return;
            }
            return;
        }

        if (self.pointer_role == .launcher_popup and self.launcher_popup_visible) {
            if (launcher.hitTest(x, y)) |index| {
                self.spawnCommand(launcher.entries[index].command) catch |err| {
                    log.err("failed to launch app: {}", .{err});
                };
                self.toggleLauncherPopup();
            }
            return;
        }

        const metrics = render.computePanelMetrics(self.panel.width, panel_height);
        if (metrics.clock.contains(x, y)) {
            self.toggleClockPopup();
            return;
        }
        if (metrics.apps.contains(x, y)) {
            self.toggleLauncherPopup();
            return;
        }
        if (metrics.workspaces.contains(x, y)) {
            self.toggleWorkspacePopup();
            return;
        }

        if (self.pointer_role == .panel) {
            if (self.clock_popup_visible) self.toggleClockPopup();
            if (self.launcher_popup_visible) self.toggleLauncherPopup();
            if (self.workspace_popup_visible) self.toggleWorkspacePopup();
        }
    }

    fn toggleClockPopup(self: *App) void {
        if (!self.clock_popup_visible) self.closeOtherPopups(.clock_popup);
        self.clock_popup_visible = !self.clock_popup_visible;
        if (self.clock_popup_visible) {
            self.month_cursor = calendar.MonthCursor.initNow();
            self.createClockPopup() catch |err| {
                self.clock_popup_visible = false;
                log.err("failed to create clock popup: {}", .{err});
                return;
            };
            self.popup.dirty = true;
        } else {
            self.destroyClockPopup();
        }
    }

    fn toggleLauncherPopup(self: *App) void {
        if (!self.launcher_popup_visible) self.closeOtherPopups(.launcher_popup);
        self.launcher_popup_visible = !self.launcher_popup_visible;
        if (self.launcher_popup_visible) {
            self.createLauncherPopup() catch |err| {
                self.launcher_popup_visible = false;
                log.err("failed to create launcher popup: {}", .{err});
                return;
            };
            self.launcher_popup.dirty = true;
        } else {
            self.destroyLauncherPopup();
        }
    }

    fn toggleWorkspacePopup(self: *App) void {
        if (!self.workspace_popup_visible) self.closeOtherPopups(.workspace_popup);
        self.workspace_popup_visible = !self.workspace_popup_visible;
        if (self.workspace_popup_visible) {
            self.refreshWorkspaceState();
            self.createWorkspacePopup() catch |err| {
                self.workspace_popup_visible = false;
                log.err("failed to create workspace popup: {}", .{err});
                return;
            };
            self.workspace_popup.dirty = true;
        } else {
            self.destroyWorkspacePopup();
        }
    }

    fn closeOtherPopups(self: *App, keep: SurfaceRole) void {
        if (keep != .clock_popup and self.clock_popup_visible) self.toggleClockPopup();
        if (keep != .launcher_popup and self.launcher_popup_visible) self.toggleLauncherPopup();
        if (keep != .workspace_popup and self.workspace_popup_visible) self.toggleWorkspacePopup();
    }

    fn spawnCommand(self: *App, command: []const u8) !void {
        const argv: []const []const u8 = &.{ "sh", "-lc", command };
        var child = std.process.Child.init(argv, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        try child.spawn();
    }

    fn refreshWorkspaceState(self: *App) void {
        const socket_path = self.ipc_socket_path orelse return;
        self.workspace_state = ipc.getWorkspaceState(self.allocator, socket_path) catch self.workspace_state;
    }

    fn updatePanelHover(self: *App) void {
        const new_hovered = if (self.pointer_role == .panel)
            render.panelHoverAt(self.panel.width, panel_height, self.pointer_x, self.pointer_y)
        else
            render.HoverTarget.none;

        if (new_hovered != self.panel_hovered) {
            self.panel_hovered = new_hovered;
            self.panel.dirty = true;
        }
    }

    fn activateWorkspace(self: *App, index: usize) void {
        const socket_path = self.ipc_socket_path orelse return;
        self.workspace_state = ipc.activateWorkspace(self.allocator, socket_path, index) catch self.workspace_state;
        self.workspace_popup.dirty = true;
    }

    fn moveFocusedToWorkspace(self: *App, index: usize) void {
        const socket_path = self.ipc_socket_path orelse return;
        self.workspace_state = ipc.moveFocusedToWorkspace(self.allocator, socket_path, index) catch self.workspace_state;
        self.workspace_popup.dirty = true;
    }

    fn handleGlobal(data: ?*anyopaque, registry: ?*c.struct_wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
        _ = registry;
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        const interface_name = std.mem.span(interface);

        if (std.mem.eql(u8, interface_name, std.mem.span(c.wl_compositor_interface.name))) {
            app.compositor = @ptrCast(c.wl_registry_bind(app.registry, name, &c.wl_compositor_interface, @min(version, 6)));
        } else if (std.mem.eql(u8, interface_name, std.mem.span(c.wl_shm_interface.name))) {
            app.shm = @ptrCast(c.wl_registry_bind(app.registry, name, &c.wl_shm_interface, 1));
        } else if (std.mem.eql(u8, interface_name, std.mem.span(c.wl_seat_interface.name))) {
            const seat: *c.struct_wl_seat = @ptrCast(c.wl_registry_bind(app.registry, name, &c.wl_seat_interface, @min(version, 5)));
            app.setSeat(seat);
        } else if (std.mem.eql(u8, interface_name, std.mem.span(c.zwlr_layer_shell_v1_interface.name))) {
            app.layer_shell = @ptrCast(c.wl_registry_bind(app.registry, name, &c.zwlr_layer_shell_v1_interface, @min(version, 4)));
        }
    }

    fn handleGlobalRemove(_: ?*anyopaque, _: ?*c.struct_wl_registry, _: u32) callconv(.c) void {}

    fn handleSeatCapabilities(data: ?*anyopaque, seat: ?*c.struct_wl_seat, capabilities: u32) callconv(.c) void {
        _ = seat;
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));

        if ((capabilities & c.WL_SEAT_CAPABILITY_POINTER) != 0 and app.pointer == null) {
            const wl_seat = app.seat orelse return;
            const pointer = c.wl_seat_get_pointer(wl_seat) orelse return;
            app.pointer = pointer;
            app.pointer_listener = .{
                .enter = handlePointerEnter,
                .leave = handlePointerLeave,
                .motion = handlePointerMotion,
                .button = handlePointerButton,
                .axis = handlePointerAxis,
                .frame = handlePointerFrame,
                .axis_source = handlePointerAxisSource,
                .axis_stop = handlePointerAxisStop,
                .axis_discrete = handlePointerAxisDiscrete,
                .axis_value120 = handlePointerAxisValue120,
                .axis_relative_direction = handlePointerAxisRelativeDirection,
            };
            _ = c.wl_pointer_add_listener(pointer, &app.pointer_listener, app);
        }
    }

    fn handleSeatName(_: ?*anyopaque, _: ?*c.struct_wl_seat, _: [*c]const u8) callconv(.c) void {}

    fn handleLayerConfigure(data: ?*anyopaque, layer_surface: ?*c.struct_zwlr_layer_surface_v1, serial: u32, width: u32, height: u32) callconv(.c) void {
        const raw_surface = data orelse return;
        const surface: *SurfaceState = @ptrCast(@alignCast(raw_surface));
        const zwlr_surface = layer_surface orelse return;

        c.zwlr_layer_surface_v1_ack_configure(zwlr_surface, serial);
        surface.width = if (width == 0) switch (surface.role) {
            .panel => default_output_width,
            .clock_popup => popup_width,
            .launcher_popup => launcher.popup_width,
            .workspace_popup => workspaces.popup_width,
        } else width;
        surface.height = if (height == 0) switch (surface.role) {
            .panel => panel_height,
            .clock_popup => popup_height,
            .launcher_popup => launcher.popup_height,
            .workspace_popup => workspaces.popup_height,
        } else height;
        surface.configured = true;
        surface.mapped = true;
        surface.dirty = true;
        if (!surface.logged_configure) {
            surface.logged_configure = true;
            log.info("configured {s} surface at {}x{}", .{
                switch (surface.role) {
                    .panel => "panel",
                    .clock_popup => "clock-popup",
                    .launcher_popup => "launcher-popup",
                    .workspace_popup => "workspace-popup",
                },
                surface.width,
                surface.height,
            });
        }
    }

    fn handleLayerClosed(data: ?*anyopaque, _: ?*c.struct_zwlr_layer_surface_v1) callconv(.c) void {
        const raw_surface = data orelse return;
        const surface: *SurfaceState = @ptrCast(@alignCast(raw_surface));
        surface.mapped = false;
        surface.configured = false;
    }

    fn handleSurfaceEnter(_: ?*anyopaque, _: ?*c.struct_wl_surface, _: ?*c.struct_wl_output) callconv(.c) void {}
    fn handleSurfaceLeave(_: ?*anyopaque, _: ?*c.struct_wl_surface, _: ?*c.struct_wl_output) callconv(.c) void {}
    fn handlePreferredBufferScale(_: ?*anyopaque, _: ?*c.struct_wl_surface, _: i32) callconv(.c) void {}
    fn handlePreferredBufferTransform(_: ?*anyopaque, _: ?*c.struct_wl_surface, _: u32) callconv(.c) void {}

    fn handlePointerEnter(data: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, surface: ?*c.struct_wl_surface, surface_x: c.wl_fixed_t, surface_y: c.wl_fixed_t) callconv(.c) void {
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        const wl_surface = surface orelse return;
        app.pointer_x = c.wl_fixed_to_double(surface_x);
        app.pointer_y = c.wl_fixed_to_double(surface_y);
        if (app.panel.wl_surface == wl_surface) {
            app.pointer_role = .panel;
        } else if (app.popup.wl_surface != null and app.popup.wl_surface.? == wl_surface) {
            app.pointer_role = .clock_popup;
        } else if (app.launcher_popup.wl_surface != null and app.launcher_popup.wl_surface.? == wl_surface) {
            app.pointer_role = .launcher_popup;
        } else if (app.workspace_popup.wl_surface != null and app.workspace_popup.wl_surface.? == wl_surface) {
            app.pointer_role = .workspace_popup;
        } else {
            app.pointer_role = null;
        }
        app.updatePanelHover();
    }

    fn handlePointerLeave(data: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: ?*c.struct_wl_surface) callconv(.c) void {
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        app.pointer_role = null;
        app.updatePanelHover();
    }
    fn handlePointerMotion(data: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, surface_x: c.wl_fixed_t, surface_y: c.wl_fixed_t) callconv(.c) void {
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        app.pointer_x = c.wl_fixed_to_double(surface_x);
        app.pointer_y = c.wl_fixed_to_double(surface_y);
        app.updatePanelHover();
    }

    fn handlePointerButton(data: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: u32, button: u32, state: u32) callconv(.c) void {
        if (state != c.WL_POINTER_BUTTON_STATE_PRESSED) return;
        if (button != 0x110 and button != 0x112) return;
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));

        app.handleClick(button, app.pointer_x, app.pointer_y);
    }

    fn handlePointerAxis(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: u32, _: c.wl_fixed_t) callconv(.c) void {}
    fn handlePointerFrame(_: ?*anyopaque, _: ?*c.struct_wl_pointer) callconv(.c) void {}
    fn handlePointerAxisSource(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32) callconv(.c) void {}
    fn handlePointerAxisStop(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: u32) callconv(.c) void {}
    fn handlePointerAxisDiscrete(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: i32) callconv(.c) void {}
    fn handlePointerAxisValue120(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: i32) callconv(.c) void {}
    fn handlePointerAxisRelativeDirection(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: u32) callconv(.c) void {}
};
