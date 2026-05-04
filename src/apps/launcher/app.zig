const std = @import("std");
const c = @import("client_wl").c;
const buffer_mod = @import("client_buffer");
const runtime_catalog = @import("runtime_catalog");
const launcher_state = @import("launcher_state");
const model = @import("model.zig");
const render = @import("render.zig");

const log = std.log.scoped(.axia_launcher);

const width: u32 = 760;
const height: u32 = 432;

pub const App = struct {
    allocator: std.mem.Allocator,
    display: *c.struct_wl_display,
    registry: *c.struct_wl_registry,
    compositor: ?*c.struct_wl_compositor = null,
    shm: ?*c.struct_wl_shm = null,
    wm_base: ?*c.struct_xdg_wm_base = null,
    seat: ?*c.struct_wl_seat = null,
    pointer: ?*c.struct_wl_pointer = null,
    keyboard: ?*c.struct_wl_keyboard = null,
    wl_surface: ?*c.struct_wl_surface = null,
    xdg_surface: ?*c.struct_xdg_surface = null,
    toplevel: ?*c.struct_xdg_toplevel = null,
    buffer: ?buffer_mod.ShmBuffer = null,
    xkb_context: ?*c.struct_xkb_context = null,
    xkb_keymap: ?*c.struct_xkb_keymap = null,
    xkb_state: ?*c.struct_xkb_state = null,
    configured: bool = false,
    running: bool = true,
    dirty: bool = true,
    current_width: u32 = width,
    current_height: u32 = height,
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    hovered_index: ?usize = null,
    frame_callback: ?*c.struct_wl_callback = null,
    frame_pending: bool = false,
    launcher: model.State = .{},
    catalog: runtime_catalog.Catalog,
    state_store: launcher_state.State,
    pinned_entries: std.ArrayListUnmanaged(runtime_catalog.AppEntry) = .empty,
    registry_listener: c.struct_wl_registry_listener = undefined,
    wm_base_listener: c.struct_xdg_wm_base_listener = undefined,
    xdg_surface_listener: c.struct_xdg_surface_listener = undefined,
    toplevel_listener: c.struct_xdg_toplevel_listener = undefined,
    seat_listener: c.struct_wl_seat_listener = undefined,
    pointer_listener: c.struct_wl_pointer_listener = undefined,
    keyboard_listener: c.struct_wl_keyboard_listener = undefined,
    frame_listener: c.struct_wl_callback_listener = undefined,

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
            .state_store = undefined,
        };
        try app.catalog.loadDefault();
        app.state_store = try launcher_state.load(allocator);
        try app.state_store.ensureDefaultLauncherPins(&app.catalog);
        app.pinned_entries = try app.state_store.launcherPinEntries(allocator, &app.catalog);

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
        self.clearXkb();
        if (self.keyboard) |keyboard| c.wl_keyboard_destroy(keyboard);
        if (self.pointer) |pointer| c.wl_pointer_destroy(pointer);
        if (self.seat) |seat| c.wl_seat_destroy(seat);
        if (self.frame_callback) |callback| c.wl_callback_destroy(callback);
        if (self.toplevel) |toplevel| c.xdg_toplevel_destroy(toplevel);
        if (self.xdg_surface) |xdg_surface| c.xdg_surface_destroy(xdg_surface);
        if (self.wl_surface) |wl_surface| c.wl_surface_destroy(wl_surface);
        if (self.wm_base) |wm_base| c.xdg_wm_base_destroy(wm_base);
        if (self.shm) |shm| c.wl_shm_destroy(shm);
        if (self.compositor) |compositor| c.wl_compositor_destroy(compositor);
        self.pinned_entries.deinit(self.allocator);
        self.state_store.deinit();
        self.catalog.deinit();
        c.wl_registry_destroy(self.registry);
        c.wl_display_disconnect(self.display);
    }

    pub fn run(self: *App) !void {
        while (self.running) {
            if (self.dirty and !self.frame_pending) try self.redraw();
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

        c.xdg_toplevel_set_title(toplevel, "Aplicativos");
        c.xdg_toplevel_set_app_id(toplevel, "axia-launcher");

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
        if (!self.configured) return;
        const shm = self.shm orelse return error.ShmMissing;
        const compositor = self.compositor orelse return error.CompositorMissing;
        if (self.buffer) |*buffer| {
            if (buffer.width != self.current_width or buffer.height != self.current_height) {
                buffer.deinit();
                self.buffer = null;
            }
        }
        if (self.buffer == null) {
            self.buffer = try buffer_mod.ShmBuffer.init(shm, self.current_width, self.current_height, "axia-launcher");
        }
        const buffer = &self.buffer.?;
        var snapshot = self.launcher.snapshotWithEntries(self.catalog.entries.items, self.pinned_entries.items, render.visibleResultLimit(self.current_height));
        self.applyFavoriteFlags(&snapshot);
        const card = render.cardRect(self.current_width, self.current_height, snapshot);
        render.draw(buffer.cr, self.current_width, self.current_height, snapshot, self.hovered_index);
        c.cairo_surface_flush(buffer.surface);

        const region = c.wl_compositor_create_region(compositor) orelse return error.RegionCreateFailed;
        defer c.wl_region_destroy(region);
        c.wl_region_add(
            region,
            @intFromFloat(card.x),
            @intFromFloat(card.y),
            @intFromFloat(card.width),
            @intFromFloat(card.height),
        );
        c.wl_surface_set_input_region(self.wl_surface.?, region);

        c.wl_surface_attach(self.wl_surface.?, buffer.buffer, 0, 0);
        c.wl_surface_damage_buffer(self.wl_surface.?, 0, 0, @intCast(self.current_width), @intCast(self.current_height));
        const callback = c.wl_surface_frame(self.wl_surface.?) orelse return error.FrameCallbackCreateFailed;
        self.frame_listener = .{ .done = handleFrameDone };
        _ = c.wl_callback_add_listener(callback, &self.frame_listener, self);
        self.frame_callback = callback;
        self.frame_pending = true;
        c.wl_surface_commit(self.wl_surface.?);
        self.dirty = false;
    }

    fn spawnCommand(self: *App, command: []const u8) !void {
        const argv: []const []const u8 = &.{ "sh", "-lc", command };
        var child = std.process.Child.init(argv, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        try child.spawn();
        self.running = false;
    }

    fn launchCatalogIndex(self: *App, index: usize) void {
        if (index >= self.catalog.entries.items.len) return;
        const entry = self.catalog.entries.items[index];
        if (!entry.enabled or entry.command.len == 0) return;
        self.state_store.recordRecent(entry.id) catch |err| {
            log.err("failed to persist launcher recent app: {}", .{err});
        };
        self.state_store.save() catch |err| {
            log.err("failed to save launcher state: {}", .{err});
        };
        self.spawnCommand(entry.command) catch |err| {
            log.err("failed to launch app: {}", .{err});
        };
    }

    fn toggleFavoriteCatalogIndex(self: *App, index: usize) void {
        if (index >= self.catalog.entries.items.len) return;
        const entry = self.catalog.entries.items[index];
        if (entry.id.len == 0) return;

        _ = self.state_store.toggleLauncherPin(entry.id) catch |err| {
            log.err("failed to toggle launcher pin: {}", .{err});
            return;
        };
        self.state_store.save() catch |err| {
            log.err("failed to save launcher pins: {}", .{err});
            return;
        };
        self.reloadPinnedEntries() catch |err| {
            log.err("failed to refresh launcher pins: {}", .{err});
        };
        self.dirty = true;
    }

    fn reloadPinnedEntries(self: *App) !void {
        const next_entries = try self.state_store.launcherPinEntries(self.allocator, &self.catalog);
        self.pinned_entries.deinit(self.allocator);
        self.pinned_entries = next_entries;
    }

    fn applyFavoriteFlags(self: *const App, snapshot: *model.Snapshot) void {
        for (0..snapshot.count) |index| {
            const catalog_index = snapshot.entries[index].catalog_index;
            if (catalog_index >= self.catalog.entries.items.len) continue;
            snapshot.entries[index].favorite = self.state_store.isLauncherPinned(self.catalog.entries.items[catalog_index].id);
        }
    }

    fn updateHover(self: *App) void {
        const snapshot = self.launcher.snapshotWithEntries(self.catalog.entries.items, self.pinned_entries.items, render.visibleResultLimit(self.current_height));
        const hovered = render.hitTest(self.current_width, self.current_height, self.pointer_x, self.pointer_y, snapshot);
        if (hovered != self.hovered_index) {
            self.hovered_index = hovered;
            self.dirty = true;
        }
    }

    fn setSeat(self: *App, seat: *c.struct_wl_seat) void {
        self.seat = seat;
        self.seat_listener = .{ .capabilities = handleSeatCapabilities, .name = handleSeatName };
        _ = c.wl_seat_add_listener(seat, &self.seat_listener, self);
    }

    fn clearXkb(self: *App) void {
        if (self.xkb_state) |state| c.xkb_state_unref(state);
        if (self.xkb_keymap) |keymap| c.xkb_keymap_unref(keymap);
        if (self.xkb_context) |context| c.xkb_context_unref(context);
        self.xkb_state = null;
        self.xkb_keymap = null;
        self.xkb_context = null;
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

    fn handlePing(_: ?*anyopaque, wm_base: ?*c.struct_xdg_wm_base, serial: u32) callconv(.c) void {
        c.xdg_wm_base_pong(wm_base, serial);
    }

    fn handleXdgConfigure(data: ?*anyopaque, xdg_surface: ?*c.struct_xdg_surface, serial: u32) callconv(.c) void {
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        c.xdg_surface_ack_configure(xdg_surface, serial);
        app.configured = true;
        app.dirty = true;
    }

    fn handleToplevelConfigure(data: ?*anyopaque, _: ?*c.struct_xdg_toplevel, width_arg: i32, height_arg: i32, _: [*c]c.struct_wl_array) callconv(.c) void {
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        if (width_arg > 0) app.current_width = @intCast(width_arg);
        if (height_arg > 0) app.current_height = @intCast(height_arg);
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

        if ((capabilities & c.WL_SEAT_CAPABILITY_KEYBOARD) != 0 and app.keyboard == null) {
            const wl_seat = app.seat orelse return;
            const keyboard = c.wl_seat_get_keyboard(wl_seat) orelse return;
            app.keyboard = keyboard;
            app.keyboard_listener = .{
                .keymap = handleKeyboardKeymap,
                .enter = handleKeyboardEnter,
                .leave = handleKeyboardLeave,
                .key = handleKeyboardKey,
                .modifiers = handleKeyboardModifiers,
                .repeat_info = handleKeyboardRepeatInfo,
            };
            _ = c.wl_keyboard_add_listener(keyboard, &app.keyboard_listener, app);
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
        app.hovered_index = null;
        app.dirty = true;
    }

    fn handlePointerMotion(data: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, sx: c.wl_fixed_t, sy: c.wl_fixed_t) callconv(.c) void {
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        app.pointer_x = c.wl_fixed_to_double(sx);
        app.pointer_y = c.wl_fixed_to_double(sy);
        app.updateHover();
    }

    fn handlePointerButton(data: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: u32, button: u32, state: u32) callconv(.c) void {
        if (state != c.WL_POINTER_BUTTON_STATE_PRESSED or button != 0x110) return;
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        const snapshot = app.launcher.snapshotWithEntries(app.catalog.entries.items, app.pinned_entries.items, render.visibleResultLimit(app.current_height));
        if (render.favoriteHitTest(app.current_width, app.current_height, app.pointer_x, app.pointer_y, snapshot)) |favorite_index| {
            if (favorite_index >= snapshot.count) return;
            app.toggleFavoriteCatalogIndex(snapshot.entries[favorite_index].catalog_index);
            return;
        }

        const hovered = app.hovered_index orelse return;
        if (hovered >= snapshot.count) return;
        app.launchCatalogIndex(snapshot.entries[hovered].catalog_index);
    }

    fn handlePointerAxis(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: u32, _: c.wl_fixed_t) callconv(.c) void {}
    fn handlePointerFrame(_: ?*anyopaque, _: ?*c.struct_wl_pointer) callconv(.c) void {}
    fn handlePointerAxisSource(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32) callconv(.c) void {}
    fn handlePointerAxisStop(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: u32) callconv(.c) void {}
    fn handlePointerAxisDiscrete(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: i32) callconv(.c) void {}
    fn handlePointerAxisValue120(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: i32) callconv(.c) void {}
    fn handlePointerAxisRelativeDirection(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: u32) callconv(.c) void {}

    fn handleKeyboardKeymap(data: ?*anyopaque, _: ?*c.struct_wl_keyboard, format: u32, fd: i32, size: u32) callconv(.c) void {
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        defer _ = c.close(fd);

        if (format != c.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) return;

        const keymap_memory = c.mmap(null, size, c.PROT_READ, c.MAP_PRIVATE, fd, 0);
        if (keymap_memory == c.MAP_FAILED) return;
        defer _ = c.munmap(keymap_memory, size);

        if (app.xkb_context == null) {
            app.xkb_context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);
        }

        const context = app.xkb_context orelse return;
        if (app.xkb_state) |state| c.xkb_state_unref(state);
        if (app.xkb_keymap) |keymap| c.xkb_keymap_unref(keymap);

        const keymap_string: [*c]const u8 = @ptrCast(keymap_memory);
        app.xkb_keymap = c.xkb_keymap_new_from_string(
            context,
            keymap_string,
            c.XKB_KEYMAP_FORMAT_TEXT_V1,
            c.XKB_KEYMAP_COMPILE_NO_FLAGS,
        );
        if (app.xkb_keymap == null) return;

        app.xkb_state = c.xkb_state_new(app.xkb_keymap);
    }

    fn handleKeyboardEnter(_: ?*anyopaque, _: ?*c.struct_wl_keyboard, _: u32, _: ?*c.struct_wl_surface, _: ?*c.struct_wl_array) callconv(.c) void {}
    fn handleKeyboardLeave(_: ?*anyopaque, _: ?*c.struct_wl_keyboard, _: u32, _: ?*c.struct_wl_surface) callconv(.c) void {}

    fn handleKeyboardKey(data: ?*anyopaque, _: ?*c.struct_wl_keyboard, _: u32, _: u32, key: u32, state: u32) callconv(.c) void {
        if (state != c.WL_KEYBOARD_KEY_STATE_PRESSED) return;
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        const xkb_state = app.xkb_state orelse return;

        const keycode: c.xkb_keycode_t = key + 8;
        const keysym = c.xkb_state_key_get_one_sym(xkb_state, keycode);

        switch (keysym) {
            c.XKB_KEY_Escape => {
                app.running = false;
                return;
            },
            c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => {
                const catalog_index = app.launcher.selectedCatalogIndexWithEntries(app.catalog.entries.items, app.pinned_entries.items, render.visibleResultLimit(app.current_height)) orelse return;
                app.launchCatalogIndex(catalog_index);
                return;
            },
            c.XKB_KEY_Up => app.launcher.moveSelectionWithEntries(app.catalog.entries.items, app.pinned_entries.items, render.visibleResultLimit(app.current_height), -1),
            c.XKB_KEY_Down => app.launcher.moveSelectionWithEntries(app.catalog.entries.items, app.pinned_entries.items, render.visibleResultLimit(app.current_height), 1),
            c.XKB_KEY_BackSpace => app.launcher.backspace(),
            else => {
                var utf8_buf = [_]u8{0} ** 64;
                const written = c.xkb_state_key_get_utf8(
                    xkb_state,
                    keycode,
                    @ptrCast(&utf8_buf[0]),
                    utf8_buf.len,
                );
                if (written > 0) {
                    const text = std.mem.sliceTo(utf8_buf[0..], 0);
                    app.launcher.appendText(text);
                } else {
                    return;
                }
            },
        }

        app.hovered_index = null;
        app.dirty = true;
    }

    fn handleKeyboardModifiers(data: ?*anyopaque, _: ?*c.struct_wl_keyboard, _: u32, mods_depressed: u32, mods_latched: u32, mods_locked: u32, group: u32) callconv(.c) void {
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        const state = app.xkb_state orelse return;
        _ = c.xkb_state_update_mask(state, mods_depressed, mods_latched, mods_locked, 0, 0, group);
    }

    fn handleKeyboardRepeatInfo(_: ?*anyopaque, _: ?*c.struct_wl_keyboard, _: i32, _: i32) callconv(.c) void {}

    fn handleFrameDone(data: ?*anyopaque, callback: ?*c.struct_wl_callback, _: u32) callconv(.c) void {
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        if (callback != null) {
            c.wl_callback_destroy(callback);
        }
        app.frame_callback = null;
        app.frame_pending = false;
        if (app.dirty) {
            app.redraw() catch |err| log.err("failed to redraw launcher app: {}", .{err});
        }
    }
};
