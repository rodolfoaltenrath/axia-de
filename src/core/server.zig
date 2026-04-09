const std = @import("std");
const c = @import("../wl.zig").c;
const ProtocolGlobals = @import("protocols.zig").ProtocolGlobals;
const Output = @import("output.zig").Output;
const SceneManager = @import("../render/scene.zig").SceneManager;
const GlassManager = @import("../render/glass/manager.zig").Manager;
const InputManager = @import("../input/manager.zig").InputManager;
const LayerManager = @import("../layers/manager.zig").LayerManager;
const PanelProcess = @import("../panel/process.zig").PanelProcess;
const DockProcess = @import("../dock/process.zig").DockProcess;
const LauncherProcess = @import("../apps/launcher/process.zig").LauncherProcess;
const XdgManager = @import("../shell/xdg.zig").XdgManager;
const DecorationManager = @import("../shell/decoration.zig").DecorationManager;
const IpcServer = @import("../ipc/server.zig").IpcServer;
const IpcWorkspaceSnapshot = @import("../ipc/server.zig").WorkspaceSnapshot;
const WallpaperAsset = @import("../render/wallpaper.zig").WallpaperAsset;
const DesktopMenu = @import("../desktop/menu.zig").DesktopMenu;
const DesktopAction = @import("../desktop/actions.zig").Action;
const SettingsManager = @import("../settings/manager.zig").SettingsManager;
const settings_model = @import("../settings/model.zig");
const SettingsPage = settings_model.Page;
const SettingsRuntimeState = settings_model.RuntimeState;
const SettingsPreferencesState = settings_model.PreferencesState;
const Preferences = @import("../config/preferences.zig");

const log = std.log.scoped(.axia);

pub const Server = struct {
    allocator: std.mem.Allocator,
    display: *c.struct_wl_display,
    event_loop: *c.struct_wl_event_loop,
    backend: [*c]c.struct_wlr_backend,
    renderer: [*c]c.struct_wlr_renderer,
    buffer_allocator: [*c]c.struct_wlr_allocator,
    protocols: ProtocolGlobals,
    output_layout: [*c]c.struct_wlr_output_layout,
    scene: SceneManager,
    glass: GlassManager,
    socket_name: [*c]const u8,
    outputs: std.ArrayListUnmanaged(*Output) = .empty,
    new_output: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    listeners_ready: bool = false,
    input: InputManager,
    layers: LayerManager,
    panel: PanelProcess,
    dock: DockProcess,
    launcher: LauncherProcess,
    xdg: XdgManager,
    decorations: DecorationManager,
    ipc: IpcServer,
    wallpaper: ?*WallpaperAsset,
    desktop_menu: DesktopMenu,
    settings: SettingsManager,
    settings_prefs: SettingsPreferencesState,
    dock_glass_surface_box: ?c.struct_wlr_box = null,
    dock_surface_height: i32 = 0,

    pub fn init(allocator: std.mem.Allocator) !Server {
        c.wlr_log_init(c.WLR_ERROR, null);

        const display = c.wl_display_create() orelse return error.WaylandDisplayCreateFailed;
        errdefer c.wl_display_destroy(display);

        const output_layout = c.wlr_output_layout_create(display);
        if (output_layout == null) return error.OutputLayoutCreateFailed;
        errdefer c.wlr_output_layout_destroy(output_layout);

        const event_loop = c.wl_display_get_event_loop(display) orelse return error.WaylandEventLoopCreateFailed;

        const backend = c.wlr_backend_autocreate(event_loop, null);
        if (backend == null) return error.BackendCreateFailed;

        const renderer = c.wlr_renderer_autocreate(backend);
        if (renderer == null) return error.RendererCreateFailed;
        errdefer c.wlr_renderer_destroy(renderer);

        if (!c.wlr_renderer_init_wl_display(renderer, display)) {
            return error.RendererDisplayInitFailed;
        }

        const buffer_allocator = c.wlr_allocator_autocreate(backend, renderer);
        if (buffer_allocator == null) return error.AllocatorCreateFailed;
        errdefer c.wlr_allocator_destroy(buffer_allocator);

        const protocols = try ProtocolGlobals.init(display, renderer);

        const socket_name = c.wl_display_add_socket_auto(display);
        if (socket_name == null) return error.WaylandSocketCreateFailed;

        var scene = try SceneManager.init(output_layout);
        errdefer scene.deinit();

        var glass = GlassManager.init(
            allocator,
            output_layout,
            scene.glassEffectRoot(),
        );
        errdefer glass.deinit();

        var input = try InputManager.init(allocator, display, output_layout);
        errdefer input.deinit();

        var layers = try LayerManager.init(
            allocator,
            event_loop,
            input.seat,
            output_layout,
            scene.backgroundRoot(),
            scene.bottomLayerRoot(),
            scene.topLayerRoot(),
            scene.overlayLayerRoot(),
            protocols.layer_shell,
        );
        errdefer layers.deinit();

        const panel = PanelProcess.init(allocator);
        const dock = DockProcess.init(allocator);
        const launcher = LauncherProcess.init(allocator);

        var xdg = try XdgManager.init(
            allocator,
            input.seat,
            output_layout,
            scene.windowRoot(),
            scene.overlayLayerRoot(),
            display,
        );
        errdefer xdg.deinit();

        var decorations = try DecorationManager.init(allocator, display);
        errdefer decorations.deinit();

        var ipc = IpcServer.init(allocator);
        errdefer ipc.deinit();

        var preferences = try Preferences.load(allocator);
        defer preferences.deinit();
        const settings_prefs: SettingsPreferencesState = .{
            .accent = switch (preferences.accent) {
                .aurora => .aurora,
                .ember => .ember,
                .moss => .moss,
            },
            .reduce_transparency = preferences.reduce_transparency,
            .panel_show_seconds = preferences.panel_show_seconds,
            .panel_show_date = preferences.panel_show_date,
            .dock_size = switch (preferences.dock_size) {
                .compact => .compact,
                .comfortable => .comfortable,
                .large => .large,
            },
            .dock_icon_size = switch (preferences.dock_icon_size) {
                .small => .small,
                .medium => .medium,
                .large => .large,
            },
            .dock_auto_hide = preferences.dock_auto_hide,
            .dock_strong_hover = preferences.dock_strong_hover,
            .workspace_wrap = preferences.workspace_wrap,
            .startup_workspace = preferences.startup_workspace,
        };

        const wallpaper = blk: {
            if (preferences.wallpaper_path) |path| {
                break :blk WallpaperAsset.loadFromPath(allocator, path) catch |err| {
                    log.err("failed to load configured wallpaper, falling back: {}", .{err});
                    break :blk try WallpaperAsset.loadDefault(allocator);
                };
            }
            break :blk try WallpaperAsset.loadDefault(allocator);
        };
        errdefer if (wallpaper) |asset| asset.deinit();

        const desktop_menu = DesktopMenu.init(
            allocator,
            output_layout,
            scene.overlayLayerRoot(),
        );

        var settings = SettingsManager.init(
            allocator,
            output_layout,
            scene.overlayLayerRoot(),
        );
        errdefer settings.deinit();

        if (wallpaper) |asset| {
            try settings.setCurrentWallpaperPath(asset.source_path);
        }

        xdg.setWorkspaceWrap(settings_prefs.workspace_wrap);
        xdg.activateWorkspace(settings_prefs.startup_workspace);

        log.info("Wayland socket ready at {s}", .{std.mem.span(socket_name)});

        return .{
            .allocator = allocator,
            .display = display,
            .event_loop = event_loop,
            .backend = backend,
            .renderer = renderer,
            .buffer_allocator = buffer_allocator,
            .protocols = protocols,
            .output_layout = output_layout,
            .scene = scene,
            .glass = glass,
            .socket_name = socket_name,
            .input = input,
            .layers = layers,
            .panel = panel,
            .dock = dock,
            .launcher = launcher,
            .xdg = xdg,
            .decorations = decorations,
            .ipc = ipc,
            .wallpaper = wallpaper,
            .desktop_menu = desktop_menu,
            .settings = settings,
            .settings_prefs = settings_prefs,
        };
    }

    pub fn setupListeners(self: *Server) void {
        self.new_output.notify = handleNewOutput;
        c.wl_signal_add(&self.backend.*.events.new_output, &self.new_output);
        self.listeners_ready = true;
        self.input.setupListeners(self.backend);
        self.input.setPointerCallbacks(self, handlePointerMotion, handlePointerButton);
        self.input.setShortcutHandler(self, handleShortcut);
        self.layers.setLayoutCallback(self, handleLayerLayoutChanged);
        self.layers.setupListeners();
        self.xdg.setupListeners();
        self.decorations.setupListeners();
        self.ipc.setWorkspaceCallbacks(
            self,
            ipcGetWorkspaceState,
            ipcActivateWorkspace,
            ipcMoveFocusedWorkspace,
            ipcSetWallpaper,
            ipcToggleLauncher,
            ipcGetRuntimeState,
            ipcSetWorkspaceWrap,
            ipcFocusApp,
            ipcCloseApp,
            ipcShowPreview,
            ipcHidePreview,
            ipcUpdateDockGlass,
        );
        self.desktop_menu.setActionCallback(self, handleDesktopAction);
        self.settings.setApplyWallpaperCallback(self, handleApplyWallpaper);
    }

    pub fn deinit(self: *Server) void {
        _ = self.event_loop;

        if (self.listeners_ready) {
            c.wl_list_remove(&self.new_output.link);
        }

        for (self.outputs.items) |output| {
            output.detach();
            self.allocator.destroy(output);
        }
        self.outputs.deinit(self.allocator);

        self.xdg.deinit();
        self.decorations.deinit();
        self.ipc.deinit();
        self.layers.deinit();
        self.panel.deinit();
        self.dock.deinit();
        self.launcher.deinit();
        self.input.deinit();
        if (self.wallpaper) |wallpaper| wallpaper.deinit();
        self.desktop_menu.deinit();
        self.settings.deinit();
        self.glass.deinit();

        self.scene.deinit();
        _ = self.protocols;
        c.wlr_output_layout_destroy(self.output_layout);
        c.wlr_allocator_destroy(self.buffer_allocator);
        c.wlr_renderer_destroy(self.renderer);
        c.wl_display_destroy_clients(self.display);
        c.wl_display_destroy(self.display);
    }

    pub fn run(self: *Server) !void {
        try self.ipc.start(self.event_loop, self.socket_name);

        if (!c.wlr_backend_start(self.backend)) {
            return error.BackendStartFailed;
        }

        self.panel.spawn(self.socket_name, self.ipc.path());
        self.dock.spawn(self.socket_name, self.ipc.path());
        log.info("Axia-DE core is running on WAYLAND_DISPLAY={s}", .{std.mem.span(self.socket_name)});
        c.wl_display_run(self.display);
    }

    fn registerOutput(self: *Server, wlr_output: [*c]c.struct_wlr_output) !void {
        const output = try Output.create(
            self.allocator,
            self.display,
            self.renderer,
            self.buffer_allocator,
            self.output_layout,
            self.scene.scene,
            self.scene.output_layout_link,
            self.scene.backgroundRoot(),
            self.wallpaper,
            wlr_output,
            self,
            unregisterOutputCallback,
        );
        errdefer self.allocator.destroy(output);

        try self.outputs.append(self.allocator, output);
        try output.setup();

        if (self.xdg.primary_output == null) {
            self.xdg.setPrimaryOutput(wlr_output);
        }
        if (self.layers.primary_output == null) {
            self.layers.setPrimaryOutput(wlr_output);
        }
        if (self.desktop_menu.primary_output == null) {
            self.desktop_menu.setPrimaryOutput(wlr_output);
        }
        if (self.settings.primary_output == null) {
            self.settings.setPrimaryOutput(wlr_output);
        }
        self.xdg.setUsableArea(self.layers.getUsableArea());
        self.syncGlassRegions();
    }

    fn unregisterOutput(self: *Server, target: *Output) void {
        for (self.outputs.items, 0..) |output, index| {
            if (output == target) {
                _ = self.outputs.swapRemove(index);
                return;
            }
        }
    }

    fn handleNewOutput(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const server: *Server = @ptrCast(@as(*allowzero Server, @fieldParentPtr("new_output", listener)));
        const raw_output = data orelse return;
        const wlr_output: [*c]c.struct_wlr_output = @ptrCast(@alignCast(raw_output));

        server.registerOutput(wlr_output) catch |err| {
            log.err("failed to register output: {}", .{err});
        };
    }

    fn unregisterOutputCallback(ctx: ?*anyopaque, output: *Output) void {
        const server = ctx orelse return;
        const typed: *Server = @ptrCast(@alignCast(server));
        typed.unregisterOutput(output);
    }

    fn handlePointerMotion(ctx: ?*anyopaque, time_msec: u32, lx: f64, ly: f64) void {
        const raw_server = ctx orelse return;
        const server: *Server = @ptrCast(@alignCast(raw_server));
        if (server.layers.handlePointerMotion(time_msec, lx, ly)) return;
        if (server.settings.handlePointerMotion(lx, ly)) return;
        if (server.desktop_menu.handlePointerMotion(lx, ly)) return;
        server.xdg.handlePointerMotion(time_msec, lx, ly);
    }

    fn handlePointerButton(
        ctx: ?*anyopaque,
        time_msec: u32,
        button: u32,
        state: c.enum_wl_pointer_button_state,
        lx: f64,
        ly: f64,
    ) void {
        const raw_server = ctx orelse return;
        const server: *Server = @ptrCast(@alignCast(raw_server));
        if (state == c.WL_POINTER_BUTTON_STATE_PRESSED) {
            server.xdg.dismissLauncherIfOutside(lx, ly);
        }
        if (server.layers.handlePointerButton(time_msec, button, state, lx, ly)) return;
        if (server.settings.handlePointerButton(button, state, lx, ly)) return;
        if (server.desktop_menu.handlePointerButton(button, state, lx, ly)) return;
        if (!server.xdg.hasHitAt(lx, ly) and state == c.WL_POINTER_BUTTON_STATE_PRESSED and button == 0x111) {
            server.xdg.clearDesktopFocus();
            server.desktop_menu.showAt(lx, ly) catch |err| {
                log.err("failed to show desktop menu: {}", .{err});
            };
            return;
        }
        server.xdg.handlePointerButton(time_msec, button, state, lx, ly, server.input.currentModifiers());
    }

    fn handleLayerLayoutChanged(ctx: ?*anyopaque, usable_area: c.struct_wlr_box) void {
        const raw_server = ctx orelse return;
        const server: *Server = @ptrCast(@alignCast(raw_server));
        server.xdg.setUsableArea(usable_area);
        server.syncGlassRegions();
    }

    fn syncGlassRegions(self: *Server) void {
        const output = if (self.layers.primary_output) |primary|
            primary
        else
            self.xdg.primary_output orelse return;
        var full_area = std.mem.zeroes(c.struct_wlr_box);
        c.wlr_output_layout_get_box(self.output_layout, output, &full_area);
        if (full_area.width <= 0 or full_area.height <= 0) return;

        const usable_area = self.layers.getUsableArea();
        const top_inset = usable_area.y - full_area.y;
        if (top_inset > 0) {
            const top_bar_box = c.struct_wlr_box{
                .x = full_area.x,
                .y = full_area.y,
                .width = full_area.width,
                .height = top_inset,
            };
            self.glass.registerRegion(.top_bar, output, top_bar_box) catch {};
            self.glass.refreshOutput(output, self.wallpaper) catch |err| {
                log.err("failed to refresh top bar glass region: {}", .{err});
            };
        } else {
            self.glass.removeRegion(.top_bar, output);
        }

        if (self.dock_glass_surface_box) |surface_box| {
            const absolute = c.struct_wlr_box{
                .x = full_area.x + surface_box.x,
                .y = full_area.y + full_area.height - self.dock_surface_height + surface_box.y,
                .width = surface_box.width,
                .height = surface_box.height,
            };
            self.glass.registerRegion(.dock, output, absolute) catch {};
            self.glass.refreshOutput(output, self.wallpaper) catch |err| {
                log.err("failed to refresh dock glass region: {}", .{err});
            };
        } else {
            self.glass.removeRegion(.dock, output);
        }
    }

    fn ipcUpdateDockGlass(ctx: ?*anyopaque, surface_box: c.struct_wlr_box, surface_height: i32) void {
        const raw_server = ctx orelse return;
        const server: *Server = @ptrCast(@alignCast(raw_server));
        if (surface_box.width <= 0 or surface_box.height <= 0) {
            server.dock_glass_surface_box = null;
            server.dock_surface_height = surface_height;
            server.syncGlassRegions();
            return;
        }
        server.dock_glass_surface_box = surface_box;
        server.dock_surface_height = surface_height;
        server.syncGlassRegions();
    }

    fn handleShortcut(ctx: ?*anyopaque, modifiers: u32, sym: c.xkb_keysym_t) bool {
        const raw_server = ctx orelse return false;
        const server: *Server = @ptrCast(@alignCast(raw_server));

        if (sym == c.XKB_KEY_space and (modifiers & c.WLR_MODIFIER_ALT) != 0) {
            server.toggleLauncher();
            return true;
        }

        if (sym == c.XKB_KEY_space and (modifiers & c.WLR_MODIFIER_LOGO) != 0) {
            server.toggleLauncher();
            return true;
        }

        if ((modifiers & c.WLR_MODIFIER_LOGO) == 0) return false;

        if (sym >= c.XKB_KEY_1 and sym <= c.XKB_KEY_4) {
            const workspace_index: usize = @intCast(sym - c.XKB_KEY_1);
            if ((modifiers & c.WLR_MODIFIER_SHIFT) != 0) {
                server.xdg.moveFocusedViewToWorkspace(workspace_index);
            } else {
                server.xdg.activateWorkspace(workspace_index);
            }
            return true;
        }

        return switch (sym) {
            c.XKB_KEY_Tab => blk: {
                server.xdg.cycleWorkspace();
                break :blk true;
            },
            else => false,
        };
    }

    fn ipcGetWorkspaceState(ctx: ?*anyopaque) IpcWorkspaceSnapshot {
        const raw_server = ctx orelse return .{ .current = 0, .count = 0 };
        const server: *Server = @ptrCast(@alignCast(raw_server));
        return server.xdg.workspaceSnapshot();
    }

    fn ipcActivateWorkspace(ctx: ?*anyopaque, workspace_index: usize) void {
        const raw_server = ctx orelse return;
        const server: *Server = @ptrCast(@alignCast(raw_server));
        server.xdg.activateWorkspace(workspace_index);
    }

    fn ipcMoveFocusedWorkspace(ctx: ?*anyopaque, workspace_index: usize) void {
        const raw_server = ctx orelse return;
        const server: *Server = @ptrCast(@alignCast(raw_server));
        server.xdg.moveFocusedViewToWorkspace(workspace_index);
    }

    fn ipcSetWallpaper(ctx: ?*anyopaque, path: []const u8) void {
        const raw_server = ctx orelse return;
        const server: *Server = @ptrCast(@alignCast(raw_server));
        server.applyWallpaper(path) catch |err| {
            log.err("failed to apply wallpaper via ipc: {}", .{err});
        };
    }

    fn ipcToggleLauncher(ctx: ?*anyopaque) void {
        const raw_server = ctx orelse return;
        const server: *Server = @ptrCast(@alignCast(raw_server));
        server.toggleLauncher();
    }

    fn ipcGetRuntimeState(ctx: ?*anyopaque) SettingsRuntimeState {
        const raw_server = ctx orelse return .{};
        const server: *Server = @ptrCast(@alignCast(raw_server));
        return server.runtimeStateSnapshot();
    }

    fn ipcSetWorkspaceWrap(ctx: ?*anyopaque, enabled: bool) void {
        const raw_server = ctx orelse return;
        const server: *Server = @ptrCast(@alignCast(raw_server));
        server.setWorkspaceWrap(enabled) catch |err| {
            log.err("failed to set workspace wrap: {}", .{err});
        };
    }

    fn ipcFocusApp(ctx: ?*anyopaque, app_id: []const u8) bool {
        const raw_server = ctx orelse return false;
        const server: *Server = @ptrCast(@alignCast(raw_server));
        return server.focusApp(app_id);
    }

    fn ipcCloseApp(ctx: ?*anyopaque, app_id: []const u8) bool {
        const raw_server = ctx orelse return false;
        const server: *Server = @ptrCast(@alignCast(raw_server));
        return server.closeApp(app_id);
    }

    fn ipcShowPreview(ctx: ?*anyopaque, app_id: []const u8, anchor_x: i32) void {
        const raw_server = ctx orelse return;
        const server: *Server = @ptrCast(@alignCast(raw_server));
        server.xdg.showAppPreview(app_id, anchor_x) catch |err| {
            log.err("failed to show app preview: {}", .{err});
        };
    }

    fn ipcHidePreview(ctx: ?*anyopaque) void {
        const raw_server = ctx orelse return;
        const server: *Server = @ptrCast(@alignCast(raw_server));
        server.xdg.hideAppPreview();
    }

    fn handleDesktopAction(ctx: ?*anyopaque, action: DesktopAction) void {
        const raw_server = ctx orelse return;
        const server: *Server = @ptrCast(@alignCast(raw_server));
        const page: SettingsPage = switch (action) {
            .wallpapers => .wallpapers,
            .appearance => .appearance,
            .panel => .panel,
            .displays => .displays,
            .workspaces => .workspaces,
            .about => .about,
        };
        server.spawnSettingsApp(page);
    }

    fn handleApplyWallpaper(ctx: ?*anyopaque, path: []const u8) void {
        const raw_server = ctx orelse return;
        const server: *Server = @ptrCast(@alignCast(raw_server));
        server.applyWallpaper(path) catch |err| {
            log.err("failed to apply wallpaper: {}", .{err});
        };
    }

    fn applyWallpaper(self: *Server, path: []const u8) !void {
        const new_wallpaper = try WallpaperAsset.loadFromPath(self.allocator, path);
        errdefer new_wallpaper.deinit();

        for (self.outputs.items) |output| {
            try output.setWallpaper(new_wallpaper);
            self.glass.markOutputDirty(output.wlr_output);
            try self.glass.refreshOutput(output.wlr_output, new_wallpaper);
        }

        const old_wallpaper = self.wallpaper;
        self.wallpaper = new_wallpaper;
        try self.settings.setCurrentWallpaperPath(new_wallpaper.source_path);
        try Preferences.saveWallpaper(self.allocator, path);
        if (old_wallpaper) |wallpaper| wallpaper.deinit();
        log.info("wallpaper applied: {s}", .{path});
    }

    fn toggleLauncher(self: *Server) void {
        if (self.xdg.dismissLauncher()) return;
        self.launcher.spawn(self.socket_name, self.ipc.path());
    }

    fn runtimeStateSnapshot(self: *const Server) SettingsRuntimeState {
        var snapshot = SettingsRuntimeState{};
        const workspace = self.xdg.workspaceSnapshot();
        snapshot.workspace_current = workspace.current;
        snapshot.workspace_count = workspace.count;
        snapshot.socket_name_len = copyText(&snapshot.socket_name, std.mem.span(self.socket_name));

        snapshot.display_count = @min(self.outputs.items.len, snapshot.displays.len);
        for (self.outputs.items[0..snapshot.display_count], 0..) |output, index| {
            const display = &snapshot.displays[index];
            const name = std.mem.span(output.wlr_output.*.name);
            display.name_len = copyText(&display.name, name);
            display.width = @intCast(@max(output.wlr_output.*.width, 0));
            display.height = @intCast(@max(output.wlr_output.*.height, 0));
            display.primary = self.xdg.primary_output != null and self.xdg.primary_output.? == output.wlr_output;
        }

        self.xdg.populateRuntimeApps(&snapshot);

        return snapshot;
    }

    fn focusApp(self: *Server, app_id: []const u8) bool {
        return self.xdg.focusAppById(app_id);
    }

    fn closeApp(self: *Server, app_id: []const u8) bool {
        return self.xdg.closeAppById(app_id);
    }

    fn setWorkspaceWrap(self: *Server, enabled: bool) !void {
        self.settings_prefs.workspace_wrap = enabled;
        self.xdg.setWorkspaceWrap(enabled);
        try self.persistSettingsPreferences();
    }

    fn persistSettingsPreferences(self: *Server) !void {
        var prefs = Preferences.Preferences{
            .allocator = self.allocator,
            .accent = switch (self.settings_prefs.accent) {
                .aurora => .aurora,
                .ember => .ember,
                .moss => .moss,
            },
            .reduce_transparency = self.settings_prefs.reduce_transparency,
            .panel_show_seconds = self.settings_prefs.panel_show_seconds,
            .panel_show_date = self.settings_prefs.panel_show_date,
            .dock_size = switch (self.settings_prefs.dock_size) {
                .compact => .compact,
                .comfortable => .comfortable,
                .large => .large,
            },
            .dock_icon_size = switch (self.settings_prefs.dock_icon_size) {
                .small => .small,
                .medium => .medium,
                .large => .large,
            },
            .dock_auto_hide = self.settings_prefs.dock_auto_hide,
            .dock_strong_hover = self.settings_prefs.dock_strong_hover,
            .workspace_wrap = self.settings_prefs.workspace_wrap,
            .startup_workspace = self.settings_prefs.startup_workspace,
        };
        defer prefs.deinit();

        if (self.wallpaper) |wallpaper| {
            prefs.wallpaper_path = try self.allocator.dupe(u8, wallpaper.source_path);
        }

        try prefs.save();
    }

    fn spawnSettingsApp(self: *Server, page: SettingsPage) void {
        const exe_dir = std.fs.selfExeDirPathAlloc(self.allocator) catch |err| {
            log.err("failed to resolve exe dir for settings app: {}", .{err});
            return;
        };
        defer self.allocator.free(exe_dir);

        const settings_path = std.fs.path.join(self.allocator, &.{ exe_dir, "axia-settings" }) catch |err| {
            log.err("failed to build settings app path: {}", .{err});
            return;
        };
        defer self.allocator.free(settings_path);

        const page_arg = settingsPageArg(page);
        const argv = self.allocator.alloc([]const u8, 2) catch |err| {
            log.err("failed to allocate settings argv: {}", .{err});
            return;
        };
        defer self.allocator.free(argv);
        argv[0] = settings_path;
        argv[1] = page_arg;

        var env_map = std.process.EnvMap.init(self.allocator);
        defer env_map.deinit();

        const inherited = std.process.getEnvMap(self.allocator) catch |err| {
            log.err("failed to read env for settings app: {}", .{err});
            return;
        };
        defer {
            var copy = inherited;
            copy.deinit();
        }

        var it = inherited.iterator();
        while (it.next()) |entry| {
            env_map.put(entry.key_ptr.*, entry.value_ptr.*) catch |err| {
                log.err("failed to copy env for settings app: {}", .{err});
                return;
            };
        }

        env_map.put("WAYLAND_DISPLAY", std.mem.span(self.socket_name)) catch |err| {
            log.err("failed to set WAYLAND_DISPLAY for settings app: {}", .{err});
            return;
        };
        env_map.put("AXIA_BIN_DIR", exe_dir) catch |err| {
            log.err("failed to set AXIA_BIN_DIR for settings app: {}", .{err});
            return;
        };
        env_map.put("AXIA_IPC_SOCKET", self.ipc.path()) catch |err| {
            log.err("failed to set AXIA_IPC_SOCKET for settings app: {}", .{err});
            return;
        };

        var child = std.process.Child.init(argv, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Inherit;
        child.env_map = &env_map;
        child.spawn() catch |err| {
            log.err("failed to spawn settings app: {}", .{err});
        };
    }

    fn settingsPageArg(page: SettingsPage) []const u8 {
        return switch (page) {
            .wallpapers => "wallpapers",
            .appearance => "appearance",
            .panel => "panel",
            .dock => "dock",
            .displays => "displays",
            .workspaces => "workspaces",
            .network => "network",
            .bluetooth => "bluetooth",
            .printers => "printers",
            .about => "about",
        };
    }

    fn copyText(dest: []u8, src: []const u8) usize {
        const len = @min(dest.len, src.len);
        @memcpy(dest[0..len], src[0..len]);
        return len;
    }
};
