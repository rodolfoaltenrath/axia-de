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
const AppGridProcess = @import("../apps/app_grid/process.zig").AppGridProcess;
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
const toast_model = @import("../toast/model.zig");

const log = std.log.scoped(.axia);
const shell_supervisor_interval_ms = 1000;

const ScreenshotAreaTask = struct {
    active_flag: *std.atomic.Value(bool),
    socket_name: []u8,
    socket_path: []u8,
};

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
    shell_supervisor_timer: ?*c.struct_wl_event_source = null,
    input: InputManager,
    layers: LayerManager,
    panel: PanelProcess,
    dock: DockProcess,
    launcher: LauncherProcess,
    app_grid: AppGridProcess,
    launcher_requested: bool = false,
    app_grid_requested: bool = false,
    xdg: XdgManager,
    decorations: DecorationManager,
    ipc: IpcServer,
    wallpaper: ?*WallpaperAsset,
    desktop_menu: DesktopMenu,
    settings: SettingsManager,
    settings_prefs: SettingsPreferencesState,
    screenshot_area_active: *std.atomic.Value(bool),
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
        const app_grid = AppGridProcess.init(allocator);

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

        const screenshot_area_active = try std.heap.page_allocator.create(std.atomic.Value(bool));
        screenshot_area_active.* = std.atomic.Value(bool).init(false);

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
            .app_grid = app_grid,
            .xdg = xdg,
            .decorations = decorations,
            .ipc = ipc,
            .wallpaper = wallpaper,
            .desktop_menu = desktop_menu,
            .settings = settings,
            .settings_prefs = settings_prefs,
            .screenshot_area_active = screenshot_area_active,
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
            ipcToggleAppGrid,
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
        if (self.shell_supervisor_timer) |timer| {
            _ = c.wl_event_source_remove(timer);
            self.shell_supervisor_timer = null;
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
        self.app_grid.deinit();
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
        try self.startShellSupervisor();
        log.info("Axia-DE core is running on WAYLAND_DISPLAY={s}", .{std.mem.span(self.socket_name)});
        c.wl_display_run(self.display);
    }

    fn startShellSupervisor(self: *Server) !void {
        if (self.shell_supervisor_timer != null) return;

        const timer = c.wl_event_loop_add_timer(self.event_loop, handleShellSupervisorTimer, self) orelse {
            return error.ShellSupervisorTimerCreateFailed;
        };
        self.shell_supervisor_timer = timer;

        if (c.wl_event_source_timer_update(timer, shell_supervisor_interval_ms) != 0) {
            _ = c.wl_event_source_remove(timer);
            self.shell_supervisor_timer = null;
            return error.ShellSupervisorTimerStartFailed;
        }
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

    fn handleShellSupervisorTimer(data: ?*anyopaque) callconv(.c) c_int {
        const raw_server = data orelse return 0;
        const server: *Server = @ptrCast(@alignCast(raw_server));
        server.superviseShellProcesses();

        if (server.shell_supervisor_timer) |timer| {
            _ = c.wl_event_source_timer_update(timer, shell_supervisor_interval_ms);
        }
        return 0;
    }

    fn superviseShellProcesses(self: *Server) void {
        if (self.panel.reapIfExited()) |term| {
            log.warn("panel exited unexpectedly ({s}), restarting", .{formatChildTerm(term)});
        }
        if (self.dock.reapIfExited()) |term| {
            log.warn("dock exited unexpectedly ({s}), restarting", .{formatChildTerm(term)});
        }
        self.handleSpecialProcessExit(
            &self.launcher,
            &self.launcher_requested,
            "launcher",
        );
        self.handleSpecialProcessExit(
            &self.app_grid,
            &self.app_grid_requested,
            "app grid",
        );

        self.panel.spawn(self.socket_name, self.ipc.path());
        self.dock.spawn(self.socket_name, self.ipc.path());
        if (self.launcher_requested and self.launcher.child == null) {
            self.launcher.spawn(self.socket_name, self.ipc.path());
        }
        if (self.app_grid_requested and self.app_grid.child == null) {
            self.app_grid.spawn(self.socket_name, self.ipc.path());
        }
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

        if (sym == c.XKB_KEY_Print and (modifiers & c.WLR_MODIFIER_LOGO) != 0) {
            server.captureAreaScreenshot();
            return true;
        }

        if (sym == c.XKB_KEY_Print and (modifiers & c.WLR_MODIFIER_SHIFT) != 0) {
            server.captureFocusedWindowScreenshot() catch |err| {
                log.err("failed to capture focused window screenshot: {}", .{err});
                server.showToast(.failure, "Falha ao capturar a janela.");
            };
            return true;
        }

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
            c.XKB_KEY_Print => blk: {
                server.captureScreenshot() catch |err| {
                    log.err("failed to capture screenshot: {}", .{err});
                    server.showToast(.failure, "Falha ao capturar a tela.");
                };
                break :blk true;
            },
            c.XKB_KEY_a, c.XKB_KEY_A => blk: {
                server.toggleAppGrid();
                break :blk true;
            },
            c.XKB_KEY_l, c.XKB_KEY_L => blk: {
                server.runSessionCommand("loginctl lock-session \"$XDG_SESSION_ID\"") catch |err| {
                    log.err("failed to lock session via shortcut: {}", .{err});
                };
                break :blk true;
            },
            c.XKB_KEY_comma, c.XKB_KEY_less => blk: {
                server.spawnSettingsApp(.wallpapers);
                break :blk true;
            },
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

    fn ipcToggleAppGrid(ctx: ?*anyopaque) void {
        const raw_server = ctx orelse return;
        const server: *Server = @ptrCast(@alignCast(raw_server));
        server.toggleAppGrid();
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
        if (self.xdg.dismissLauncher()) {
            self.launcher_requested = false;
            return;
        }
        self.launcher_requested = true;
        self.launcher.spawn(self.socket_name, self.ipc.path());
    }

    fn toggleAppGrid(self: *Server) void {
        const app_id = "axia-app-grid";
        if (self.xdg.isAppFocusedById(app_id)) {
            self.app_grid_requested = false;
            _ = self.xdg.closeAppById(app_id);
            return;
        }
        if (self.xdg.focusAppById(app_id)) {
            self.app_grid_requested = true;
            return;
        }
        self.app_grid_requested = true;
        self.app_grid.spawn(self.socket_name, self.ipc.path());
    }

    fn handleSpecialProcessExit(
        self: *Server,
        process: anytype,
        requested_flag: *bool,
        label: []const u8,
    ) void {
        const term = process.reapIfExited() orelse return;
        if (!requested_flag.*) return;

        switch (term) {
            .Exited => |code| {
                if (code == 0) {
                    requested_flag.* = false;
                    return;
                }
                log.warn("{s} exited with code {d}, restarting", .{ label, code });
            },
            .Signal => |signal| {
                log.warn("{s} exited via signal {d}, restarting", .{ label, signal });
            },
            .Stopped => |signal| {
                log.warn("{s} stopped via signal {d}, restarting", .{ label, signal });
            },
            .Unknown => |status| {
                log.warn("{s} exited with unknown status {d}, restarting", .{ label, status });
            },
        }

        if (std.mem.eql(u8, label, "launcher")) {
            self.launcher.spawn(self.socket_name, self.ipc.path());
        } else if (std.mem.eql(u8, label, "app grid")) {
            self.app_grid.spawn(self.socket_name, self.ipc.path());
        }
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

    fn captureScreenshot(self: *Server) !void {
        try self.captureScreenshotWithMode(.fullscreen);
    }

    fn captureFocusedWindowScreenshot(self: *Server) !void {
        const box = self.xdg.focusedViewOuterBox() orelse {
            self.showToast(.warning, "Nenhuma janela focada para capturar.");
            return;
        };
        if (box.width <= 0 or box.height <= 0) {
            self.showToast(.warning, "A janela focada nao pode ser capturada.");
            return;
        }

        try self.captureScreenshotWithMode(.{ .focused = box });
    }

    fn captureAreaScreenshot(self: *Server) void {
        if (self.screenshot_area_active.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
            self.showToast(.warning, "Ja existe uma selecao de screenshot em andamento.");
            return;
        }

        const task = std.heap.page_allocator.create(ScreenshotAreaTask) catch {
            self.screenshot_area_active.store(false, .release);
            self.showToast(.failure, "Falha ao iniciar a captura por area.");
            return;
        };
        errdefer std.heap.page_allocator.destroy(task);

        task.socket_name = std.heap.page_allocator.dupe(u8, std.mem.span(self.socket_name)) catch {
            self.screenshot_area_active.store(false, .release);
            self.showToast(.failure, "Falha ao preparar a captura por area.");
            return;
        };
        errdefer std.heap.page_allocator.free(task.socket_name);

        task.socket_path = std.heap.page_allocator.dupe(u8, self.ipc.path()) catch {
            self.screenshot_area_active.store(false, .release);
            self.showToast(.failure, "Falha ao preparar a captura por area.");
            return;
        };
        errdefer std.heap.page_allocator.free(task.socket_path);

        task.active_flag = self.screenshot_area_active;

        const thread = std.Thread.spawn(.{}, runAreaScreenshotTask, .{task}) catch |err| {
            std.heap.page_allocator.free(task.socket_path);
            std.heap.page_allocator.free(task.socket_name);
            std.heap.page_allocator.destroy(task);
            self.screenshot_area_active.store(false, .release);
            log.err("failed to spawn area screenshot thread: {}", .{err});
            self.showToast(.failure, "Falha ao iniciar a captura por area.");
            return;
        };
        thread.detach();
        self.showToast(.info, "Selecione uma area para screenshot.");
    }

    const ScreenshotMode = union(enum) {
        fullscreen,
        focused: c.struct_wlr_box,
    };

    fn captureScreenshotWithMode(self: *Server, mode: ScreenshotMode) !void {
        const screenshot_dir = try ensureScreenshotDirectoryAlloc(self.allocator);
        defer self.allocator.free(screenshot_dir);

        const timestamp_ms = std.time.milliTimestamp();
        const file_name = switch (mode) {
            .fullscreen => try std.fmt.allocPrint(self.allocator, "axia-screenshot-{d}.png", .{timestamp_ms}),
            .focused => try std.fmt.allocPrint(self.allocator, "axia-window-screenshot-{d}.png", .{timestamp_ms}),
        };
        defer self.allocator.free(file_name);

        const screenshot_path = try std.fs.path.join(self.allocator, &.{ screenshot_dir, file_name });
        defer self.allocator.free(screenshot_path);

        var env_map = std.process.EnvMap.init(self.allocator);
        defer env_map.deinit();
        try copyInheritedEnvAlloc(self.allocator, &env_map);
        try env_map.put("WAYLAND_DISPLAY", std.mem.span(self.socket_name));

        const geometry = switch (mode) {
            .fullscreen => null,
            .focused => |box| try std.fmt.allocPrint(self.allocator, "{d},{d} {d}x{d}", .{ box.x, box.y, box.width, box.height }),
        };
        defer if (geometry) |value| self.allocator.free(value);

        const result = switch (mode) {
            .fullscreen => std.process.Child.run(.{
                .allocator = self.allocator,
                .argv = &.{ "grim", screenshot_path },
                .env_map = &env_map,
                .max_output_bytes = 8 * 1024,
            }),
            .focused => std.process.Child.run(.{
                .allocator = self.allocator,
                .argv = &.{ "grim", "-g", geometry.?, screenshot_path },
                .env_map = &env_map,
                .max_output_bytes = 8 * 1024,
            }),
        } catch |err| {
            switch (err) {
                error.FileNotFound => {
                    self.showToast(.failure, "Instale o grim para usar screenshots.");
                    return;
                },
                else => return err,
            }
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| {
                if (code == 0) {
                    const message = switch (mode) {
                        .fullscreen => try std.fmt.allocPrint(self.allocator, "Screenshot salva em {s}", .{file_name}),
                        .focused => try std.fmt.allocPrint(self.allocator, "Screenshot da janela salva em {s}", .{file_name}),
                    };
                    defer self.allocator.free(message);
                    self.showToast(.success, message);
                    return;
                }

                log.err("grim exited with code {d}: {s}", .{ code, result.stderr });
                self.showToast(.failure, "Falha ao salvar screenshot.");
            },
            else => {
                log.err("grim exited unexpectedly: {any}", .{result.term});
                self.showToast(.failure, "Falha ao capturar screenshot.");
            },
        }
    }

    fn runAreaScreenshotTask(task: *ScreenshotAreaTask) void {
        defer task.active_flag.store(false, .release);
        defer std.heap.page_allocator.free(task.socket_path);
        defer std.heap.page_allocator.free(task.socket_name);
        defer std.heap.page_allocator.destroy(task);

        const allocator = std.heap.page_allocator;

        var env_map = std.process.EnvMap.init(allocator);
        defer env_map.deinit();
        copyInheritedEnvAlloc(allocator, &env_map) catch {
            sendToastMessage(allocator, task.socket_path, .failure, "Falha ao preparar screenshot por area.");
            return;
        };
        env_map.put("WAYLAND_DISPLAY", task.socket_name) catch {
            sendToastMessage(allocator, task.socket_path, .failure, "Falha ao preparar screenshot por area.");
            return;
        };

        const selection_result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "slurp" },
            .env_map = &env_map,
            .max_output_bytes = 4 * 1024,
        }) catch |err| {
            switch (err) {
                error.FileNotFound => sendToastMessage(allocator, task.socket_path, .failure, "Instale o slurp para selecionar a area."),
                else => sendToastMessage(allocator, task.socket_path, .failure, "Falha ao abrir o seletor de area."),
            }
            return;
        };
        defer allocator.free(selection_result.stdout);
        defer allocator.free(selection_result.stderr);

        const selection = switch (selection_result.term) {
            .Exited => |code| blk: {
                if (code != 0) {
                    if (code == 1) {
                        sendToastMessage(allocator, task.socket_path, .info, "Screenshot por area cancelada.");
                    } else {
                        sendToastMessage(allocator, task.socket_path, .failure, "Falha ao selecionar a area.");
                    }
                    return;
                }
                break :blk std.mem.trim(u8, selection_result.stdout, " \r\n\t");
            },
            else => {
                sendToastMessage(allocator, task.socket_path, .failure, "Falha ao selecionar a area.");
                return;
            },
        };

        if (selection.len == 0) {
            sendToastMessage(allocator, task.socket_path, .info, "Screenshot por area cancelada.");
            return;
        }

        const screenshot_dir = ensureScreenshotDirectoryAlloc(allocator) catch {
            sendToastMessage(allocator, task.socket_path, .failure, "Falha ao criar pasta de screenshots.");
            return;
        };
        defer allocator.free(screenshot_dir);

        const timestamp_ms = std.time.milliTimestamp();
        const file_name = std.fmt.allocPrint(allocator, "axia-area-screenshot-{d}.png", .{timestamp_ms}) catch {
            sendToastMessage(allocator, task.socket_path, .failure, "Falha ao preparar screenshot por area.");
            return;
        };
        defer allocator.free(file_name);

        const screenshot_path = std.fs.path.join(allocator, &.{ screenshot_dir, file_name }) catch {
            sendToastMessage(allocator, task.socket_path, .failure, "Falha ao preparar screenshot por area.");
            return;
        };
        defer allocator.free(screenshot_path);

        const grim_result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "grim", "-g", selection, screenshot_path },
            .env_map = &env_map,
            .max_output_bytes = 8 * 1024,
        }) catch |err| {
            switch (err) {
                error.FileNotFound => sendToastMessage(allocator, task.socket_path, .failure, "Instale o grim para usar screenshots."),
                else => sendToastMessage(allocator, task.socket_path, .failure, "Falha ao capturar a area."),
            }
            return;
        };
        defer allocator.free(grim_result.stdout);
        defer allocator.free(grim_result.stderr);

        switch (grim_result.term) {
            .Exited => |code| {
                if (code == 0) {
                    const message = std.fmt.allocPrint(allocator, "Screenshot da area salva em {s}", .{file_name}) catch {
                        sendToastMessage(allocator, task.socket_path, .success, "Screenshot da area salva.");
                        return;
                    };
                    defer allocator.free(message);
                    sendToastMessage(allocator, task.socket_path, .success, message);
                } else {
                    sendToastMessage(allocator, task.socket_path, .failure, "Falha ao capturar a area.");
                }
            },
            else => sendToastMessage(allocator, task.socket_path, .failure, "Falha ao capturar a area."),
        }
    }

    fn ensureScreenshotDirectoryAlloc(allocator: std.mem.Allocator) ![]u8 {
        const home = try std.process.getEnvVarOwned(allocator, "HOME");
        defer allocator.free(home);

        const pictures = try std.fs.path.join(allocator, &.{ home, "Pictures" });
        defer allocator.free(pictures);
        const imagens = try std.fs.path.join(allocator, &.{ home, "Imagens" });
        defer allocator.free(imagens);

        const base_dir = if (directoryExistsAbsolute(pictures))
            try allocator.dupe(u8, pictures)
        else if (directoryExistsAbsolute(imagens))
            try allocator.dupe(u8, imagens)
        else
            try allocator.dupe(u8, home);

        errdefer allocator.free(base_dir);

        const screenshot_dir = try std.fs.path.join(allocator, &.{ base_dir, "Screenshots" });
        allocator.free(base_dir);
        errdefer allocator.free(screenshot_dir);

        std.fs.makeDirAbsolute(screenshot_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        return screenshot_dir;
    }

    fn copyInheritedEnvAlloc(allocator: std.mem.Allocator, env_map: *std.process.EnvMap) !void {
        const inherited = try std.process.getEnvMap(allocator);
        defer {
            var copy = inherited;
            copy.deinit();
        }

        var it = inherited.iterator();
        while (it.next()) |entry| {
            try env_map.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    fn runSessionCommand(self: *Server, command: []const u8) !void {
        const argv: []const []const u8 = &.{ "sh", "-lc", command };
        var child = std.process.Child.init(argv, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        try child.spawn();
    }

    fn showToast(self: *Server, level: toast_model.Level, message: []const u8) void {
        self.ipc.showToast(level, message);
    }

    fn directoryExistsAbsolute(path: []const u8) bool {
        const dir = std.fs.openDirAbsolute(path, .{}) catch return false;
        var opened = dir;
        opened.close();
        return true;
    }

    fn sendToastMessage(allocator: std.mem.Allocator, socket_path: []const u8, level: toast_model.Level, message: []const u8) void {
        const payload = std.fmt.allocPrint(allocator, "toast show {s} {s}\n", .{ toast_model.levelName(level), message }) catch return;
        defer allocator.free(payload);

        const address = std.net.Address.initUnix(socket_path) catch return;
        const fd = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0) catch return;
        defer std.posix.close(fd);

        std.posix.connect(fd, &address.any, address.getOsSockLen()) catch return;
        _ = std.posix.write(fd, payload) catch return;
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

    fn formatChildTerm(term: std.process.Child.Term) []const u8 {
        return switch (term) {
            .Exited => "exit",
            .Signal => "signal",
            .Stopped => "stopped",
            .Unknown => "unknown",
        };
    }

    fn copyText(dest: []u8, src: []const u8) usize {
        const len = @min(dest.len, src.len);
        @memcpy(dest[0..len], src[0..len]);
        return len;
    }
};
