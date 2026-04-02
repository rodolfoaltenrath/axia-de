const std = @import("std");
const c = @import("../wl.zig").c;
const ProtocolGlobals = @import("protocols.zig").ProtocolGlobals;
const Output = @import("output.zig").Output;
const SceneManager = @import("../render/scene.zig").SceneManager;
const InputManager = @import("../input/manager.zig").InputManager;
const LayerManager = @import("../layers/manager.zig").LayerManager;
const PanelProcess = @import("../panel/process.zig").PanelProcess;
const XdgManager = @import("../shell/xdg.zig").XdgManager;
const DecorationManager = @import("../shell/decoration.zig").DecorationManager;
const IpcServer = @import("../ipc/server.zig").IpcServer;
const IpcWorkspaceSnapshot = @import("../ipc/server.zig").WorkspaceSnapshot;
const WallpaperAsset = @import("../render/wallpaper.zig").WallpaperAsset;
const DesktopMenu = @import("../desktop/menu.zig").DesktopMenu;
const DesktopAction = @import("../desktop/actions.zig").Action;
const SettingsManager = @import("../settings/manager.zig").SettingsManager;
const SettingsPage = @import("../settings/model.zig").Page;

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
    socket_name: [*c]const u8,
    outputs: std.ArrayListUnmanaged(*Output) = .empty,
    new_output: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    listeners_ready: bool = false,
    input: InputManager,
    layers: LayerManager,
    panel: PanelProcess,
    xdg: XdgManager,
    decorations: DecorationManager,
    ipc: IpcServer,
    wallpaper: ?*WallpaperAsset,
    desktop_menu: DesktopMenu,
    settings: SettingsManager,

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

        var xdg = try XdgManager.init(
            allocator,
            input.seat,
            output_layout,
            scene.windowRoot(),
            display,
        );
        errdefer xdg.deinit();

        var decorations = try DecorationManager.init(allocator, display);
        errdefer decorations.deinit();

        var ipc = IpcServer.init(allocator);
        errdefer ipc.deinit();

        const wallpaper = try WallpaperAsset.loadDefault(allocator);
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
            .socket_name = socket_name,
            .input = input,
            .layers = layers,
            .panel = panel,
            .xdg = xdg,
            .decorations = decorations,
            .ipc = ipc,
            .wallpaper = wallpaper,
            .desktop_menu = desktop_menu,
            .settings = settings,
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
        self.ipc.setWorkspaceCallbacks(self, ipcGetWorkspaceState, ipcActivateWorkspace, ipcMoveFocusedWorkspace);
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
        self.input.deinit();
        if (self.wallpaper) |wallpaper| wallpaper.deinit();
        self.desktop_menu.deinit();
        self.settings.deinit();

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
    }

    fn handleShortcut(ctx: ?*anyopaque, modifiers: u32, sym: c.xkb_keysym_t) bool {
        const raw_server = ctx orelse return false;
        const server: *Server = @ptrCast(@alignCast(raw_server));

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
        server.settings.open(page) catch |err| {
            log.err("failed to open settings page: {}", .{err});
        };
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
        }

        const old_wallpaper = self.wallpaper;
        self.wallpaper = new_wallpaper;
        try self.settings.setCurrentWallpaperPath(new_wallpaper.source_path);
        if (old_wallpaper) |wallpaper| wallpaper.deinit();
        log.info("wallpaper applied: {s}", .{path});
    }
};
