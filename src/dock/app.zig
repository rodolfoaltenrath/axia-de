const std = @import("std");
const c = @import("wl.zig").c;
const buffer_mod = @import("buffer.zig");
const dock_icons = @import("icons.zig");
const dock_ipc = @import("ipc.zig");
const launcher_state = @import("launcher_state");
const runtime_catalog = @import("runtime_catalog");
const render = @import("render.zig");

const log = std.log.scoped(.axia_dock);
const default_output_width: u32 = 1366;
const runtime_sync_interval_ms: i64 = 160;

const SurfaceState = struct {
    wl_surface: ?*c.struct_wl_surface = null,
    layer_surface: ?*c.struct_zwlr_layer_surface_v1 = null,
    width: u32 = 0,
    height: u32 = 0,
    configured: bool = false,
    buffer: ?buffer_mod.ShmBuffer = null,
    dirty: bool = false,
    layer_listener: c.struct_zwlr_layer_surface_v1_listener = undefined,
    surface_listener: c.struct_wl_surface_listener = undefined,

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
    ipc_socket_path: ?[]u8 = null,
    surface: SurfaceState = .{},
    running: bool = true,
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    hovered_index: ?usize = null,
    last_runtime_sync_ms: i64 = 0,
    previewed_index: ?usize = null,
    catalog: runtime_catalog.Catalog,
    favorites: std.ArrayListUnmanaged(runtime_catalog.AppEntry) = .empty,
    display_entries: std.ArrayListUnmanaged(runtime_catalog.AppEntry) = .empty,
    display_open_apps: std.ArrayListUnmanaged(dock_ipc.OpenAppInfo) = .empty,
    open_apps: dock_ipc.OpenAppsState = .{},
    icons: dock_icons.IconCache,
    registry_listener: c.struct_wl_registry_listener = undefined,
    seat_listener: c.struct_wl_seat_listener = undefined,
    pointer_listener: c.struct_wl_pointer_listener = undefined,

    pub fn create(allocator: std.mem.Allocator) !*App {
        const app = try allocator.create(App);
        errdefer allocator.destroy(app);

        const display = c.wl_display_connect(null) orelse return error.WaylandConnectFailed;
        errdefer c.wl_display_disconnect(display);

        const registry = c.wl_display_get_registry(display) orelse return error.RegistryGetFailed;
        app.* = .{
            .allocator = allocator,
            .display = display,
            .registry = registry,
            .catalog = runtime_catalog.Catalog.init(allocator),
            .icons = try dock_icons.IconCache.init(allocator, &.{}),
        };
        app.ipc_socket_path = std.process.getEnvVarOwned(allocator, "AXIA_IPC_SOCKET") catch null;
        try app.catalog.loadDefault();
        try launcher_state.ensureDefaultFavorites(allocator, &app.catalog);
        app.favorites = try launcher_state.loadFavoriteEntries(allocator, &app.catalog);
        app.refreshOpenApps() catch {};
        try app.rebuildDisplayEntries();

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

        try app.createDockSurface();
        return app;
    }

    pub fn destroy(self: *App) void {
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }

    fn deinit(self: *App) void {
        self.hidePreview();
        self.surface.destroy();
        if (self.pointer) |pointer| c.wl_pointer_destroy(pointer);
        if (self.seat) |seat| c.wl_seat_destroy(seat);
        if (self.layer_shell) |layer_shell| c.zwlr_layer_shell_v1_destroy(layer_shell);
        if (self.shm) |shm| c.wl_shm_destroy(shm);
        if (self.compositor) |compositor| c.wl_compositor_destroy(compositor);
        self.icons.deinit();
        self.display_entries.deinit(self.allocator);
        self.display_open_apps.deinit(self.allocator);
        self.favorites.deinit(self.allocator);
        self.catalog.deinit();
        c.wl_registry_destroy(self.registry);
        c.wl_display_disconnect(self.display);
        if (self.ipc_socket_path) |socket_path| self.allocator.free(socket_path);
    }

    pub fn run(self: *App) !void {
        while (self.running) {
            try self.refreshOpenAppsIfNeeded();
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

            const result = c.poll(&pollfd, 1, 1000);
            if (result < 0 and std.posix.errno(result) != .INTR) return error.PollFailed;
            if (result > 0 and (pollfd.revents & c.POLLIN) != 0) {
                if (c.wl_display_dispatch(self.display) < 0) {
                    return error.DisplayDispatchFailed;
                }
            }
        }
    }

    fn createDockSurface(self: *App) !void {
        const compositor = self.compositor orelse return error.CompositorMissing;
        const layer_shell = self.layer_shell orelse return error.LayerShellMissing;

        const wl_surface = c.wl_compositor_create_surface(compositor) orelse return error.SurfaceCreateFailed;
        errdefer c.wl_surface_destroy(wl_surface);

        const layer_surface = c.zwlr_layer_shell_v1_get_layer_surface(
            layer_shell,
            wl_surface,
            null,
            c.ZWLR_LAYER_SHELL_V1_LAYER_TOP,
            "axia-dock",
        ) orelse return error.LayerSurfaceCreateFailed;

        c.zwlr_layer_surface_v1_set_anchor(
            layer_surface,
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
                c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
                c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT,
        );
        c.zwlr_layer_surface_v1_set_size(layer_surface, 0, render.surface_height);
        c.zwlr_layer_surface_v1_set_exclusive_zone(layer_surface, render.surface_height);
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(
            layer_surface,
            c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE,
        );

        self.surface.wl_surface = wl_surface;
        self.surface.layer_surface = layer_surface;
        self.surface.dirty = true;
        self.installSurfaceListeners();
        c.wl_surface_commit(wl_surface);
    }

    fn installSurfaceListeners(self: *App) void {
        self.surface.layer_listener = .{
            .configure = handleLayerConfigure,
            .closed = handleLayerClosed,
        };
        self.surface.surface_listener = .{
            .enter = handleSurfaceEnter,
            .leave = handleSurfaceLeave,
            .preferred_buffer_scale = handlePreferredBufferScale,
            .preferred_buffer_transform = handlePreferredBufferTransform,
        };
        _ = c.zwlr_layer_surface_v1_add_listener(self.surface.layer_surface.?, &self.surface.layer_listener, self);
        _ = c.wl_surface_add_listener(self.surface.wl_surface.?, &self.surface.surface_listener, self);
    }

    fn redrawIfNeeded(self: *App) !void {
        if (!self.surface.dirty) return;
        const shm = self.shm orelse return error.ShmMissing;
        if (!self.surface.configured or self.surface.width == 0 or self.surface.height == 0) return;

        if (self.surface.buffer) |*buffer| {
            if (buffer.width != self.surface.width or buffer.height != self.surface.height) {
                buffer.deinit();
                self.surface.buffer = null;
            }
        }

        if (self.surface.buffer == null) {
            self.surface.buffer = try buffer_mod.ShmBuffer.init(shm, self.surface.width, self.surface.height);
        }

        const buffer = &self.surface.buffer.?;
        render.drawDock(
            buffer.cr,
            self.surface.width,
            self.surface.height,
            self.display_entries.items,
            self.display_open_apps.items,
            &self.icons,
            self.hovered_index,
        );

        c.cairo_surface_flush(buffer.surface);
        c.wl_surface_attach(self.surface.wl_surface.?, buffer.buffer, 0, 0);
        c.wl_surface_damage_buffer(self.surface.wl_surface.?, 0, 0, @intCast(self.surface.width), @intCast(self.surface.height));
        c.wl_surface_commit(self.surface.wl_surface.?);
        self.surface.dirty = false;
    }

    fn setSeat(self: *App, seat: *c.struct_wl_seat) void {
        self.seat = seat;
        self.seat_listener = .{
            .capabilities = handleSeatCapabilities,
            .name = handleSeatName,
        };
        _ = c.wl_seat_add_listener(seat, &self.seat_listener, self);
    }

    fn updateHover(self: *App) void {
        if (!self.surface.configured) return;
        const new_hovered = render.hitTest(self.surface.width, self.surface.height, self.pointer_x, self.pointer_y, self.display_entries.items);
        if (new_hovered != self.hovered_index) {
            self.hovered_index = new_hovered;
            self.syncPreviewHover();
            self.surface.dirty = true;
        }
    }

    fn refreshOpenAppsIfNeeded(self: *App) !void {
        const now_ms = std.time.milliTimestamp();
        if (now_ms - self.last_runtime_sync_ms < runtime_sync_interval_ms) return;
        self.last_runtime_sync_ms = now_ms;
        try self.refreshOpenApps();
    }

    fn refreshOpenApps(self: *App) !void {
        const socket_path = self.ipc_socket_path orelse return;
        const next = dock_ipc.getOpenApps(self.allocator, socket_path) catch return;
        if (openAppsEqual(self.open_apps, next)) return;

        const should_rebuild = !openAppIdsEqual(self.open_apps, next);
        self.open_apps = next;
        if (should_rebuild) {
            try self.rebuildDisplayEntries();
            self.updateHover();
            self.syncPreviewHover();
            self.surface.dirty = true;
        }
    }

    fn rebuildDisplayEntries(self: *App) !void {
        var next_entries: std.ArrayListUnmanaged(runtime_catalog.AppEntry) = .empty;
        errdefer next_entries.deinit(self.allocator);
        var next_open_apps: std.ArrayListUnmanaged(dock_ipc.OpenAppInfo) = .empty;
        errdefer next_open_apps.deinit(self.allocator);

        for (self.favorites.items) |entry| {
            try next_entries.append(self.allocator, entry);
            try next_open_apps.append(self.allocator, self.openAppForEntry(entry) orelse .{});
        }

        for (self.open_apps.apps[0..self.open_apps.count]) |open_app| {
            const entry = self.catalog.findByRuntimeApp(open_app.idText(), open_app.title[0..open_app.title_len]) orelse continue;
            if (containsEntry(next_entries.items, entry.id)) continue;
            try next_entries.append(self.allocator, entry);
            try next_open_apps.append(self.allocator, open_app);
        }

        const entries_changed = !sameEntryIds(self.display_entries.items, next_entries.items);

        self.display_entries.deinit(self.allocator);
        self.display_open_apps.deinit(self.allocator);
        self.display_entries = next_entries;
        self.display_open_apps = next_open_apps;

        if (!entries_changed) return;

        self.icons.deinit();
        self.icons = try dock_icons.IconCache.init(self.allocator, self.display_entries.items);
    }

    fn openAppForEntry(self: *const App, entry: runtime_catalog.AppEntry) ?dock_ipc.OpenAppInfo {
        for (self.open_apps.apps[0..self.open_apps.count]) |open_app| {
            const mapped = self.catalog.findByRuntimeApp(open_app.idText(), open_app.title[0..open_app.title_len]) orelse continue;
            if (std.mem.eql(u8, mapped.id, entry.id)) return open_app;
        }
        return null;
    }

    fn spawnCommand(self: *App, command: []const u8) !void {
        const argv: []const []const u8 = &.{ "sh", "-lc", command };
        var child = std.process.Child.init(argv, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        try child.spawn();
    }

    fn handleGlobal(data: ?*anyopaque, _: ?*c.struct_wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
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

    fn handleSeatCapabilities(data: ?*anyopaque, _: ?*c.struct_wl_seat, capabilities: u32) callconv(.c) void {
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
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        const zwlr_surface = layer_surface orelse return;
        c.zwlr_layer_surface_v1_ack_configure(zwlr_surface, serial);
        app.surface.width = if (width == 0) default_output_width else width;
        app.surface.height = if (height == 0) render.surface_height else height;
        app.surface.configured = true;
        app.surface.dirty = true;
        log.info("configured dock surface at {}x{}", .{ app.surface.width, app.surface.height });
    }

    fn handleLayerClosed(data: ?*anyopaque, _: ?*c.struct_zwlr_layer_surface_v1) callconv(.c) void {
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        app.running = false;
    }

    fn handleSurfaceEnter(_: ?*anyopaque, _: ?*c.struct_wl_surface, _: ?*c.struct_wl_output) callconv(.c) void {}
    fn handleSurfaceLeave(_: ?*anyopaque, _: ?*c.struct_wl_surface, _: ?*c.struct_wl_output) callconv(.c) void {}
    fn handlePreferredBufferScale(_: ?*anyopaque, _: ?*c.struct_wl_surface, _: i32) callconv(.c) void {}
    fn handlePreferredBufferTransform(_: ?*anyopaque, _: ?*c.struct_wl_surface, _: u32) callconv(.c) void {}

    fn handlePointerEnter(data: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: ?*c.struct_wl_surface, surface_x: c.wl_fixed_t, surface_y: c.wl_fixed_t) callconv(.c) void {
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        app.pointer_x = c.wl_fixed_to_double(surface_x);
        app.pointer_y = c.wl_fixed_to_double(surface_y);
        app.updateHover();
    }

    fn handlePointerLeave(data: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: ?*c.struct_wl_surface) callconv(.c) void {
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        app.hovered_index = null;
        app.syncPreviewHover();
        app.surface.dirty = true;
    }

    fn handlePointerMotion(data: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, surface_x: c.wl_fixed_t, surface_y: c.wl_fixed_t) callconv(.c) void {
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        app.pointer_x = c.wl_fixed_to_double(surface_x);
        app.pointer_y = c.wl_fixed_to_double(surface_y);
        app.updateHover();
    }

    fn handlePointerButton(data: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: u32, button: u32, state: u32) callconv(.c) void {
        if (state != c.WL_POINTER_BUTTON_STATE_PRESSED or button != 0x110) return;
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        app.hidePreview();
        const index = app.hovered_index orelse return;
        if (index >= app.display_entries.items.len) return;
        const entry = app.display_entries.items[index];
        const open_app = if (index < app.display_open_apps.items.len)
            app.display_open_apps.items[index]
        else
            dock_ipc.OpenAppInfo{};
        launcher_state.recordRecentId(app.allocator, entry.id) catch |err| {
            log.err("failed to persist dock recent app: {}", .{err});
        };

        if (open_app.id_len > 0) {
            const socket_path = app.ipc_socket_path orelse return;
            app.last_runtime_sync_ms = 0;
            if (dock_ipc.focusApp(app.allocator, socket_path, open_app.idText()) catch false) {
                return;
            }
        }

        app.spawnCommand(entry.command) catch |err| {
            log.err("failed to launch dock app: {}", .{err});
        };
        app.last_runtime_sync_ms = 0;
    }

    fn handlePointerAxis(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: u32, _: c.wl_fixed_t) callconv(.c) void {}
    fn handlePointerFrame(_: ?*anyopaque, _: ?*c.struct_wl_pointer) callconv(.c) void {}
    fn handlePointerAxisSource(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32) callconv(.c) void {}
    fn handlePointerAxisStop(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: u32) callconv(.c) void {}
    fn handlePointerAxisDiscrete(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: i32) callconv(.c) void {}
    fn handlePointerAxisValue120(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: i32) callconv(.c) void {}
    fn handlePointerAxisRelativeDirection(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: u32) callconv(.c) void {}

    fn displayOpenApp(self: *const App, index: usize) ?dock_ipc.OpenAppInfo {
        if (index >= self.display_open_apps.items.len) return null;
        const open_app = self.display_open_apps.items[index];
        if (open_app.id_len == 0) return null;
        return open_app;
    }

    fn containsEntry(entries: []const runtime_catalog.AppEntry, id: []const u8) bool {
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.id, id)) return true;
        }
        return false;
    }

    fn sameEntryIds(a: []const runtime_catalog.AppEntry, b: []const runtime_catalog.AppEntry) bool {
        if (a.len != b.len) return false;
        for (a, b) |lhs, rhs| {
            if (!std.mem.eql(u8, lhs.id, rhs.id)) return false;
        }
        return true;
    }

    fn openAppsEqual(a: dock_ipc.OpenAppsState, b: dock_ipc.OpenAppsState) bool {
        if (a.count != b.count) return false;
        for (0..a.count) |index| {
            const lhs = a.apps[index];
            const rhs = b.apps[index];
            if (lhs.focused != rhs.focused) return false;
            if (!std.mem.eql(u8, lhs.id[0..lhs.id_len], rhs.id[0..rhs.id_len])) return false;
            if (!std.mem.eql(u8, lhs.title[0..lhs.title_len], rhs.title[0..rhs.title_len])) return false;
        }
        return true;
    }

    fn openAppIdsEqual(a: dock_ipc.OpenAppsState, b: dock_ipc.OpenAppsState) bool {
        if (a.count != b.count) return false;
        for (0..a.count) |index| {
            const lhs = a.apps[index];
            const rhs = b.apps[index];
            if (!std.mem.eql(u8, lhs.id[0..lhs.id_len], rhs.id[0..rhs.id_len])) return false;
        }
        return true;
    }

    fn syncPreviewHover(self: *App) void {
        const hovered = self.hovered_index orelse {
            self.hidePreview();
            return;
        };
        if (hovered >= self.display_entries.items.len) {
            self.hidePreview();
            return;
        }

        const open_app = self.displayOpenApp(hovered) orelse {
            self.hidePreview();
            return;
        };

        if (self.previewed_index != null and self.previewed_index.? == hovered) return;
        const socket_path = self.ipc_socket_path orelse return;
        const rect = render.itemRect(self.surface.width, self.surface.height, self.display_entries.items, hovered);
        const anchor_x: i32 = @intFromFloat(@round(rect.x + rect.width / 2.0));
        dock_ipc.showPreview(self.allocator, socket_path, open_app.idText(), anchor_x) catch |err| {
            log.err("failed to show dock preview: {}", .{err});
            return;
        };
        self.previewed_index = hovered;
    }

    fn hidePreview(self: *App) void {
        if (self.previewed_index == null) return;
        const socket_path = self.ipc_socket_path orelse {
            self.previewed_index = null;
            return;
        };
        dock_ipc.hidePreview(self.allocator, socket_path) catch |err| {
            log.err("failed to hide dock preview: {}", .{err});
        };
        self.previewed_index = null;
    }
};
