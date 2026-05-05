const std = @import("std");
const c = @import("wl.zig").c;
const buffer_mod = @import("buffer.zig");
const dock_icons = @import("icons.zig");
const dock_ipc = @import("ipc.zig");
const dock_style = @import("style.zig");
const launcher_state = @import("launcher_state");
const runtime_catalog = @import("runtime_catalog");
const prefs = @import("axia_prefs");
const render = @import("render.zig");

const log = std.log.scoped(.axia_dock);
const default_output_width: u32 = 1366;
const runtime_sync_interval_ms: i64 = 160;
const preferences_sync_interval_ms: i64 = 320;
const auto_hide_grace_ms: i64 = 260;
const preview_hover_delay_ms: i64 = 0;
const preview_suppression_after_click_ms: i64 = 520;
const drag_start_threshold: f64 = 8.0;
const context_menu_extra_height: u32 = 80;

const GlassBox = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

const ContextMenuState = struct {
    open: bool = false,
    item_index: usize = 0,
    pinned: bool = false,
};

const DragState = struct {
    pressed_index: ?usize = null,
    source_index: usize = 0,
    target_index: usize = 0,
    press_x: f64 = 0,
    press_y: f64 = 0,
    active: bool = false,

    fn clear(self: *DragState) void {
        self.* = .{};
    }
};

const SurfaceState = struct {
    wl_surface: ?*c.struct_wl_surface = null,
    layer_surface: ?*c.struct_zwlr_layer_surface_v1 = null,
    width: u32 = 0,
    height: u32 = 0,
    configured: bool = false,
    buffers: [2]?buffer_mod.ShmBuffer = .{ null, null },
    dirty: bool = false,
    layer_listener: c.struct_zwlr_layer_surface_v1_listener = undefined,
    surface_listener: c.struct_wl_surface_listener = undefined,

    fn destroy(self: *SurfaceState) void {
        for (&self.buffers) |*slot| {
            if (slot.*) |*buffer| {
                buffer.deinit();
                slot.* = null;
            }
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
    all_apps_hovered: bool = false,
    pressed_hit: render.HitTarget = .none,
    hovered_since_ms: i64 = 0,
    last_runtime_sync_ms: i64 = 0,
    previewed_index: ?usize = null,
    preview_suppressed_until_ms: i64 = 0,
    pointer_inside: bool = false,
    hide_deadline_ms: i64 = 0,
    last_preferences_sync_ms: i64 = 0,
    last_animation_ms: i64 = 0,
    slide_offset_y: f64 = 0,
    last_glass_box: ?GlassBox = null,
    last_glass_surface_height: i32 = 0,
    context_menu: ContextMenuState = .{},
    drag: DragState = .{},
    catalog: runtime_catalog.Catalog,
    dock_config: dock_style.Config = dock_style.defaultConfig(),
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
        app.reloadDockPreferences() catch {};
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
            try self.refreshPreferencesIfNeeded();
            try self.refreshOpenAppsIfNeeded();
            self.updateDockAnimation();
            self.syncPreviewHover();
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

            const timeout_ms: c_int = if (self.isAnimating()) 16 else 1000;
            const result = c.poll(&pollfd, 1, timeout_ms);
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
            c.ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM,
            "axia-dock",
        ) orelse return error.LayerSurfaceCreateFailed;

        c.zwlr_layer_surface_v1_set_anchor(
            layer_surface,
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
                c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
                c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT,
        );
        const preferred_height = self.currentPreferredSurfaceHeight();
        c.zwlr_layer_surface_v1_set_size(layer_surface, 0, preferred_height);
        c.zwlr_layer_surface_v1_set_exclusive_zone(layer_surface, if (self.dock_config.auto_hide) 0 else @intCast(preferred_height));
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

        const buffer = (try self.acquireBuffer(shm)) orelse return;
        render.drawDock(
            buffer.cr,
            self.surface.width,
            self.surface.height,
            self.display_entries.items,
            self.display_open_apps.items,
            &self.icons,
            self.hovered_index,
            self.all_apps_hovered,
            false,
            self.dock_config.style,
            self.slide_offset_y,
            if (self.context_menu.open) .{
                .item_index = self.context_menu.item_index,
                .pinned = self.context_menu.pinned,
            } else null,
            if (self.drag.active) self.drag.target_index else null,
            self.favorites.items.len,
        );

        c.cairo_surface_flush(buffer.surface);
        c.wl_surface_attach(self.surface.wl_surface.?, buffer.buffer, 0, 0);
        c.wl_surface_damage_buffer(self.surface.wl_surface.?, 0, 0, @intCast(self.surface.width), @intCast(self.surface.height));
        c.wl_surface_commit(self.surface.wl_surface.?);
        buffer.markBusy();
        self.surface.dirty = false;
        self.syncGlassRegion() catch {};
    }

    fn acquireBuffer(self: *App, shm: *c.struct_wl_shm) !?*buffer_mod.ShmBuffer {
        for (&self.surface.buffers) |*slot| {
            if (slot.*) |*buffer| {
                if (buffer.width != self.surface.width or buffer.height != self.surface.height) {
                    buffer.deinit();
                    slot.* = null;
                }
            }
        }

        for (&self.surface.buffers) |*slot| {
            if (slot.*) |*buffer| {
                if (!buffer.busy) return buffer;
                continue;
            }

            slot.* = try buffer_mod.ShmBuffer.init(shm, self.surface.width, self.surface.height);
            slot.*.?.installListener();
            return &slot.*.?;
        }

        return null;
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
        const hit = render.hitTest(
            self.surface.width,
            self.surface.height,
            self.pointer_x,
            self.pointer_y,
            self.display_entries.items,
            self.dock_config.style,
            self.slide_offset_y,
        );
        var new_hovered: ?usize = null;
        var new_all_apps_hovered = false;
        switch (hit) {
            .none => {},
            .app => |index| new_hovered = index,
            .all_apps => new_all_apps_hovered = true,
        }
        if (new_hovered != self.hovered_index or new_all_apps_hovered != self.all_apps_hovered) {
            self.hovered_index = new_hovered;
            self.all_apps_hovered = new_all_apps_hovered;
            self.hovered_since_ms = if (new_hovered != null) std.time.milliTimestamp() else 0;
            if (self.previewed_index != null and self.previewed_index != new_hovered) {
                self.hidePreview();
            }
            self.syncPreviewHover();
            self.surface.dirty = true;
        }

        if (self.drag.active) {
            const next_target = self.favoriteDropIndexForPointer();
            if (next_target != self.drag.target_index) {
                self.drag.target_index = next_target;
                self.surface.dirty = true;
            }
        }
    }

    fn refreshOpenAppsIfNeeded(self: *App) !void {
        const now_ms = std.time.milliTimestamp();
        if (now_ms - self.last_runtime_sync_ms < runtime_sync_interval_ms) return;
        self.last_runtime_sync_ms = now_ms;
        try self.refreshOpenApps();
    }

    fn refreshPreferencesIfNeeded(self: *App) !void {
        const now_ms = std.time.milliTimestamp();
        if (now_ms - self.last_preferences_sync_ms < preferences_sync_interval_ms) return;
        self.last_preferences_sync_ms = now_ms;
        try self.reloadDockPreferences();
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
            self.syncGlassRegion() catch {};
            return;
        }

        if (self.refreshDisplayOpenApps()) {
            self.syncPreviewHover();
            self.surface.dirty = true;
        }
    }

    fn reloadDockPreferences(self: *App) !void {
        var loaded = try prefs.load(self.allocator);
        defer loaded.deinit();

        const next = dock_style.configFromPreferences(loaded);
        if (dock_style.eql(next, self.dock_config)) return;

        self.dock_config = next;
        try self.applyLayerPreferences();
        self.surface.dirty = true;
        self.syncGlassRegion() catch {};
    }

    fn applyLayerPreferences(self: *App) !void {
        const layer_surface = self.surface.layer_surface orelse return;
        const wl_surface = self.surface.wl_surface orelse return;
        const preferred_height = self.currentPreferredSurfaceHeight();
        c.zwlr_layer_surface_v1_set_size(layer_surface, 0, preferred_height);
        c.zwlr_layer_surface_v1_set_exclusive_zone(layer_surface, if (self.dock_config.auto_hide) 0 else @intCast(self.dock_config.style.preferredSurfaceHeight()));
        c.wl_surface_commit(wl_surface);
    }

    fn currentPreferredSurfaceHeight(self: *const App) u32 {
        const base = self.dock_config.style.preferredSurfaceHeight();
        return if (self.context_menu.open) base + context_menu_extra_height else base;
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
        try self.icons.syncEntries(self.display_entries.items);
    }

    fn reloadFavorites(self: *App) !void {
        self.favorites.deinit(self.allocator);
        self.favorites = try launcher_state.loadFavoriteEntries(self.allocator, &self.catalog);
        try self.rebuildDisplayEntries();
        self.surface.dirty = true;
    }

    fn applyFavoriteToggleInMemory(self: *App, entry: runtime_catalog.AppEntry, pinned: bool) !void {
        if (pinned) {
            if (!containsEntry(self.favorites.items, entry.id)) {
                try self.favorites.append(self.allocator, entry);
            }
        } else {
            for (self.favorites.items, 0..) |favorite, index| {
                if (!std.mem.eql(u8, favorite.id, entry.id)) continue;
                _ = self.favorites.orderedRemove(index);
                break;
            }
        }

        try self.rebuildDisplayEntries();
        self.surface.dirty = true;
    }

    fn refreshDisplayOpenApps(self: *App) bool {
        var changed = false;
        for (self.display_entries.items, 0..) |entry, index| {
            const next_open = self.openAppForEntry(entry) orelse dock_ipc.OpenAppInfo{};
            if (index >= self.display_open_apps.items.len) break;
            const current = self.display_open_apps.items[index];
            if (!openAppInfoEqual(current, next_open)) {
                self.display_open_apps.items[index] = next_open;
                changed = true;
            }
        }
        return changed;
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

    fn spawnSiblingBinary(self: *App, binary_name: []const u8) !void {
        const env_bin_dir = std.process.getEnvVarOwned(self.allocator, "AXIA_BIN_DIR") catch null;
        defer if (env_bin_dir) |dir| self.allocator.free(dir);

        const binary_path = if (env_bin_dir) |dir|
            try std.fs.path.join(self.allocator, &.{ dir, binary_name })
        else blk: {
            const exe_dir = try std.fs.selfExeDirPathAlloc(self.allocator);
            defer self.allocator.free(exe_dir);
            break :blk try std.fs.path.join(self.allocator, &.{ exe_dir, binary_name });
        };
        defer self.allocator.free(binary_path);

        const argv: []const []const u8 = &.{binary_path};
        var child = std.process.Child.init(argv, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Inherit;
        try child.spawn();
    }

    fn findOpenAppById(self: *const App, app_id: []const u8) ?dock_ipc.OpenAppInfo {
        for (self.open_apps.apps[0..self.open_apps.count]) |open_app| {
            if (std.mem.eql(u8, open_app.idText(), app_id)) return open_app;
        }
        return null;
    }

    fn isAppGridOpen(self: *const App) bool {
        return self.findOpenAppById("axia-app-grid") != null;
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
        app.surface.height = if (height == 0) app.currentPreferredSurfaceHeight() else height;
        app.surface.configured = true;
        app.surface.dirty = true;
        app.syncGlassRegion() catch {};
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
        app.pointer_inside = true;
        app.hide_deadline_ms = 0;
        app.hovered_since_ms = std.time.milliTimestamp();
        app.pointer_x = c.wl_fixed_to_double(surface_x);
        app.pointer_y = c.wl_fixed_to_double(surface_y);
        app.updateHover();
    }

    fn handlePointerLeave(data: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: ?*c.struct_wl_surface) callconv(.c) void {
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        app.pointer_inside = false;
        app.hide_deadline_ms = std.time.milliTimestamp() + auto_hide_grace_ms;
        app.hovered_since_ms = 0;
        app.hovered_index = null;
        app.all_apps_hovered = false;
        app.pressed_hit = .none;
        app.drag.clear();
        app.hidePreview();
        app.surface.dirty = true;
    }

    fn handlePointerMotion(data: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, surface_x: c.wl_fixed_t, surface_y: c.wl_fixed_t) callconv(.c) void {
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        app.pointer_inside = true;
        app.hide_deadline_ms = 0;
        app.pointer_x = c.wl_fixed_to_double(surface_x);
        app.pointer_y = c.wl_fixed_to_double(surface_y);
        app.updateDragState();
        app.updateHover();
    }

    fn handlePointerButton(data: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: u32, button: u32, state: u32) callconv(.c) void {
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        const click_hit = render.hitTest(
            app.surface.width,
            app.surface.height,
            app.pointer_x,
            app.pointer_y,
            app.display_entries.items,
            app.dock_config.style,
            app.slide_offset_y,
        );
        if (button == 0x111 and state == c.WL_POINTER_BUTTON_STATE_PRESSED) {
            app.handleSecondaryPress(click_hit);
            return;
        }

        if (button != 0x110) return;
        switch (state) {
            c.WL_POINTER_BUTTON_STATE_PRESSED => app.handlePrimaryPress(click_hit),
            c.WL_POINTER_BUTTON_STATE_RELEASED => app.handlePrimaryRelease(click_hit),
            else => {},
        }
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

    fn openAppInfoEqual(a: dock_ipc.OpenAppInfo, b: dock_ipc.OpenAppInfo) bool {
        return a.focused == b.focused and
            a.id_len == b.id_len and
            a.title_len == b.title_len and
            std.mem.eql(u8, a.id[0..a.id_len], b.id[0..b.id_len]) and
            std.mem.eql(u8, a.title[0..a.title_len], b.title[0..b.title_len]);
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

        const now_ms = std.time.milliTimestamp();
        if (self.preview_suppressed_until_ms != 0 and now_ms < self.preview_suppressed_until_ms) return;
        if (self.hovered_since_ms == 0 or now_ms - self.hovered_since_ms < preview_hover_delay_ms) return;
        if (self.previewed_index != null and self.previewed_index.? == hovered) return;
        const socket_path = self.ipc_socket_path orelse return;
        const rect = render.itemRect(
            self.surface.width,
            self.surface.height,
            self.display_entries.items.len + 1,
            self.dock_config.style,
            self.slide_offset_y,
            hovered,
        );
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

    fn syncGlassRegion(self: *App) !void {
        if (!self.surface.configured or self.surface.width == 0 or self.surface.height == 0) return;
        const socket_path = self.ipc_socket_path orelse return;
        const hidden_target = self.dock_config.style.hiddenOffset();
        if (self.dock_config.auto_hide and !self.isAppGridOpen() and !self.pointer_inside and self.hovered_index == null and !self.all_apps_hovered and !self.isAnimating() and @abs(self.slide_offset_y - hidden_target) <= 0.25) {
            try dock_ipc.updateGlassRegion(self.allocator, socket_path, 0, 0, 0, 0, @intCast(self.surface.height));
            self.last_glass_box = null;
            self.last_glass_surface_height = @intCast(self.surface.height);
            return;
        }
        const rect = render.containerRect(
            self.surface.width,
            self.surface.height,
            self.display_entries.items.len + 1,
            self.dock_config.style,
            self.slide_offset_y,
        );
        const box = GlassBox{
            .x = @intFromFloat(@round(rect.x)),
            .y = @intFromFloat(@round(rect.y)),
            .width = @intFromFloat(@round(rect.width)),
            .height = @intFromFloat(@round(rect.height)),
        };
        const surface_height: i32 = @intCast(self.surface.height);
        if (self.last_glass_box) |last| {
            if (last.x == box.x and last.y == box.y and last.width == box.width and last.height == box.height and self.last_glass_surface_height == surface_height) {
                return;
            }
        }
        try dock_ipc.updateGlassRegion(
            self.allocator,
            socket_path,
            box.x,
            box.y,
            box.width,
            box.height,
            surface_height,
        );
        self.last_glass_box = box;
        self.last_glass_surface_height = surface_height;
    }

    fn targetSlideOffset(self: *const App) f64 {
        if (!self.dock_config.auto_hide) return 0;
        if (self.isAppGridOpen()) return 0;
        if (self.context_menu.open or self.drag.active) return 0;
        if (self.pointer_inside or self.hovered_index != null or self.all_apps_hovered) return 0;
        const now_ms = std.time.milliTimestamp();
        if (self.hide_deadline_ms != 0 and now_ms < self.hide_deadline_ms) {
            return 0;
        }
        return self.dock_config.style.hiddenOffset();
    }

    fn isAnimating(self: *const App) bool {
        return @abs(self.slide_offset_y - self.targetSlideOffset()) > 0.25;
    }

    fn updateDockAnimation(self: *App) void {
        const target = self.targetSlideOffset();
        const diff = target - self.slide_offset_y;
        if (@abs(diff) <= 0.25) {
            if (@abs(self.slide_offset_y - target) > 0.001) {
                self.slide_offset_y = target;
                self.surface.dirty = true;
                self.syncGlassRegion() catch {};
            }
            self.last_animation_ms = 0;
            return;
        }

        const now_ms = std.time.milliTimestamp();
        if (self.last_animation_ms == 0) self.last_animation_ms = now_ms;
        const dt = @max(now_ms - self.last_animation_ms, 1);
        self.last_animation_ms = now_ms;
        const response_ms: f64 = if (diff > 0) 150.0 else 185.0;
        const easing = @min(1.0, (@as(f64, @floatFromInt(dt)) / response_ms) * 1.12);
        const step = diff * easing;
        self.slide_offset_y += step;
        self.surface.dirty = true;
        self.syncGlassRegion() catch {};
    }

    fn handleSecondaryPress(self: *App, hit: render.HitTarget) void {
        self.hidePreview();
        self.drag.clear();
        self.pressed_hit = .none;

        if (self.context_menu.open) {
            const action = render.contextMenuActionAt(
                self.surface.width,
                self.surface.height,
                self.dock_config.style,
                self.slide_offset_y,
                self.display_entries.items,
                .{ .item_index = self.context_menu.item_index, .pinned = self.context_menu.pinned },
                self.pointer_x,
                self.pointer_y,
            );
            if (action == .toggle_pin) {
                self.togglePinForIndex(self.context_menu.item_index) catch {};
                self.context_menu.open = false;
                self.applyLayerPreferences() catch {};
                self.surface.dirty = true;
                return;
            }
        }

        switch (hit) {
            .app => |index| {
                if (index >= self.display_entries.items.len) return;
                self.context_menu = .{
                    .open = true,
                    .item_index = index,
                    .pinned = index < self.favorites.items.len,
                };
                self.applyLayerPreferences() catch {};
                self.surface.dirty = true;
            },
            else => {
                self.context_menu.open = false;
                self.applyLayerPreferences() catch {};
                self.surface.dirty = true;
            },
        }
    }

    fn handlePrimaryPress(self: *App, hit: render.HitTarget) void {
        self.hidePreview();
        self.preview_suppressed_until_ms = std.time.milliTimestamp() + preview_suppression_after_click_ms;

        if (self.context_menu.open) {
            const action = render.contextMenuActionAt(
                self.surface.width,
                self.surface.height,
                self.dock_config.style,
                self.slide_offset_y,
                self.display_entries.items,
                .{ .item_index = self.context_menu.item_index, .pinned = self.context_menu.pinned },
                self.pointer_x,
                self.pointer_y,
            );
            if (action == .toggle_pin) {
                self.togglePinForIndex(self.context_menu.item_index) catch {};
                self.context_menu.open = false;
                self.applyLayerPreferences() catch {};
                self.surface.dirty = true;
                return;
            }
            self.context_menu.open = false;
            self.applyLayerPreferences() catch {};
            self.surface.dirty = true;
        }

        self.pressed_hit = hit;
        switch (hit) {
            .app => |index| {
                if (index < self.favorites.items.len) {
                    self.drag = .{
                        .pressed_index = index,
                        .source_index = index,
                        .target_index = index,
                        .press_x = self.pointer_x,
                        .press_y = self.pointer_y,
                    };
                }
            },
            else => self.drag.clear(),
        }
    }

    fn handlePrimaryRelease(self: *App, hit: render.HitTarget) void {
        defer {
            self.pressed_hit = .none;
            self.drag.clear();
        }

        if (self.drag.active) {
            self.finishDragReorder() catch {};
            return;
        }

        if (!sameHitTarget(self.pressed_hit, hit)) return;

        switch (hit) {
            .all_apps => self.toggleAppGrid(),
            .app => |index| self.activateEntry(index),
            .none => {},
        }
    }

    fn activateEntry(self: *App, index: usize) void {
        if (index >= self.display_entries.items.len) return;
        const entry = self.display_entries.items[index];
        const open_app = if (index < self.display_open_apps.items.len)
            self.display_open_apps.items[index]
        else
            dock_ipc.OpenAppInfo{};

        launcher_state.recordRecentId(self.allocator, entry.id) catch |err| {
            log.err("failed to persist dock recent app: {}", .{err});
        };

        if (open_app.id_len > 0) {
            const socket_path = self.ipc_socket_path orelse return;
            self.last_runtime_sync_ms = 0;
            if (dock_ipc.focusApp(self.allocator, socket_path, open_app.idText()) catch false) return;
        }

        self.spawnCommand(entry.command) catch |err| {
            log.err("failed to launch dock app: {}", .{err});
        };
        self.last_runtime_sync_ms = 0;
    }

    fn toggleAppGrid(self: *App) void {
        const socket_path = self.ipc_socket_path;
        if (socket_path) |path| {
            dock_ipc.toggleAppGrid(self.allocator, path) catch |err| {
                log.err("failed to toggle app grid via ipc: {}", .{err});
                return;
            };
            self.last_runtime_sync_ms = 0;
            return;
        }

        self.refreshOpenApps() catch {};
        if (self.findOpenAppById("axia-app-grid") != null) return;

        self.spawnSiblingBinary("axia-app-grid") catch |err| {
            log.err("failed to launch app grid: {}", .{err});
        };
    }

    fn togglePinForIndex(self: *App, index: usize) !void {
        if (index >= self.display_entries.items.len) return;
        const entry = self.display_entries.items[index];
        const pinned = index < self.favorites.items.len;
        try launcher_state.setFavoriteEnabled(self.allocator, entry.id, !pinned);
        try self.applyFavoriteToggleInMemory(entry, !pinned);
        self.updateHover();
    }

    fn updateDragState(self: *App) void {
        if (self.drag.pressed_index == null or self.drag.active) {
            if (self.drag.active) {
                const next_target = self.favoriteDropIndexForPointer();
                if (next_target != self.drag.target_index) {
                    self.drag.target_index = next_target;
                    self.surface.dirty = true;
                }
            }
            return;
        }

        const dx = self.pointer_x - self.drag.press_x;
        const dy = self.pointer_y - self.drag.press_y;
        if ((dx * dx + dy * dy) < drag_start_threshold * drag_start_threshold) return;

        self.drag.active = true;
        self.drag.target_index = self.favoriteDropIndexForPointer();
        self.context_menu.open = false;
        self.applyLayerPreferences() catch {};
        self.hovered_index = self.drag.source_index;
        self.surface.dirty = true;
    }

    fn favoriteDropIndexForPointer(self: *const App) usize {
        const favorite_count = self.favorites.items.len;
        if (favorite_count <= 1) return 0;

        var nearest_index: usize = 0;
        var nearest_distance = std.math.inf(f64);
        for (0..favorite_count) |index| {
            const rect = render.itemRect(
                self.surface.width,
                self.surface.height,
                self.display_entries.items.len + 1,
                self.dock_config.style,
                self.slide_offset_y,
                index,
            );
            const center = rect.x + rect.width / 2.0;
            const distance = @abs(self.pointer_x - center);
            if (distance < nearest_distance) {
                nearest_distance = distance;
                nearest_index = index;
            }
        }
        return nearest_index;
    }

    fn finishDragReorder(self: *App) !void {
        if (!self.drag.active) return;
        if (self.drag.source_index >= self.favorites.items.len or self.drag.target_index >= self.favorites.items.len) return;
        if (self.drag.source_index == self.drag.target_index) {
            self.surface.dirty = true;
            return;
        }

        const moved = self.favorites.items[self.drag.source_index];
        const moved_favorite = self.favorites.orderedRemove(self.drag.source_index);
        try self.favorites.insert(self.allocator, self.drag.target_index, moved_favorite);

        const moved_display = self.display_entries.orderedRemove(self.drag.source_index);
        try self.display_entries.insert(self.allocator, self.drag.target_index, moved_display);

        if (self.drag.source_index < self.display_open_apps.items.len) {
            const moved_open = self.display_open_apps.orderedRemove(self.drag.source_index);
            try self.display_open_apps.insert(self.allocator, self.drag.target_index, moved_open);
        }
        try self.icons.syncEntries(self.display_entries.items);
        _ = try launcher_state.moveFavoriteId(self.allocator, moved.id, self.drag.target_index);
        self.surface.dirty = true;
    }

    fn sameHitTarget(a: render.HitTarget, b: render.HitTarget) bool {
        return switch (a) {
            .none => b == .none,
            .all_apps => b == .all_apps,
            .app => |lhs| switch (b) {
                .app => |rhs| lhs == rhs,
                else => false,
            },
        };
    }
};
