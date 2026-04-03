const std = @import("std");
const c = @import("client_wl").c;
const buffer_mod = @import("client_buffer");
const browser = @import("browser.zig");
const icons = @import("icons.zig");
const render = @import("render.zig");

const log = std.log.scoped(.axia_files);

const width: u32 = 920;
const height: u32 = 580;

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
    current_width: u32 = width,
    current_height: u32 = height,
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    hovered: render.Hit = .none,
    last_button_serial: u32 = 0,
    maximized: bool = false,
    sidebar_collapsed: bool = false,
    browser: browser.Browser,
    icons: icons.SidebarIcons,
    registry_listener: c.struct_wl_registry_listener = undefined,
    wm_base_listener: c.struct_xdg_wm_base_listener = undefined,
    xdg_surface_listener: c.struct_xdg_surface_listener = undefined,
    toplevel_listener: c.struct_xdg_toplevel_listener = undefined,
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
            .browser = browser.Browser.init(allocator),
            .icons = try icons.SidebarIcons.init(allocator),
        };

        app.registry_listener = .{ .global = handleGlobal, .global_remove = handleGlobalRemove };
        _ = c.wl_registry_add_listener(registry, &app.registry_listener, app);

        if (c.wl_display_roundtrip(display) < 0) return error.RoundtripFailed;
        if (c.wl_display_roundtrip(display) < 0) return error.RoundtripFailed;

        if (app.compositor == null or app.shm == null or app.wm_base == null) return error.RequiredGlobalsMissing;

        try app.browser.ensureDefaultDirectory();
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
        self.icons.deinit();
        self.browser.deinit();
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

        c.xdg_toplevel_set_title(toplevel, "Axia Files");
        c.xdg_toplevel_set_app_id(toplevel, "axia-files");

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
        self.buffer = try buffer_mod.ShmBuffer.init(shm, self.current_width, self.current_height, "axia-files");

        const buffer = &self.buffer.?;
        render.draw(
            buffer.cr,
            self.current_width,
            self.current_height,
            self.browser.snapshot(),
            self.hovered,
            self.sidebar_collapsed,
            &self.icons,
        );
        c.cairo_surface_flush(buffer.surface);
        c.wl_surface_attach(self.wl_surface.?, buffer.buffer, 0, 0);
        c.wl_surface_damage_buffer(self.wl_surface.?, 0, 0, @intCast(self.current_width), @intCast(self.current_height));
        c.wl_surface_commit(self.wl_surface.?);
        self.dirty = false;
    }

    fn updateHover(self: *App) void {
        const new_hovered = render.hitTest(
            self.current_width,
            self.current_height,
            self.pointer_x,
            self.pointer_y,
            self.browser.snapshot(),
            self.sidebar_collapsed,
        );
        if (!hitEquals(new_hovered, self.hovered)) {
            self.hovered = new_hovered;
            self.dirty = true;
        }
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
                if (self.maximized) {
                    c.xdg_toplevel_unset_maximized(toplevel);
                } else {
                    c.xdg_toplevel_set_maximized(toplevel);
                }
            },
            .close => self.running = false,
            .toggle_sidebar => self.sidebar_collapsed = !self.sidebar_collapsed,
            .up => self.browser.goParent() catch {},
            .previous => self.browser.previousPage(),
            .next => self.browser.nextPage(),
            .sort_modified => self.browser.toggleModifiedSort(),
            .sidebar => |target| self.browser.openSidebar(target) catch {},
            .entry => |index| self.browser.activateVisible(index) catch {},
        }
        self.dirty = true;
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
    fn handlePing(data: ?*anyopaque, wm_base: ?*c.struct_xdg_wm_base, serial: u32) callconv(.c) void {
        _ = data;
        c.xdg_wm_base_pong(wm_base, serial);
    }
    fn handleXdgConfigure(data: ?*anyopaque, xdg_surface: ?*c.struct_xdg_surface, serial: u32) callconv(.c) void {
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        c.xdg_surface_ack_configure(xdg_surface, serial);
        app.configured = true;
        app.dirty = true;
        app.redraw() catch |err| log.err("failed to draw files app: {}", .{err});
    }
    fn handleToplevelConfigure(data: ?*anyopaque, _: ?*c.struct_xdg_toplevel, width_arg: i32, height_arg: i32, states: [*c]c.struct_wl_array) callconv(.c) void {
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        if (width_arg > 0) app.current_width = @intCast(width_arg);
        if (height_arg > 0) app.current_height = @intCast(height_arg);
        app.maximized = hasState(states, c.XDG_TOPLEVEL_STATE_MAXIMIZED);
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
        app.redraw() catch {};
    }
    fn handlePointerLeave(data: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: ?*c.struct_wl_surface) callconv(.c) void {
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        app.hovered = .none;
        app.dirty = true;
        app.redraw() catch {};
    }
    fn handlePointerMotion(data: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, sx: c.wl_fixed_t, sy: c.wl_fixed_t) callconv(.c) void {
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        app.pointer_x = c.wl_fixed_to_double(sx);
        app.pointer_y = c.wl_fixed_to_double(sy);
        app.updateHover();
        app.redraw() catch {};
    }
    fn handlePointerButton(data: ?*anyopaque, _: ?*c.struct_wl_pointer, serial: u32, _: u32, button: u32, state: u32) callconv(.c) void {
        if (state != c.WL_POINTER_BUTTON_STATE_PRESSED or button != 0x110) return;
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        app.last_button_serial = serial;
        app.handleAction();
        app.updateHover();
        app.redraw() catch {};
    }
    fn handlePointerAxis(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: u32, _: c.wl_fixed_t) callconv(.c) void {}
    fn handlePointerFrame(_: ?*anyopaque, _: ?*c.struct_wl_pointer) callconv(.c) void {}
    fn handlePointerAxisSource(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32) callconv(.c) void {}
    fn handlePointerAxisStop(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: u32) callconv(.c) void {}
    fn handlePointerAxisDiscrete(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: i32) callconv(.c) void {}
    fn handlePointerAxisValue120(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: i32) callconv(.c) void {}
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

fn hitEquals(lhs: render.Hit, rhs: render.Hit) bool {
    return switch (lhs) {
        .none => rhs == .none,
        .titlebar => rhs == .titlebar,
        .minimize => rhs == .minimize,
        .maximize => rhs == .maximize,
        .close => rhs == .close,
        .toggle_sidebar => rhs == .toggle_sidebar,
        .up => rhs == .up,
        .previous => rhs == .previous,
        .next => rhs == .next,
        .sort_modified => rhs == .sort_modified,
        .sidebar => |left_target| switch (rhs) {
            .sidebar => |right_target| left_target == right_target,
            else => false,
        },
        .entry => |left_index| switch (rhs) {
            .entry => |right_index| left_index == right_index,
            else => false,
        },
    };
}
