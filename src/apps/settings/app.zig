const std = @import("std");
const c = @import("client_wl").c;
const buffer_mod = @import("client_buffer");
const prefs = @import("axia_prefs");
const settings_model = @import("settings_model");
const file_picker = @import("settings_picker");
const ipc = @import("ipc.zig");
const render = @import("render.zig");

const log = std.log.scoped(.axia_settings_app);

pub const App = struct {
    allocator: std.mem.Allocator,
    display: *c.struct_wl_display,
    registry: *c.struct_wl_registry,
    compositor: ?*c.struct_wl_compositor = null,
    shm: ?*c.struct_wl_shm = null,
    wm_base: ?*c.struct_xdg_wm_base = null,
    seat: ?*c.struct_wl_seat = null,
    pointer: ?*c.struct_wl_pointer = null,
    wl_surface: ?*c.struct_wl_surface = null,
    xdg_surface: ?*c.struct_xdg_surface = null,
    toplevel: ?*c.struct_xdg_toplevel = null,
    buffer: ?buffer_mod.ShmBuffer = null,
    running: bool = true,
    configured: bool = false,
    dirty: bool = false,
    current_width: u32 = render.window_width,
    current_height: u32 = render.window_height,
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    scroll_y: f64 = 0,
    scroll_drag_active: bool = false,
    scroll_drag_offset_y: f64 = 0,
    hovered: render.Hit = .none,
    last_button_serial: u32 = 0,
    maximized: bool = false,
    page: settings_model.Page = .wallpapers,
    current_wallpaper_path: ?[]u8 = null,
    preferences: settings_model.PreferencesState = .{},
    runtime: settings_model.RuntimeState = .{},
    ipc_socket_path: ?[]u8 = null,
    registry_listener: c.struct_wl_registry_listener = undefined,
    wm_base_listener: c.struct_xdg_wm_base_listener = undefined,
    xdg_surface_listener: c.struct_xdg_surface_listener = undefined,
    toplevel_listener: c.struct_xdg_toplevel_listener = undefined,
    seat_listener: c.struct_wl_seat_listener = undefined,
    pointer_listener: c.struct_wl_pointer_listener = undefined,

    pub fn create(allocator: std.mem.Allocator, initial_page: settings_model.Page) !*App {
        const app = try allocator.create(App);
        errdefer allocator.destroy(app);

        const display = c.wl_display_connect(null) orelse return error.WaylandConnectFailed;
        errdefer c.wl_display_disconnect(display);
        const registry = c.wl_display_get_registry(display) orelse return error.RegistryGetFailed;

        app.* = .{
            .allocator = allocator,
            .display = display,
            .registry = registry,
            .page = initial_page,
        };

        const maybe_socket = std.process.getEnvVarOwned(allocator, "AXIA_IPC_SOCKET") catch null;
        if (maybe_socket) |socket| app.ipc_socket_path = socket;

        var loaded_prefs = try prefs.load(allocator);
        defer loaded_prefs.deinit();
        app.preferences = preferencesStateFromStored(loaded_prefs);
        if (loaded_prefs.wallpaper_path) |path| {
            app.current_wallpaper_path = try allocator.dupe(u8, path);
        }
        app.refreshRuntimeState();

        app.registry_listener = .{ .global = handleGlobal, .global_remove = handleGlobalRemove };
        _ = c.wl_registry_add_listener(registry, &app.registry_listener, app);
        if (c.wl_display_roundtrip(display) < 0) return error.RoundtripFailed;
        if (c.wl_display_roundtrip(display) < 0) return error.RoundtripFailed;
        if (app.compositor == null or app.shm == null or app.wm_base == null) return error.RequiredGlobalsMissing;

        try app.createWindow();
        return app;
    }

    pub fn destroy(self: *App) void {
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }

    fn deinit(self: *App) void {
        if (self.buffer) |*buffer| buffer.deinit();
        if (self.pointer) |pointer| c.wl_pointer_destroy(pointer);
        if (self.seat) |seat| c.wl_seat_destroy(seat);
        if (self.toplevel) |toplevel| c.xdg_toplevel_destroy(toplevel);
        if (self.xdg_surface) |xdg_surface| c.xdg_surface_destroy(xdg_surface);
        if (self.wl_surface) |wl_surface| c.wl_surface_destroy(wl_surface);
        if (self.wm_base) |wm_base| c.xdg_wm_base_destroy(wm_base);
        if (self.shm) |shm| c.wl_shm_destroy(shm);
        if (self.compositor) |compositor| c.wl_compositor_destroy(compositor);
        if (self.current_wallpaper_path) |path| self.allocator.free(path);
        if (self.ipc_socket_path) |path| self.allocator.free(path);
        c.wl_registry_destroy(self.registry);
        c.wl_display_disconnect(self.display);
    }

    pub fn run(self: *App) !void {
        while (self.running) {
            if (self.dirty) try self.redraw();
            if (c.wl_display_dispatch(self.display) < 0) return error.DisplayDispatchFailed;
        }
    }

    fn createWindow(self: *App) !void {
        const compositor = self.compositor orelse return error.CompositorMissing;
        const wm_base = self.wm_base orelse return error.WmBaseMissing;

        const wl_surface = c.wl_compositor_create_surface(compositor) orelse return error.SurfaceCreateFailed;
        errdefer c.wl_surface_destroy(wl_surface);
        const xdg_surface = c.xdg_wm_base_get_xdg_surface(wm_base, wl_surface) orelse return error.XdgSurfaceCreateFailed;
        errdefer c.xdg_surface_destroy(xdg_surface);
        const toplevel = c.xdg_surface_get_toplevel(xdg_surface) orelse return error.XdgToplevelCreateFailed;
        errdefer c.xdg_toplevel_destroy(toplevel);

        c.xdg_toplevel_set_title(toplevel, "Configurações");
        c.xdg_toplevel_set_app_id(toplevel, "axia-settings");

        self.wm_base_listener = .{ .ping = handlePing };
        self.xdg_surface_listener = .{ .configure = handleXdgConfigure };
        self.toplevel_listener = .{
            .configure = handleToplevelConfigure,
            .close = handleToplevelClose,
            .configure_bounds = handleConfigureBounds,
            .wm_capabilities = handleWmCapabilities,
        };
        _ = c.xdg_wm_base_add_listener(wm_base, &self.wm_base_listener, self);
        _ = c.xdg_surface_add_listener(xdg_surface, &self.xdg_surface_listener, self);
        _ = c.xdg_toplevel_add_listener(toplevel, &self.toplevel_listener, self);

        self.wl_surface = wl_surface;
        self.xdg_surface = xdg_surface;
        self.toplevel = toplevel;
        self.dirty = true;
        c.wl_surface_commit(wl_surface);
    }

    fn redraw(self: *App) !void {
        if (!self.configured or !self.dirty) return;
        const shm = self.shm orelse return error.ShmMissing;
        if (self.buffer) |*buffer| buffer.deinit();
        self.buffer = try buffer_mod.ShmBuffer.init(shm, self.current_width, self.current_height, "axia-settings");

        const buffer = &self.buffer.?;
        render.draw(buffer.cr, self.current_width, self.current_height, .{
            .page = self.page,
            .hovered = self.hovered,
            .current_wallpaper_path = self.current_wallpaper_path,
            .preferences = self.preferences,
            .runtime = self.runtime,
            .scroll_y = self.scroll_y,
        });
        c.cairo_surface_flush(buffer.surface);
        c.wl_surface_attach(self.wl_surface.?, buffer.buffer, 0, 0);
        c.wl_surface_damage_buffer(self.wl_surface.?, 0, 0, @intCast(self.current_width), @intCast(self.current_height));
        c.wl_surface_commit(self.wl_surface.?);
        self.dirty = false;
    }

    fn applyWallpaper(self: *App, path: []const u8) !void {
        if (self.ipc_socket_path) |socket| {
            ipc.setWallpaper(self.allocator, socket, path) catch |err| {
                log.err("failed to send wallpaper over ipc: {}", .{err});
            };
        }

        if (self.current_wallpaper_path) |existing| self.allocator.free(existing);
        self.current_wallpaper_path = try self.allocator.dupe(u8, path);
        try self.savePreferences();
        self.dirty = true;
    }

    fn updateHover(self: *App) void {
        const new_hovered = render.hitTest(
            self.current_width,
            self.current_height,
            self.pointer_x,
            self.pointer_y,
            .{
                .page = self.page,
                .hovered = self.hovered,
                .current_wallpaper_path = self.current_wallpaper_path,
                .preferences = self.preferences,
                .runtime = self.runtime,
                .scroll_y = self.scroll_y,
            },
        );
        if (!hitEquals(new_hovered, self.hovered)) {
            self.hovered = new_hovered;
            self.dirty = true;
        }
    }

    fn setPage(self: *App, page: settings_model.Page) void {
        self.page = page;
        self.scroll_y = 0;
        self.hovered = .none;
        if (page == .displays or page == .workspaces or page == .about) {
            self.refreshRuntimeState();
        }
        self.dirty = true;
    }

    fn handleAction(self: *App) void {
        switch (self.hovered) {
            .none => {},
            .titlebar => {
                const toplevel = self.toplevel orelse return;
                const seat = self.seat orelse return;
                c.xdg_toplevel_move(toplevel, seat, self.last_button_serial);
            },
            .minimize => {
                const toplevel = self.toplevel orelse return;
                c.xdg_toplevel_set_minimized(toplevel);
            },
            .maximize => {
                const toplevel = self.toplevel orelse return;
                if (self.maximized) c.xdg_toplevel_unset_maximized(toplevel) else c.xdg_toplevel_set_maximized(toplevel);
            },
            .close => self.running = false,
            .nav => |page| self.setPage(page),
            .wallpaper_preset => |index| {
                const preset = settings_model.wallpaper_presets[index];
                self.applyWallpaper(preset.path) catch |err| {
                    log.err("failed to apply preset wallpaper: {}", .{err});
                };
            },
            .browser_manual => {
                self.openWallpaperPicker() catch |err| {
                    log.err("failed to open wallpaper picker: {}", .{err});
                };
            },
            .accent_preset => |preset| {
                self.preferences.accent = preset;
                self.savePreferences() catch |err| {
                    log.err("failed to save appearance settings: {}", .{err});
                };
            },
            .reduce_transparency => {
                self.preferences.reduce_transparency = !self.preferences.reduce_transparency;
                self.savePreferences() catch |err| {
                    log.err("failed to save appearance settings: {}", .{err});
                };
            },
            .panel_show_seconds => {
                self.preferences.panel_show_seconds = !self.preferences.panel_show_seconds;
                self.savePreferences() catch |err| {
                    log.err("failed to save panel settings: {}", .{err});
                };
            },
            .panel_show_date => {
                self.preferences.panel_show_date = !self.preferences.panel_show_date;
                self.savePreferences() catch |err| {
                    log.err("failed to save panel settings: {}", .{err});
                };
            },
            .dock_size => |preset| {
                self.preferences.dock_size = preset;
                self.savePreferences() catch |err| {
                    log.err("failed to save dock settings: {}", .{err});
                };
            },
            .dock_icon_size => |preset| {
                self.preferences.dock_icon_size = preset;
                self.savePreferences() catch |err| {
                    log.err("failed to save dock settings: {}", .{err});
                };
            },
            .dock_auto_hide => {
                self.preferences.dock_auto_hide = !self.preferences.dock_auto_hide;
                self.savePreferences() catch |err| {
                    log.err("failed to save dock settings: {}", .{err});
                };
            },
            .dock_strong_hover => {
                self.preferences.dock_strong_hover = !self.preferences.dock_strong_hover;
                self.savePreferences() catch |err| {
                    log.err("failed to save dock settings: {}", .{err});
                };
            },
            .workspace_wrap => {
                self.preferences.workspace_wrap = !self.preferences.workspace_wrap;
                self.savePreferences() catch |err| {
                    log.err("failed to save workspace settings: {}", .{err});
                };
                if (self.ipc_socket_path) |socket| {
                    ipc.setWorkspaceWrap(self.allocator, socket, self.preferences.workspace_wrap) catch |err| {
                        log.err("failed to update workspace wrap over ipc: {}", .{err});
                    };
                }
                self.refreshRuntimeState();
            },
            .startup_workspace => |index| {
                self.preferences.startup_workspace = index;
                self.savePreferences() catch |err| {
                    log.err("failed to save startup workspace: {}", .{err});
                };
                if (self.ipc_socket_path) |socket| {
                    ipc.activateWorkspace(self.allocator, socket, index) catch |err| {
                        log.err("failed to activate workspace over ipc: {}", .{err});
                    };
                }
                self.refreshRuntimeState();
            },
            .scroll_thumb => {
                const thumb = render.scrollThumbRect(self.current_width, self.current_height, scrollState(self));
                self.scroll_drag_active = true;
                self.scroll_drag_offset_y = self.pointer_y - thumb.y;
            },
            .scroll_track => {
                const thumb = render.scrollThumbRect(self.current_width, self.current_height, scrollState(self));
                self.scroll_drag_active = true;
                self.scroll_drag_offset_y = thumb.height / 2.0;
                updateScrollFromPointer(self);
            },
        }
        self.dirty = true;
    }

    fn savePreferences(self: *App) !void {
        var stored = prefs.Preferences{
            .allocator = self.allocator,
            .accent = storedAccentFromSettings(self.preferences.accent),
            .reduce_transparency = self.preferences.reduce_transparency,
            .panel_show_seconds = self.preferences.panel_show_seconds,
            .panel_show_date = self.preferences.panel_show_date,
            .dock_size = switch (self.preferences.dock_size) {
                .compact => .compact,
                .comfortable => .comfortable,
                .large => .large,
            },
            .dock_icon_size = switch (self.preferences.dock_icon_size) {
                .small => .small,
                .medium => .medium,
                .large => .large,
            },
            .dock_auto_hide = self.preferences.dock_auto_hide,
            .dock_strong_hover = self.preferences.dock_strong_hover,
            .workspace_wrap = self.preferences.workspace_wrap,
            .startup_workspace = self.preferences.startup_workspace,
        };
        defer stored.deinit();

        if (self.current_wallpaper_path) |path| {
            stored.wallpaper_path = try self.allocator.dupe(u8, path);
        }

        try stored.save();
    }

    fn refreshRuntimeState(self: *App) void {
        const socket = self.ipc_socket_path orelse return;
        self.runtime = ipc.getRuntimeState(self.allocator, socket) catch self.runtime;
    }

    fn openWallpaperPicker(self: *App) !void {
        const selected_path = try file_picker.pickImagePath(self.allocator) orelse return;
        defer self.allocator.free(selected_path);
        try self.applyWallpaper(selected_path);
    }

    fn setSeat(self: *App, seat: *c.struct_wl_seat) void {
        self.seat = seat;
        self.seat_listener = .{ .capabilities = handleSeatCapabilities, .name = handleSeatName };
        _ = c.wl_seat_add_listener(seat, &self.seat_listener, self);
    }

    fn handleGlobal(data: ?*anyopaque, _: ?*c.struct_wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        const interface_name = std.mem.span(interface);

        if (std.mem.eql(u8, interface_name, std.mem.span(c.wl_compositor_interface.name))) {
            app.compositor = @ptrCast(c.wl_registry_bind(app.registry, name, &c.wl_compositor_interface, @min(version, 6)));
        } else if (std.mem.eql(u8, interface_name, std.mem.span(c.wl_shm_interface.name))) {
            app.shm = @ptrCast(c.wl_registry_bind(app.registry, name, &c.wl_shm_interface, 1));
        } else if (std.mem.eql(u8, interface_name, std.mem.span(c.xdg_wm_base_interface.name))) {
            app.wm_base = @ptrCast(c.wl_registry_bind(app.registry, name, &c.xdg_wm_base_interface, 3));
        } else if (std.mem.eql(u8, interface_name, std.mem.span(c.wl_seat_interface.name))) {
            const seat: *c.struct_wl_seat = @ptrCast(c.wl_registry_bind(app.registry, name, &c.wl_seat_interface, @min(version, 5)));
            app.setSeat(seat);
        }
    }

    fn handleGlobalRemove(_: ?*anyopaque, _: ?*c.struct_wl_registry, _: u32) callconv(.c) void {}
    fn handlePing(_: ?*anyopaque, wm_base: ?*c.struct_xdg_wm_base, serial: u32) callconv(.c) void { c.xdg_wm_base_pong(wm_base, serial); }

    fn handleXdgConfigure(data: ?*anyopaque, xdg_surface: ?*c.struct_xdg_surface, serial: u32) callconv(.c) void {
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        c.xdg_surface_ack_configure(xdg_surface, serial);
        app.configured = true;
        app.dirty = true;
    }

    fn handleToplevelConfigure(data: ?*anyopaque, _: ?*c.struct_xdg_toplevel, width_arg: i32, height_arg: i32, states: [*c]c.struct_wl_array) callconv(.c) void {
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        if (width_arg > 0) app.current_width = @intCast(width_arg);
        if (height_arg > 0) app.current_height = @intCast(height_arg);
        app.maximized = hasState(states, c.XDG_TOPLEVEL_STATE_MAXIMIZED);
        clampScroll(app);
        app.dirty = true;
    }

    fn handleToplevelClose(data: ?*anyopaque, _: ?*c.struct_xdg_toplevel) callconv(.c) void {
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        app.running = false;
    }

    fn handleConfigureBounds(_: ?*anyopaque, _: ?*c.struct_xdg_toplevel, _: i32, _: i32) callconv(.c) void {}
    fn handleWmCapabilities(_: ?*anyopaque, _: ?*c.struct_xdg_toplevel, _: [*c]c.struct_wl_array) callconv(.c) void {}

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

    fn handlePointerEnter(data: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: ?*c.struct_wl_surface, sx: c.wl_fixed_t, sy: c.wl_fixed_t) callconv(.c) void {
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        app.pointer_x = c.wl_fixed_to_double(sx);
        app.pointer_y = c.wl_fixed_to_double(sy);
        app.updateHover();
    }

    fn handlePointerLeave(data: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: ?*c.struct_wl_surface) callconv(.c) void {
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        app.scroll_drag_active = false;
        app.hovered = .none;
        app.dirty = true;
    }

    fn handlePointerMotion(data: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, sx: c.wl_fixed_t, sy: c.wl_fixed_t) callconv(.c) void {
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        app.pointer_x = c.wl_fixed_to_double(sx);
        app.pointer_y = c.wl_fixed_to_double(sy);
        if (app.scroll_drag_active) {
            updateScrollFromPointer(app);
            return;
        }
        app.updateHover();
    }

    fn handlePointerButton(data: ?*anyopaque, _: ?*c.struct_wl_pointer, serial: u32, _: u32, button: u32, state: u32) callconv(.c) void {
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        if (button != 0x110) return;
        if (state == c.WL_POINTER_BUTTON_STATE_RELEASED) {
            app.scroll_drag_active = false;
            return;
        }
        if (state != c.WL_POINTER_BUTTON_STATE_PRESSED) return;
        app.last_button_serial = serial;
        app.handleAction();
    }

    fn handlePointerAxis(data: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, axis: u32, value: c.wl_fixed_t) callconv(.c) void {
        if (axis != c.WL_POINTER_AXIS_VERTICAL_SCROLL) return;
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        const delta = c.wl_fixed_to_double(value);
        if (@abs(delta) < 0.001) return;
        scrollBy(app, -delta * 32.0);
    }

    fn handlePointerFrame(_: ?*anyopaque, _: ?*c.struct_wl_pointer) callconv(.c) void {}
    fn handlePointerAxisSource(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32) callconv(.c) void {}
    fn handlePointerAxisStop(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: u32) callconv(.c) void {}
    fn handlePointerAxisDiscrete(data: ?*anyopaque, _: ?*c.struct_wl_pointer, axis: u32, discrete: i32) callconv(.c) void {
        if (axis != c.WL_POINTER_AXIS_VERTICAL_SCROLL or discrete == 0) return;
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        scrollBy(app, -@as(f64, @floatFromInt(discrete)) * 56.0);
    }

    fn handlePointerAxisValue120(data: ?*anyopaque, _: ?*c.struct_wl_pointer, axis: u32, value120: i32) callconv(.c) void {
        if (axis != c.WL_POINTER_AXIS_VERTICAL_SCROLL or value120 == 0) return;
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        scrollBy(app, -(@as(f64, @floatFromInt(value120)) / 120.0) * 56.0);
    }
    fn handlePointerAxisRelativeDirection(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: u32) callconv(.c) void {}
};

fn hasState(states: [*c]c.struct_wl_array, target: u32) bool {
    if (states == null or states.*.data == null) return false;
    const len = @divExact(states.*.size, @sizeOf(u32));
    const values: [*]const u32 = @ptrCast(@alignCast(states.*.data));
    for (values[0..len]) |value| {
        if (value == target) return true;
    }
    return false;
}

fn hitEquals(a: render.Hit, b: render.Hit) bool {
    return switch (a) {
        .none => b == .none,
        .titlebar => b == .titlebar,
        .minimize => b == .minimize,
        .maximize => b == .maximize,
        .close => b == .close,
        .nav => b == .nav and a.nav == b.nav,
        .wallpaper_preset => b == .wallpaper_preset and a.wallpaper_preset == b.wallpaper_preset,
        .browser_manual => b == .browser_manual,
        .accent_preset => b == .accent_preset and a.accent_preset == b.accent_preset,
        .reduce_transparency => b == .reduce_transparency,
        .panel_show_seconds => b == .panel_show_seconds,
        .panel_show_date => b == .panel_show_date,
        .dock_size => b == .dock_size and a.dock_size == b.dock_size,
        .dock_icon_size => b == .dock_icon_size and a.dock_icon_size == b.dock_icon_size,
        .dock_auto_hide => b == .dock_auto_hide,
        .dock_strong_hover => b == .dock_strong_hover,
        .workspace_wrap => b == .workspace_wrap,
        .startup_workspace => b == .startup_workspace and a.startup_workspace == b.startup_workspace,
        .scroll_thumb => b == .scroll_thumb,
        .scroll_track => b == .scroll_track,
    };
}

fn preferencesStateFromStored(stored: prefs.Preferences) settings_model.PreferencesState {
    return .{
        .accent = settingsAccentFromStored(stored.accent),
        .reduce_transparency = stored.reduce_transparency,
        .panel_show_seconds = stored.panel_show_seconds,
        .panel_show_date = stored.panel_show_date,
        .dock_size = switch (stored.dock_size) {
            .compact => .compact,
            .comfortable => .comfortable,
            .large => .large,
        },
        .dock_icon_size = switch (stored.dock_icon_size) {
            .small => .small,
            .medium => .medium,
            .large => .large,
        },
        .dock_auto_hide = stored.dock_auto_hide,
        .dock_strong_hover = stored.dock_strong_hover,
        .workspace_wrap = stored.workspace_wrap,
        .startup_workspace = stored.startup_workspace,
    };
}

fn settingsAccentFromStored(accent: prefs.AccentPreset) settings_model.AccentPreset {
    return switch (accent) {
        .aurora => .aurora,
        .ember => .ember,
        .moss => .moss,
    };
}

fn storedAccentFromSettings(accent: settings_model.AccentPreset) prefs.AccentPreset {
    return switch (accent) {
        .aurora => .aurora,
        .ember => .ember,
        .moss => .moss,
    };
}

fn scrollState(app: *App) render.State {
    return .{
        .page = app.page,
        .hovered = app.hovered,
        .current_wallpaper_path = app.current_wallpaper_path,
        .preferences = app.preferences,
        .runtime = app.runtime,
        .scroll_y = app.scroll_y,
    };
}

fn clampScroll(app: *App) void {
    const max_scroll = render.maxScroll(app.current_width, app.current_height, scrollState(app));
    app.scroll_y = std.math.clamp(app.scroll_y, 0.0, max_scroll);
}

fn scrollBy(app: *App, delta: f64) void {
    if (!render.scrollViewportRect(app.current_width, app.current_height).contains(app.pointer_x, app.pointer_y)) return;
    const previous = app.scroll_y;
    app.scroll_y += delta;
    clampScroll(app);
    if (@abs(app.scroll_y - previous) < 0.001) return;
    app.updateHover();
    app.dirty = true;
}

fn updateScrollFromPointer(app: *App) void {
    const track = render.scrollTrackRect(app.current_width, app.current_height);
    const thumb = render.scrollThumbRect(app.current_width, app.current_height, scrollState(app));
    const max_scroll = render.maxScroll(app.current_width, app.current_height, scrollState(app));
    if (max_scroll <= 0.0) return;

    const available = @max(0.0, track.height - thumb.height);
    if (available <= 0.0) return;

    const desired_y = std.math.clamp(app.pointer_y - app.scroll_drag_offset_y, track.y, track.y + available);
    const progress = (desired_y - track.y) / available;
    app.scroll_y = progress * max_scroll;
    clampScroll(app);
    app.updateHover();
    app.dirty = true;
}
