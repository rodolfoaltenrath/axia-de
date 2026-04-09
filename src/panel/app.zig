const std = @import("std");
const audio = @import("audio.zig");
const audio_popup = @import("audio_popup.zig");
const battery = @import("battery.zig");
const battery_popup = @import("battery_popup.zig");
const bluetooth = @import("bluetooth.zig");
const bluetooth_popup = @import("bluetooth_popup.zig");
const network = @import("network.zig");
const network_popup = @import("network_popup.zig");
const notifications_popup = @import("notifications_popup.zig");
const power_popup = @import("power_popup.zig");
const toast_popup = @import("toast_popup.zig");
const c = @import("wl.zig").c;
const buffer_mod = @import("buffer.zig");
const calendar = @import("calendar.zig");
const ipc = @import("ipc.zig");
const launcher = @import("launcher.zig");
const render = @import("render.zig");
const workspaces = @import("workspaces.zig");
const launcher_state = @import("launcher_state");
const prefs = @import("axia_prefs");
const notification_client = @import("notification_client");
const settings_model = @import("settings_model");
const runtime_catalog = @import("runtime_catalog");
const notification_model = @import("notification_model");
const toast_model = @import("toast_model");

const log = std.log.scoped(.axia_panel);
const default_output_width: u32 = 1366;

const SurfaceRole = enum {
    panel,
    dismiss_overlay,
    clock_popup,
    notifications_popup,
    power_popup,
    battery_popup,
    network_popup,
    bluetooth_popup,
    audio_popup,
    launcher_popup,
    workspace_popup,
    toast_popup,
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
    power_popup_visible: bool = false,
    notifications_popup_visible: bool = false,
    battery_popup_visible: bool = false,
    network_popup_visible: bool = false,
    bluetooth_popup_visible: bool = false,
    audio_popup_visible: bool = false,
    launcher_popup_visible: bool = false,
    workspace_popup_visible: bool = false,
    now: calendar.DateTime = .{ .tm = std.mem.zeroes(c.struct_tm) },
    displayed_minute_stamp: i64 = 0,
    month_cursor: calendar.MonthCursor = .{ .year = 1970, .month = 1 },
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    pointer_role: ?SurfaceRole = null,
    panel_hovered: render.HoverTarget = .none,
    preferences: settings_model.PreferencesState = .{},
    audio_state: audio.State = .{},
    battery_state: battery.State = .{},
    network_state: network.State = .{},
    bluetooth_state: bluetooth.State = .{},
    notification_state: notification_model.State = .{},
    toast_state: toast_model.State = .{},
    last_audio_refresh_ms: i64 = 0,
    last_toast_refresh_ms: i64 = 0,
    last_notification_refresh_ms: i64 = 0,
    last_battery_refresh_ms: i64 = 0,
    last_network_refresh_ms: i64 = 0,
    last_bluetooth_refresh_ms: i64 = 0,
    panel: SurfaceState = .{ .role = .panel },
    dismiss_overlay: SurfaceState = .{ .role = .dismiss_overlay },
    popup: SurfaceState = .{ .role = .clock_popup },
    notifications_popup: SurfaceState = .{ .role = .notifications_popup },
    power_popup: SurfaceState = .{ .role = .power_popup },
    battery_popup: SurfaceState = .{ .role = .battery_popup },
    network_popup: SurfaceState = .{ .role = .network_popup },
    bluetooth_popup: SurfaceState = .{ .role = .bluetooth_popup },
    audio_popup: SurfaceState = .{ .role = .audio_popup },
    launcher_popup: SurfaceState = .{ .role = .launcher_popup },
    workspace_popup: SurfaceState = .{ .role = .workspace_popup },
    toast_popup: SurfaceState = .{ .role = .toast_popup },
    workspace_state: ipc.WorkspaceState = .{},
    catalog: runtime_catalog.Catalog,
    launcher_entries: std.ArrayListUnmanaged(runtime_catalog.AppEntry) = .empty,
    registry_listener: c.struct_wl_registry_listener = undefined,
    seat_listener: c.struct_wl_seat_listener = undefined,
    pointer_listener: c.struct_wl_pointer_listener = undefined,

    const panel_height: u32 = 40;
    const panel_popup_top_gap: u32 = 2;
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
            .catalog = runtime_catalog.Catalog.init(allocator),
        };
        app.ipc_socket_path = std.process.getEnvVarOwned(allocator, "AXIA_IPC_SOCKET") catch null;
        try app.catalog.loadDefault();
        try launcher_state.ensureDefaultFavorites(allocator, &app.catalog);
        app.launcher_entries = try launcher_state.loadFavoriteEntries(allocator, &app.catalog);
        app.now = calendar.DateTime.now();
        app.displayed_minute_stamp = app.now.minuteStamp();
        app.month_cursor = .{
            .year = app.now.year(),
            .month = app.now.month(),
        };
        _ = app.refreshPreferences();
        _ = audio.refresh(allocator, &app.audio_state);
        _ = battery.refresh(allocator, &app.battery_state);
        _ = network.refresh(allocator, &app.network_state);
        _ = bluetooth.refresh(allocator, &app.bluetooth_state);
        app.last_audio_refresh_ms = std.time.milliTimestamp();
        app.last_toast_refresh_ms = app.last_audio_refresh_ms;
        app.last_notification_refresh_ms = app.last_audio_refresh_ms;
        app.last_battery_refresh_ms = app.last_audio_refresh_ms;
        app.last_network_refresh_ms = app.last_audio_refresh_ms;
        app.last_bluetooth_refresh_ms = app.last_audio_refresh_ms;

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
        self.toast_popup.destroy();
        self.notifications_popup.destroy();
        self.power_popup.destroy();
        self.battery_popup.destroy();
        self.network_popup.destroy();
        self.bluetooth_popup.destroy();
        self.audio_popup.destroy();
        self.popup.destroy();
        self.dismiss_overlay.destroy();
        self.panel.destroy();

        if (self.pointer) |pointer| c.wl_pointer_destroy(pointer);
        if (self.seat) |seat| c.wl_seat_destroy(seat);
        if (self.layer_shell) |layer_shell| c.zwlr_layer_shell_v1_destroy(layer_shell);
        if (self.shm) |shm| c.wl_shm_destroy(shm);
        if (self.compositor) |compositor| c.wl_compositor_destroy(compositor);
        self.launcher_entries.deinit(self.allocator);
        self.catalog.deinit();
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
            self.tickBattery();
            self.tickNetwork();
            self.tickBluetooth();
            self.tickAudio();
            self.tickToasts();
            self.tickNotifications();
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
        try self.ensureDismissOverlay();

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
        c.zwlr_layer_surface_v1_set_margin(layer_surface, panel_popup_top_gap, 0, 0, 0);
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

    fn createNotificationsPopup(self: *App) !void {
        if (self.notifications_popup.layer_surface != null) return;
        try self.ensureDismissOverlay();

        const compositor = self.compositor orelse return error.CompositorMissing;
        const layer_shell = self.layer_shell orelse return error.LayerShellMissing;

        const wl_surface = c.wl_compositor_create_surface(compositor) orelse return error.SurfaceCreateFailed;
        errdefer c.wl_surface_destroy(wl_surface);

        const layer_surface = c.zwlr_layer_shell_v1_get_layer_surface(
            layer_shell,
            wl_surface,
            null,
            c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
            "axia-panel-notifications",
        ) orelse return error.LayerSurfaceCreateFailed;

        c.zwlr_layer_surface_v1_set_anchor(
            layer_surface,
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT,
        );
        c.zwlr_layer_surface_v1_set_margin(layer_surface, panel_popup_top_gap, 182, 0, 0);
        c.zwlr_layer_surface_v1_set_size(layer_surface, notifications_popup.popup_width, notifications_popup.popup_height);
        c.zwlr_layer_surface_v1_set_exclusive_zone(layer_surface, 0);
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(
            layer_surface,
            c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE,
        );

        self.notifications_popup.wl_surface = wl_surface;
        self.notifications_popup.layer_surface = layer_surface;
        self.notifications_popup.dirty = true;
        self.installSurfaceListeners(&self.notifications_popup);

        c.wl_surface_commit(wl_surface);
    }

    fn destroyNotificationsPopup(self: *App) void {
        self.notifications_popup.destroy();
    }

    fn createPowerPopup(self: *App) !void {
        if (self.power_popup.layer_surface != null) return;
        try self.ensureDismissOverlay();

        const compositor = self.compositor orelse return error.CompositorMissing;
        const layer_shell = self.layer_shell orelse return error.LayerShellMissing;

        const wl_surface = c.wl_compositor_create_surface(compositor) orelse return error.SurfaceCreateFailed;
        errdefer c.wl_surface_destroy(wl_surface);

        const layer_surface = c.zwlr_layer_shell_v1_get_layer_surface(
            layer_shell,
            wl_surface,
            null,
            c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
            "axia-panel-power",
        ) orelse return error.LayerSurfaceCreateFailed;

        c.zwlr_layer_surface_v1_set_anchor(
            layer_surface,
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT,
        );
        c.zwlr_layer_surface_v1_set_margin(layer_surface, panel_popup_top_gap, 8, 0, 0);
        c.zwlr_layer_surface_v1_set_size(layer_surface, power_popup.popup_width, power_popup.popup_height);
        c.zwlr_layer_surface_v1_set_exclusive_zone(layer_surface, 0);
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(
            layer_surface,
            c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE,
        );

        self.power_popup.wl_surface = wl_surface;
        self.power_popup.layer_surface = layer_surface;
        self.power_popup.dirty = true;
        self.installSurfaceListeners(&self.power_popup);

        c.wl_surface_commit(wl_surface);
    }

    fn destroyPowerPopup(self: *App) void {
        self.power_popup.destroy();
    }

    fn createBatteryPopup(self: *App) !void {
        if (self.battery_popup.layer_surface != null) return;
        try self.ensureDismissOverlay();

        const compositor = self.compositor orelse return error.CompositorMissing;
        const layer_shell = self.layer_shell orelse return error.LayerShellMissing;

        const wl_surface = c.wl_compositor_create_surface(compositor) orelse return error.SurfaceCreateFailed;
        errdefer c.wl_surface_destroy(wl_surface);

        const layer_surface = c.zwlr_layer_shell_v1_get_layer_surface(
            layer_shell,
            wl_surface,
            null,
            c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
            "axia-panel-battery",
        ) orelse return error.LayerSurfaceCreateFailed;

        c.zwlr_layer_surface_v1_set_anchor(
            layer_surface,
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT,
        );
        c.zwlr_layer_surface_v1_set_margin(layer_surface, panel_popup_top_gap, 138, 0, 0);
        c.zwlr_layer_surface_v1_set_size(layer_surface, battery_popup.popup_width, battery_popup.popup_height);
        c.zwlr_layer_surface_v1_set_exclusive_zone(layer_surface, 0);
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(
            layer_surface,
            c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE,
        );

        self.battery_popup.wl_surface = wl_surface;
        self.battery_popup.layer_surface = layer_surface;
        self.battery_popup.dirty = true;
        self.installSurfaceListeners(&self.battery_popup);

        c.wl_surface_commit(wl_surface);
    }

    fn destroyBatteryPopup(self: *App) void {
        self.battery_popup.destroy();
    }

    fn createNetworkPopup(self: *App) !void {
        if (self.network_popup.layer_surface != null) return;
        try self.ensureDismissOverlay();

        const compositor = self.compositor orelse return error.CompositorMissing;
        const layer_shell = self.layer_shell orelse return error.LayerShellMissing;

        const wl_surface = c.wl_compositor_create_surface(compositor) orelse return error.SurfaceCreateFailed;
        errdefer c.wl_surface_destroy(wl_surface);

        const layer_surface = c.zwlr_layer_shell_v1_get_layer_surface(
            layer_shell,
            wl_surface,
            null,
            c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
            "axia-panel-network",
        ) orelse return error.LayerSurfaceCreateFailed;

        c.zwlr_layer_surface_v1_set_anchor(
            layer_surface,
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT,
        );
        c.zwlr_layer_surface_v1_set_margin(layer_surface, panel_popup_top_gap, 96, 0, 0);
        c.zwlr_layer_surface_v1_set_size(layer_surface, network_popup.popup_width, network_popup.popup_height);
        c.zwlr_layer_surface_v1_set_exclusive_zone(layer_surface, 0);
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(
            layer_surface,
            c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE,
        );

        self.network_popup.wl_surface = wl_surface;
        self.network_popup.layer_surface = layer_surface;
        self.network_popup.dirty = true;
        self.installSurfaceListeners(&self.network_popup);

        c.wl_surface_commit(wl_surface);
    }

    fn destroyNetworkPopup(self: *App) void {
        self.network_popup.destroy();
    }

    fn createBluetoothPopup(self: *App) !void {
        if (self.bluetooth_popup.layer_surface != null) return;
        try self.ensureDismissOverlay();

        const compositor = self.compositor orelse return error.CompositorMissing;
        const layer_shell = self.layer_shell orelse return error.LayerShellMissing;

        const wl_surface = c.wl_compositor_create_surface(compositor) orelse return error.SurfaceCreateFailed;
        errdefer c.wl_surface_destroy(wl_surface);

        const layer_surface = c.zwlr_layer_shell_v1_get_layer_surface(
            layer_shell,
            wl_surface,
            null,
            c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
            "axia-panel-bluetooth",
        ) orelse return error.LayerSurfaceCreateFailed;

        c.zwlr_layer_surface_v1_set_anchor(
            layer_surface,
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT,
        );
        c.zwlr_layer_surface_v1_set_margin(layer_surface, panel_popup_top_gap, 54, 0, 0);
        c.zwlr_layer_surface_v1_set_size(layer_surface, bluetooth_popup.popup_width, bluetooth_popup.popup_height);
        c.zwlr_layer_surface_v1_set_exclusive_zone(layer_surface, 0);
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(
            layer_surface,
            c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE,
        );

        self.bluetooth_popup.wl_surface = wl_surface;
        self.bluetooth_popup.layer_surface = layer_surface;
        self.bluetooth_popup.dirty = true;
        self.installSurfaceListeners(&self.bluetooth_popup);

        c.wl_surface_commit(wl_surface);
    }

    fn destroyBluetoothPopup(self: *App) void {
        self.bluetooth_popup.destroy();
    }

    fn createAudioPopup(self: *App) !void {
        if (self.audio_popup.layer_surface != null) return;
        try self.ensureDismissOverlay();

        const compositor = self.compositor orelse return error.CompositorMissing;
        const layer_shell = self.layer_shell orelse return error.LayerShellMissing;

        const wl_surface = c.wl_compositor_create_surface(compositor) orelse return error.SurfaceCreateFailed;
        errdefer c.wl_surface_destroy(wl_surface);

        const layer_surface = c.zwlr_layer_shell_v1_get_layer_surface(
            layer_shell,
            wl_surface,
            null,
            c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
            "axia-panel-audio",
        ) orelse return error.LayerSurfaceCreateFailed;

        c.zwlr_layer_surface_v1_set_anchor(
            layer_surface,
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT,
        );
        c.zwlr_layer_surface_v1_set_margin(layer_surface, panel_popup_top_gap, 12, 0, 0);
        c.zwlr_layer_surface_v1_set_size(layer_surface, audio_popup.popup_width, audio_popup.popup_height);
        c.zwlr_layer_surface_v1_set_exclusive_zone(layer_surface, 0);
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(
            layer_surface,
            c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE,
        );

        self.audio_popup.wl_surface = wl_surface;
        self.audio_popup.layer_surface = layer_surface;
        self.audio_popup.dirty = true;
        self.installSurfaceListeners(&self.audio_popup);

        c.wl_surface_commit(wl_surface);
    }

    fn destroyAudioPopup(self: *App) void {
        self.audio_popup.destroy();
    }

    fn createWorkspacePopup(self: *App) !void {
        if (self.workspace_popup.layer_surface != null) return;
        try self.ensureDismissOverlay();

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
        c.zwlr_layer_surface_v1_set_margin(layer_surface, panel_popup_top_gap, 0, 0, 16);
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
        try self.ensureDismissOverlay();

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
        c.zwlr_layer_surface_v1_set_margin(layer_surface, panel_popup_top_gap, 0, 0, 16);
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

    fn createToastPopup(self: *App) !void {
        if (self.toast_popup.layer_surface != null) return;

        const compositor = self.compositor orelse return error.CompositorMissing;
        const layer_shell = self.layer_shell orelse return error.LayerShellMissing;

        const wl_surface = c.wl_compositor_create_surface(compositor) orelse return error.SurfaceCreateFailed;
        errdefer c.wl_surface_destroy(wl_surface);

        const layer_surface = c.zwlr_layer_shell_v1_get_layer_surface(
            layer_shell,
            wl_surface,
            null,
            c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
            "axia-panel-toast",
        ) orelse return error.LayerSurfaceCreateFailed;

        c.zwlr_layer_surface_v1_set_anchor(
            layer_surface,
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP | c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT,
        );
        c.zwlr_layer_surface_v1_set_margin(layer_surface, panel_height + 12, 18, 0, 0);
        c.zwlr_layer_surface_v1_set_size(layer_surface, toast_popup.popup_width, toast_popup.popup_height);
        c.zwlr_layer_surface_v1_set_exclusive_zone(layer_surface, 0);
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(
            layer_surface,
            c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE,
        );

        self.toast_popup.wl_surface = wl_surface;
        self.toast_popup.layer_surface = layer_surface;
        self.toast_popup.dirty = true;
        self.installSurfaceListeners(&self.toast_popup);
        c.wl_surface_commit(wl_surface);
    }

    fn destroyToastPopup(self: *App) void {
        self.toast_popup.destroy();
    }

    fn ensureDismissOverlay(self: *App) !void {
        if (self.dismiss_overlay.layer_surface != null) return;

        const compositor = self.compositor orelse return error.CompositorMissing;
        const layer_shell = self.layer_shell orelse return error.LayerShellMissing;

        const wl_surface = c.wl_compositor_create_surface(compositor) orelse return error.SurfaceCreateFailed;
        errdefer c.wl_surface_destroy(wl_surface);

        const layer_surface = c.zwlr_layer_shell_v1_get_layer_surface(
            layer_shell,
            wl_surface,
            null,
            c.ZWLR_LAYER_SHELL_V1_LAYER_TOP,
            "axia-panel-dismiss",
        ) orelse return error.LayerSurfaceCreateFailed;

        c.zwlr_layer_surface_v1_set_anchor(
            layer_surface,
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
                c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
                c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT |
                c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM,
        );
        c.zwlr_layer_surface_v1_set_margin(layer_surface, panel_height, 0, 0, 0);
        c.zwlr_layer_surface_v1_set_size(layer_surface, 0, 0);
        c.zwlr_layer_surface_v1_set_exclusive_zone(layer_surface, 0);
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(
            layer_surface,
            c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE,
        );

        self.dismiss_overlay.wl_surface = wl_surface;
        self.dismiss_overlay.layer_surface = layer_surface;
        self.dismiss_overlay.dirty = true;
        self.installSurfaceListeners(&self.dismiss_overlay);
        c.wl_surface_commit(wl_surface);
    }

    fn updateDismissOverlay(self: *App) void {
        const keep = self.clock_popup_visible or self.notifications_popup_visible or self.power_popup_visible or self.battery_popup_visible or self.network_popup_visible or self.bluetooth_popup_visible or self.audio_popup_visible or self.workspace_popup_visible or self.launcher_popup_visible;
        if (!keep) {
            self.dismiss_overlay.destroy();
        }
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
        if (self.dismiss_overlay.layer_surface != null and self.dismiss_overlay.dirty) try self.drawSurface(&self.dismiss_overlay);
        if (self.clock_popup_visible and self.popup.dirty) try self.drawSurface(&self.popup);
        if (self.notifications_popup_visible and self.notifications_popup.dirty) try self.drawSurface(&self.notifications_popup);
        if (self.power_popup_visible and self.power_popup.dirty) try self.drawSurface(&self.power_popup);
        if (self.battery_popup_visible and self.battery_popup.dirty) try self.drawSurface(&self.battery_popup);
        if (self.network_popup_visible and self.network_popup.dirty) try self.drawSurface(&self.network_popup);
        if (self.bluetooth_popup_visible and self.bluetooth_popup.dirty) try self.drawSurface(&self.bluetooth_popup);
        if (self.audio_popup_visible and self.audio_popup.dirty) try self.drawSurface(&self.audio_popup);
        if (self.launcher_popup_visible and self.launcher_popup.dirty) try self.drawSurface(&self.launcher_popup);
        if (self.workspace_popup_visible and self.workspace_popup.dirty) try self.drawSurface(&self.workspace_popup);
        if (self.toast_popup.layer_surface != null and self.toast_popup.dirty) try self.drawSurface(&self.toast_popup);
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
            .panel => render.drawPanel(buffer.cr, surface.width, surface.height, self.now, self.panel_hovered, self.audio_state, self.battery_state, self.network_state, self.bluetooth_state, self.notification_state, self.preferences),
            .dismiss_overlay => drawDismissOverlay(buffer.cr),
            .clock_popup => render.drawCalendarPopup(buffer.cr, surface.width, surface.height, self.month_cursor, self.now, self.preferences),
            .notifications_popup => notifications_popup.drawPopup(buffer.cr, surface.width, surface.height, self.notification_state, self.preferences),
            .power_popup => power_popup.drawPopup(buffer.cr, surface.width, surface.height, self.preferences),
            .battery_popup => battery_popup.drawPopup(buffer.cr, surface.width, surface.height, self.battery_state, self.preferences),
            .network_popup => network_popup.drawPopup(buffer.cr, surface.width, surface.height, self.network_state, self.preferences),
            .bluetooth_popup => bluetooth_popup.drawPopup(buffer.cr, surface.width, surface.height, self.bluetooth_state, self.preferences),
            .audio_popup => audio_popup.drawPopup(buffer.cr, surface.width, surface.height, self.audio_state, self.preferences),
            .launcher_popup => launcher.drawPopup(buffer.cr, surface.width, surface.height, self.launcher_entries.items),
            .workspace_popup => workspaces.drawPopup(buffer.cr, surface.width, surface.height, self.workspace_state),
            .toast_popup => toast_popup.drawPopup(buffer.cr, surface.width, surface.height, self.toast_state, self.preferences),
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
                    .dismiss_overlay => "dismiss-overlay",
                    .clock_popup => "clock-popup",
                    .notifications_popup => "notifications-popup",
                    .power_popup => "power-popup",
                    .battery_popup => "battery-popup",
                    .network_popup => "network-popup",
                    .bluetooth_popup => "bluetooth-popup",
                    .audio_popup => "audio-popup",
                    .launcher_popup => "launcher-popup",
                    .workspace_popup => "workspace-popup",
                    .toast_popup => "toast-popup",
                },
                surface.width,
                surface.height,
            });
        }
    }

    fn tickClock(self: *App) void {
        const prefs_changed = self.refreshPreferences();
        const now = calendar.DateTime.now();
        const new_stamp = now.minuteStamp();
        if (!prefs_changed and !self.preferences.panel_show_seconds and new_stamp == self.displayed_minute_stamp) return;

        self.now = now;
        self.displayed_minute_stamp = new_stamp;
        self.panel.dirty = true;
        if (self.dismiss_overlay.layer_surface != null) self.dismiss_overlay.dirty = true;
        if (self.clock_popup_visible) self.popup.dirty = true;
        if (self.notifications_popup_visible) self.notifications_popup.dirty = true;
        if (self.power_popup_visible) self.power_popup.dirty = true;
        if (self.battery_popup_visible) self.battery_popup.dirty = true;
        if (self.network_popup_visible) self.network_popup.dirty = true;
        if (self.bluetooth_popup_visible) self.bluetooth_popup.dirty = true;
        if (self.audio_popup_visible) self.audio_popup.dirty = true;
        if (self.launcher_popup_visible) self.launcher_popup.dirty = true;
        if (self.workspace_popup_visible) self.workspace_popup.dirty = true;
    }

    fn tickBluetooth(self: *App) void {
        const now_ms = std.time.milliTimestamp();
        const interval_ms: i64 = if (self.bluetooth_popup_visible) 1200 else 2500;
        if (now_ms - self.last_bluetooth_refresh_ms < interval_ms) return;
        self.last_bluetooth_refresh_ms = now_ms;

        if (!bluetooth.refresh(self.allocator, &self.bluetooth_state)) return;
        self.panel.dirty = true;
        if (self.bluetooth_popup_visible) self.bluetooth_popup.dirty = true;
    }

    fn tickBattery(self: *App) void {
        const now_ms = std.time.milliTimestamp();
        const interval_ms: i64 = if (self.battery_popup_visible) 4000 else 12000;
        if (now_ms - self.last_battery_refresh_ms < interval_ms) return;
        self.last_battery_refresh_ms = now_ms;

        if (!battery.refresh(self.allocator, &self.battery_state)) return;
        self.panel.dirty = true;
        if (self.battery_popup_visible) self.battery_popup.dirty = true;
    }

    fn tickNetwork(self: *App) void {
        const now_ms = std.time.milliTimestamp();
        const interval_ms: i64 = if (self.network_popup_visible) 1800 else 3000;
        if (now_ms - self.last_network_refresh_ms < interval_ms) return;
        self.last_network_refresh_ms = now_ms;

        if (!network.refresh(self.allocator, &self.network_state)) return;
        self.panel.dirty = true;
        if (self.network_popup_visible) self.network_popup.dirty = true;
    }

    fn tickAudio(self: *App) void {
        const now_ms = std.time.milliTimestamp();
        const interval_ms: i64 = if (self.audio_popup_visible) 350 else 1500;
        if (now_ms - self.last_audio_refresh_ms < interval_ms) return;
        self.last_audio_refresh_ms = now_ms;

        if (!audio.refresh(self.allocator, &self.audio_state)) return;
        self.panel.dirty = true;
        if (self.audio_popup_visible) self.audio_popup.dirty = true;
    }

    fn tickToasts(self: *App) void {
        const socket_path = self.ipc_socket_path orelse return;
        const now_ms = std.time.milliTimestamp();
        if (now_ms - self.last_toast_refresh_ms < 180) return;
        self.last_toast_refresh_ms = now_ms;

        const next = ipc.getToasts(self.allocator, socket_path) catch return;
        if (toast_model.equal(self.toast_state, next)) return;

        self.toast_state = next;
        if (self.toast_state.count > 0) {
            self.createToastPopup() catch return;
            self.toast_popup.dirty = true;
        } else {
            self.destroyToastPopup();
        }
    }

    fn tickNotifications(self: *App) void {
        const socket_path = self.ipc_socket_path orelse return;
        const now_ms = std.time.milliTimestamp();
        const interval_ms: i64 = if (self.notifications_popup_visible) 900 else 2200;
        if (now_ms - self.last_notification_refresh_ms < interval_ms) return;
        self.last_notification_refresh_ms = now_ms;

        const next = ipc.getNotifications(self.allocator, socket_path) catch return;
        if (notification_model.equal(self.notification_state, next)) return;

        self.notification_state = next;
        self.panel.dirty = true;
        if (self.notifications_popup_visible) self.notifications_popup.dirty = true;
    }

    fn refreshPreferences(self: *App) bool {
        var loaded = prefs.load(self.allocator) catch return false;
        defer loaded.deinit();

        const next = preferencesStateFromStored(loaded);
        if (preferencesEqual(self.preferences, next)) return false;
        self.preferences = next;
        return true;
    }

    fn pushNotification(self: *App, level: notification_model.Level, message: []const u8) void {
        const socket_path = self.ipc_socket_path orelse return;
        notification_client.push(self.allocator, socket_path, level, message) catch {};
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

        if (self.pointer_role == .notifications_popup and self.notifications_popup_visible) {
            if (notifications_popup.hitTest(x, y) == .do_not_disturb) {
                const socket_path = self.ipc_socket_path orelse return;
                const next_state = ipc.setDoNotDisturb(self.allocator, socket_path, !self.notification_state.do_not_disturb) catch |err| {
                    log.err("failed to update do not disturb: {}", .{err});
                    return;
                };
                self.notification_state = next_state;
                self.panel.dirty = true;
                self.notifications_popup.dirty = true;
            }
            return;
        }

        if (self.pointer_role == .power_popup and self.power_popup_visible) {
            if (power_popup.hitTest(x, y)) |target| {
                self.runPowerAction(target);
                self.togglePowerPopup();
            }
            return;
        }

        if (self.pointer_role == .battery_popup and self.battery_popup_visible) {
            return;
        }

        if (self.pointer_role == .network_popup and self.network_popup_visible) {
            if (network_popup.hitTest(self.network_state, x, y)) |target| {
                switch (target) {
                    .wifi_toggle => {
                        const enabled = !self.network_state.wifi_enabled;
                        network.setWifiEnabled(self.allocator, enabled) catch |err| {
                            log.err("failed to toggle wifi: {}", .{err});
                            return;
                        };
                        self.pushNotification(.info, if (enabled) "Wi-Fi ligado." else "Wi-Fi desligado.");
                    },
                    .network => |index| {
                        if (index < self.network_state.networks.count) {
                            const item = self.network_state.networks.items[index];
                            if (!item.active) {
                                network.connectWifi(self.allocator, self.network_state.wifiDevice(), item.ssidText()) catch |err| {
                                    log.err("failed to connect wifi network: {}", .{err});
                                    return;
                                };
                                var message_buf: [192]u8 = undefined;
                                const message = std.fmt.bufPrint(&message_buf, "Tentando conectar em {s}.", .{item.ssidText()}) catch "Tentando conectar em uma rede Wi-Fi.";
                                self.pushNotification(.info, message);
                            }
                        }
                    },
                }
                _ = network.refresh(self.allocator, &self.network_state);
                self.last_network_refresh_ms = std.time.milliTimestamp();
                self.panel.dirty = true;
                self.network_popup.dirty = true;
            }
            return;
        }

        if (self.pointer_role == .bluetooth_popup and self.bluetooth_popup_visible) {
            if (bluetooth_popup.hitTest(self.bluetooth_state, x, y)) |target| {
                switch (target) {
                    .power_toggle => {
                        const powered = !self.bluetooth_state.powered;
                        bluetooth.setPowered(self.allocator, powered) catch |err| {
                            log.err("failed to toggle bluetooth power: {}", .{err});
                            return;
                        };
                        self.pushNotification(.info, if (powered) "Bluetooth ligado." else "Bluetooth desligado.");
                    },
                    .device => |index| {
                        if (index < self.bluetooth_state.devices.count) {
                            const device = self.bluetooth_state.devices.items[index];
                            if (device.connected) {
                                bluetooth.disconnectDevice(self.allocator, device.addressText()) catch |err| {
                                    log.err("failed to disconnect bluetooth device: {}", .{err});
                                    return;
                                };
                                var message_buf: [224]u8 = undefined;
                                const message = std.fmt.bufPrint(&message_buf, "Desconectando {s}.", .{device.nameText()}) catch "Desconectando dispositivo Bluetooth.";
                                self.pushNotification(.info, message);
                            } else {
                                bluetooth.connectDevice(self.allocator, device.addressText()) catch |err| {
                                    log.err("failed to connect bluetooth device: {}", .{err});
                                    return;
                                };
                                var message_buf: [224]u8 = undefined;
                                const message = std.fmt.bufPrint(&message_buf, "Tentando conectar {s}.", .{device.nameText()}) catch "Tentando conectar dispositivo Bluetooth.";
                                self.pushNotification(.info, message);
                            }
                        }
                    },
                }
                _ = bluetooth.refresh(self.allocator, &self.bluetooth_state);
                self.last_bluetooth_refresh_ms = std.time.milliTimestamp();
                self.panel.dirty = true;
                self.bluetooth_popup.dirty = true;
            }
            return;
        }

        if (self.pointer_role == .audio_popup and self.audio_popup_visible) {
            if (audio_popup.hitTest(self.audio_state, x, y)) |target| {
                switch (target) {
                    .sink_icon => audio.toggleSinkMute(self.allocator) catch |err| {
                        log.err("failed to toggle sink mute: {}", .{err});
                    },
                    .source_icon => audio.toggleSourceMute(self.allocator) catch |err| {
                        log.err("failed to toggle source mute: {}", .{err});
                    },
                    .sink_slider => if (audio_popup.sliderValue(target, x)) |value| {
                        audio.setSinkVolume(self.allocator, value) catch |err| log.err("failed to set sink volume: {}", .{err});
                    },
                    .source_slider => if (audio_popup.sliderValue(target, x)) |value| {
                        audio.setSourceVolume(self.allocator, value) catch |err| log.err("failed to set source volume: {}", .{err});
                    },
                    .sink_device => |index| {
                        if (index < self.audio_state.sinks.count) {
                            audio.setDefaultSink(self.allocator, self.audio_state.sinks.items[index].id) catch |err| {
                                log.err("failed to set default sink: {}", .{err});
                                return;
                            };
                            var message_buf: [224]u8 = undefined;
                            const message = std.fmt.bufPrint(&message_buf, "Saida alterada para {s}.", .{self.audio_state.sinks.items[index].labelText()}) catch "Saida de audio alterada.";
                            self.pushNotification(.info, message);
                        }
                    },
                    .source_device => |index| {
                        if (index < self.audio_state.sources.count) {
                            audio.setDefaultSource(self.allocator, self.audio_state.sources.items[index].id) catch |err| {
                                log.err("failed to set default source: {}", .{err});
                                return;
                            };
                            var message_buf: [224]u8 = undefined;
                            const message = std.fmt.bufPrint(&message_buf, "Entrada alterada para {s}.", .{self.audio_state.sources.items[index].labelText()}) catch "Entrada de audio alterada.";
                            self.pushNotification(.info, message);
                        }
                    },
                }
                _ = audio.refresh(self.allocator, &self.audio_state);
                self.last_audio_refresh_ms = std.time.milliTimestamp();
                self.panel.dirty = true;
                self.audio_popup.dirty = true;
            }
            return;
        }

        if (self.pointer_role == .launcher_popup and self.launcher_popup_visible) {
            if (launcher.hitTest(self.launcher_entries.items, x, y)) |index| {
                if (index >= self.launcher_entries.items.len) return;
                launcher_state.recordRecentId(self.allocator, self.launcher_entries.items[index].id) catch |err| {
                    log.err("failed to persist panel recent app: {}", .{err});
                };
                self.spawnCommand(self.launcher_entries.items[index].command) catch |err| {
                    log.err("failed to launch app: {}", .{err});
                };
                self.toggleLauncherPopup();
            }
            return;
        }

        if (self.pointer_role == .toast_popup) {
            return;
        }

        if (self.pointer_role == .dismiss_overlay) {
            if (self.clock_popup_visible) self.toggleClockPopup();
            if (self.notifications_popup_visible) self.toggleNotificationsPopup();
            if (self.power_popup_visible) self.togglePowerPopup();
            if (self.battery_popup_visible) self.toggleBatteryPopup();
            if (self.network_popup_visible) self.toggleNetworkPopup();
            if (self.bluetooth_popup_visible) self.toggleBluetoothPopup();
            if (self.audio_popup_visible) self.toggleAudioPopup();
            if (self.launcher_popup_visible) self.toggleLauncherPopup();
            if (self.workspace_popup_visible) self.toggleWorkspacePopup();
            return;
        }

        const metrics = render.computePanelMetrics(self.panel.width, panel_height, self.battery_state.available, self.network_state.available, self.bluetooth_state.available);
        if (metrics.power.contains(x, y)) {
            self.togglePowerPopup();
            return;
        }
        if (metrics.notifications.contains(x, y)) {
            self.toggleNotificationsPopup();
            return;
        }
        if (self.battery_state.available and metrics.battery.contains(x, y)) {
            self.toggleBatteryPopup();
            return;
        }
        if (self.network_state.available and metrics.network.contains(x, y)) {
            self.toggleNetworkPopup();
            return;
        }
        if (self.bluetooth_state.available and metrics.bluetooth.contains(x, y)) {
            self.toggleBluetoothPopup();
            return;
        }
        if (metrics.audio.contains(x, y)) {
            self.toggleAudioPopup();
            return;
        }
        if (metrics.clock.contains(x, y)) {
            self.toggleClockPopup();
            return;
        }
        if (metrics.apps.contains(x, y)) {
            self.closeOtherPopups(.panel);
            const socket_path = self.ipc_socket_path orelse return;
            ipc.toggleLauncher(self.allocator, socket_path) catch |err| {
                log.err("failed to toggle Axia Launcher: {}", .{err});
            };
            return;
        }
        if (metrics.workspaces.contains(x, y)) {
            self.toggleWorkspacePopup();
            return;
        }

        if (self.pointer_role == .panel) {
            if (self.clock_popup_visible) self.toggleClockPopup();
            if (self.notifications_popup_visible) self.toggleNotificationsPopup();
            if (self.power_popup_visible) self.togglePowerPopup();
            if (self.battery_popup_visible) self.toggleBatteryPopup();
            if (self.network_popup_visible) self.toggleNetworkPopup();
            if (self.bluetooth_popup_visible) self.toggleBluetoothPopup();
            if (self.audio_popup_visible) self.toggleAudioPopup();
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
            self.updateDismissOverlay();
        }
    }

    fn toggleNotificationsPopup(self: *App) void {
        if (!self.notifications_popup_visible) self.closeOtherPopups(.notifications_popup);
        self.notifications_popup_visible = !self.notifications_popup_visible;
        if (self.notifications_popup_visible) {
            const socket_path = self.ipc_socket_path orelse return;
            self.notification_state = ipc.getNotifications(self.allocator, socket_path) catch self.notification_state;
            self.last_notification_refresh_ms = std.time.milliTimestamp();
            self.createNotificationsPopup() catch |err| {
                self.notifications_popup_visible = false;
                log.err("failed to create notifications popup: {}", .{err});
                return;
            };
            self.panel.dirty = true;
            self.notifications_popup.dirty = true;
        } else {
            self.destroyNotificationsPopup();
            self.panel.dirty = true;
            self.updateDismissOverlay();
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
            self.updateDismissOverlay();
        }
    }

    fn togglePowerPopup(self: *App) void {
        if (!self.power_popup_visible) self.closeOtherPopups(.power_popup);
        self.power_popup_visible = !self.power_popup_visible;
        if (self.power_popup_visible) {
            self.createPowerPopup() catch |err| {
                self.power_popup_visible = false;
                log.err("failed to create power popup: {}", .{err});
                return;
            };
            self.panel.dirty = true;
            self.power_popup.dirty = true;
        } else {
            self.destroyPowerPopup();
            self.panel.dirty = true;
            self.updateDismissOverlay();
        }
    }

    fn toggleBatteryPopup(self: *App) void {
        if (!self.battery_popup_visible) self.closeOtherPopups(.battery_popup);
        self.battery_popup_visible = !self.battery_popup_visible;
        if (self.battery_popup_visible) {
            _ = battery.refresh(self.allocator, &self.battery_state);
            self.last_battery_refresh_ms = std.time.milliTimestamp();
            self.createBatteryPopup() catch |err| {
                self.battery_popup_visible = false;
                log.err("failed to create battery popup: {}", .{err});
                return;
            };
            self.panel.dirty = true;
            self.battery_popup.dirty = true;
        } else {
            self.destroyBatteryPopup();
            self.panel.dirty = true;
            self.updateDismissOverlay();
        }
    }

    fn toggleNetworkPopup(self: *App) void {
        if (!self.network_popup_visible) self.closeOtherPopups(.network_popup);
        self.network_popup_visible = !self.network_popup_visible;
        if (self.network_popup_visible) {
            _ = network.refresh(self.allocator, &self.network_state);
            self.last_network_refresh_ms = std.time.milliTimestamp();
            self.createNetworkPopup() catch |err| {
                self.network_popup_visible = false;
                log.err("failed to create network popup: {}", .{err});
                return;
            };
            self.panel.dirty = true;
            self.network_popup.dirty = true;
        } else {
            self.destroyNetworkPopup();
            self.panel.dirty = true;
            self.updateDismissOverlay();
        }
    }

    fn toggleBluetoothPopup(self: *App) void {
        if (!self.bluetooth_popup_visible) self.closeOtherPopups(.bluetooth_popup);
        self.bluetooth_popup_visible = !self.bluetooth_popup_visible;
        if (self.bluetooth_popup_visible) {
            _ = bluetooth.refresh(self.allocator, &self.bluetooth_state);
            self.last_bluetooth_refresh_ms = std.time.milliTimestamp();
            self.createBluetoothPopup() catch |err| {
                self.bluetooth_popup_visible = false;
                log.err("failed to create bluetooth popup: {}", .{err});
                return;
            };
            self.panel.dirty = true;
            self.bluetooth_popup.dirty = true;
        } else {
            self.destroyBluetoothPopup();
            self.panel.dirty = true;
            self.updateDismissOverlay();
        }
    }

    fn toggleAudioPopup(self: *App) void {
        if (!self.audio_popup_visible) self.closeOtherPopups(.audio_popup);
        self.audio_popup_visible = !self.audio_popup_visible;
        if (self.audio_popup_visible) {
            _ = audio.refresh(self.allocator, &self.audio_state);
            self.last_audio_refresh_ms = std.time.milliTimestamp();
            self.createAudioPopup() catch |err| {
                self.audio_popup_visible = false;
                log.err("failed to create audio popup: {}", .{err});
                return;
            };
            self.panel.dirty = true;
            self.audio_popup.dirty = true;
        } else {
            self.destroyAudioPopup();
            self.panel.dirty = true;
            self.updateDismissOverlay();
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
            self.updateDismissOverlay();
        }
    }

    fn closeOtherPopups(self: *App, keep: SurfaceRole) void {
        if (keep != .clock_popup and self.clock_popup_visible) self.toggleClockPopup();
        if (keep != .notifications_popup and self.notifications_popup_visible) self.toggleNotificationsPopup();
        if (keep != .power_popup and self.power_popup_visible) self.togglePowerPopup();
        if (keep != .battery_popup and self.battery_popup_visible) self.toggleBatteryPopup();
        if (keep != .network_popup and self.network_popup_visible) self.toggleNetworkPopup();
        if (keep != .bluetooth_popup and self.bluetooth_popup_visible) self.toggleBluetoothPopup();
        if (keep != .audio_popup and self.audio_popup_visible) self.toggleAudioPopup();
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

    fn runPowerAction(self: *App, target: power_popup.Target) void {
        const command: []const u8 = if (target == @field(power_popup.Target, "settings"))
            "exec \"$AXIA_BIN_DIR/axia-settings\""
        else if (target == @field(power_popup.Target, "lock"))
            "loginctl lock-session \"$XDG_SESSION_ID\""
        else if (target == @field(power_popup.Target, "logout"))
            "loginctl terminate-session \"$XDG_SESSION_ID\""
        else if (target == @field(power_popup.Target, "suspend_action"))
            "systemctl suspend"
        else if (target == @field(power_popup.Target, "restart_action"))
            "systemctl reboot"
        else
            "systemctl poweroff";
        self.spawnCommand(command) catch |err| {
            log.err("failed to run power action {s}: {}", .{@tagName(target), err});
        };
    }

    fn refreshWorkspaceState(self: *App) void {
        const socket_path = self.ipc_socket_path orelse return;
        self.workspace_state = ipc.getWorkspaceState(self.allocator, socket_path) catch self.workspace_state;
    }

    fn updatePanelHover(self: *App) void {
        const new_hovered = if (self.pointer_role == .panel)
            render.panelHoverAt(self.panel.width, panel_height, self.battery_state.available, self.network_state.available, self.bluetooth_state.available, self.pointer_x, self.pointer_y)
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
            .dismiss_overlay => default_output_width,
            .clock_popup => popup_width,
            .notifications_popup => notifications_popup.popup_width,
            .power_popup => power_popup.popup_width,
            .battery_popup => battery_popup.popup_width,
            .network_popup => network_popup.popup_width,
            .bluetooth_popup => bluetooth_popup.popup_width,
            .audio_popup => audio_popup.popup_width,
            .launcher_popup => launcher.popup_width,
            .workspace_popup => workspaces.popup_width,
            .toast_popup => toast_popup.popup_width,
        } else width;
        surface.height = if (height == 0) switch (surface.role) {
            .panel => panel_height,
            .dismiss_overlay => 720,
            .clock_popup => popup_height,
            .notifications_popup => notifications_popup.popup_height,
            .power_popup => power_popup.popup_height,
            .battery_popup => battery_popup.popup_height,
            .network_popup => network_popup.popup_height,
            .bluetooth_popup => bluetooth_popup.popup_height,
            .audio_popup => audio_popup.popup_height,
            .launcher_popup => launcher.popup_height,
            .workspace_popup => workspaces.popup_height,
            .toast_popup => toast_popup.popup_height,
        } else height;
        surface.configured = true;
        surface.mapped = true;
        surface.dirty = true;
        if (!surface.logged_configure) {
            surface.logged_configure = true;
            log.info("configured {s} surface at {}x{}", .{
                switch (surface.role) {
                    .panel => "panel",
                    .dismiss_overlay => "dismiss-overlay",
                    .clock_popup => "clock-popup",
                    .notifications_popup => "notifications-popup",
                    .power_popup => "power-popup",
                    .battery_popup => "battery-popup",
                    .network_popup => "network-popup",
                    .bluetooth_popup => "bluetooth-popup",
                    .audio_popup => "audio-popup",
                    .launcher_popup => "launcher-popup",
                    .workspace_popup => "workspace-popup",
                    .toast_popup => "toast-popup",
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
        } else if (app.dismiss_overlay.wl_surface != null and app.dismiss_overlay.wl_surface.? == wl_surface) {
            app.pointer_role = .dismiss_overlay;
        } else if (app.popup.wl_surface != null and app.popup.wl_surface.? == wl_surface) {
            app.pointer_role = .clock_popup;
        } else if (app.notifications_popup.wl_surface != null and app.notifications_popup.wl_surface.? == wl_surface) {
            app.pointer_role = .notifications_popup;
        } else if (app.power_popup.wl_surface != null and app.power_popup.wl_surface.? == wl_surface) {
            app.pointer_role = .power_popup;
        } else if (app.battery_popup.wl_surface != null and app.battery_popup.wl_surface.? == wl_surface) {
            app.pointer_role = .battery_popup;
        } else if (app.network_popup.wl_surface != null and app.network_popup.wl_surface.? == wl_surface) {
            app.pointer_role = .network_popup;
        } else if (app.bluetooth_popup.wl_surface != null and app.bluetooth_popup.wl_surface.? == wl_surface) {
            app.pointer_role = .bluetooth_popup;
        } else if (app.audio_popup.wl_surface != null and app.audio_popup.wl_surface.? == wl_surface) {
            app.pointer_role = .audio_popup;
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

fn drawDismissOverlay(cr: *c.cairo_t) void {
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
    c.cairo_set_source_rgba(cr, 0, 0, 0, 0);
    c.cairo_paint(cr);
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);
}

fn preferencesEqual(a: settings_model.PreferencesState, b: settings_model.PreferencesState) bool {
    return a.accent == b.accent and
        a.reduce_transparency == b.reduce_transparency and
        a.panel_show_seconds == b.panel_show_seconds and
        a.panel_show_date == b.panel_show_date and
        a.workspace_wrap == b.workspace_wrap and
        a.startup_workspace == b.startup_workspace;
}

fn preferencesStateFromStored(stored: prefs.Preferences) settings_model.PreferencesState {
    return .{
        .accent = switch (stored.accent) {
            .aurora => .aurora,
            .ember => .ember,
            .moss => .moss,
        },
        .reduce_transparency = stored.reduce_transparency,
        .panel_show_seconds = stored.panel_show_seconds,
        .panel_show_date = stored.panel_show_date,
        .workspace_wrap = stored.workspace_wrap,
        .startup_workspace = stored.startup_workspace,
    };
}
