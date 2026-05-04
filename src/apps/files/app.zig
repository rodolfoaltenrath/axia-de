const std = @import("std");
const c = @import("client_wl").c;
const buffer_mod = @import("client_buffer");
const browser = @import("browser.zig");
const icons = @import("icons.zig");
const render = @import("render.zig");
const toast_client = @import("toast_client");
const toast_model = @import("toast_model");

const log = std.log.scoped(.axia_files);

const width: u32 = 920;
const height: u32 = 580;
const double_click_threshold_ms: i64 = 380;

const DialogKind = enum {
    none,
    new_folder,
    new_file,
    rename,
    delete_confirm,
    delete_permanent_confirm,
};

const DialogState = struct {
    kind: DialogKind = .none,
    input: [160]u8 = [_]u8{0} ** 160,
    input_len: usize = 0,
    subject: [160]u8 = [_]u8{0} ** 160,
    subject_len: usize = 0,

    fn clear(self: *DialogState) void {
        self.* = .{};
    }

    fn inputText(self: *const DialogState) []const u8 {
        return self.input[0..self.input_len];
    }

    fn subjectText(self: *const DialogState) []const u8 {
        return self.subject[0..self.subject_len];
    }
};

pub const Mode = enum {
    browser,
    wallpaper_picker,
};

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
    buffers: [3]?buffer_mod.ShmBuffer = .{ null, null, null },
    ipc_socket_path: ?[]u8 = null,
    running: bool = true,
    configured: bool = false,
    dirty: bool = false,
    current_width: u32 = width,
    current_height: u32 = height,
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    hovered: render.Hit = .none,
    dialog: DialogState = .{},
    last_button_serial: u32 = 0,
    last_clicked_path: ?[]u8 = null,
    last_click_ms: i64 = 0,
    maximized: bool = false,
    sidebar_collapsed: bool = false,
    zoom_level: u8 = 1,
    show_details: bool = false,
    context_menu: ?render.ContextMenu = null,
    context_targets_selection: bool = false,
    mode: Mode = .browser,
    browser: browser.Browser,
    icons: icons.SidebarIcons,
    xkb_context: ?*c.struct_xkb_context = null,
    xkb_keymap: ?*c.struct_xkb_keymap = null,
    xkb_state: ?*c.struct_xkb_state = null,
    registry_listener: c.struct_wl_registry_listener = undefined,
    wm_base_listener: c.struct_xdg_wm_base_listener = undefined,
    xdg_surface_listener: c.struct_xdg_surface_listener = undefined,
    toplevel_listener: c.struct_xdg_toplevel_listener = undefined,
    seat_listener: c.struct_wl_seat_listener = undefined,
    pointer_listener: c.struct_wl_pointer_listener = undefined,
    keyboard_listener: c.struct_wl_keyboard_listener = undefined,

    pub fn create(allocator: std.mem.Allocator, mode: Mode) !*App {
        const app = try allocator.create(App);
        errdefer allocator.destroy(app);

        const display = c.wl_display_connect(null) orelse return error.WaylandConnectFailed;
        errdefer c.wl_display_disconnect(display);
        const registry = c.wl_display_get_registry(display) orelse return error.RegistryGetFailed;

        app.* = .{
            .allocator = allocator,
            .display = display,
            .registry = registry,
            .mode = mode,
            .browser = browser.Browser.init(allocator, switch (mode) {
                .browser => .browser,
                .wallpaper_picker => .wallpaper_picker,
            }),
            .icons = try icons.SidebarIcons.init(allocator),
        };
        app.ipc_socket_path = std.process.getEnvVarOwned(allocator, "AXIA_IPC_SOCKET") catch null;

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
        for (&self.buffers) |*slot| {
            if (slot.*) |*buffer| buffer.deinit();
            slot.* = null;
        }
        self.clearXkb();
        if (self.keyboard) |keyboard| c.wl_keyboard_destroy(keyboard);
        if (self.pointer) |pointer| c.wl_pointer_destroy(pointer);
        if (self.seat) |seat| c.wl_seat_destroy(seat);
        if (self.toplevel) |toplevel| c.xdg_toplevel_destroy(toplevel);
        if (self.xdg_surface) |xdg_surface| c.xdg_surface_destroy(xdg_surface);
        if (self.wl_surface) |wl_surface| c.wl_surface_destroy(wl_surface);
        if (self.wm_base) |wm_base| c.xdg_wm_base_destroy(wm_base);
        if (self.shm) |shm| c.wl_shm_destroy(shm);
        if (self.compositor) |compositor| c.wl_compositor_destroy(compositor);
        if (self.last_clicked_path) |path| self.allocator.free(path);
        if (self.ipc_socket_path) |socket| self.allocator.free(socket);
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

        c.xdg_toplevel_set_title(toplevel, if (self.mode == .wallpaper_picker) "Selecionar Wallpaper" else "Arquivos");
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

        const buffer = try self.acquireBuffer(shm) orelse {
            self.dirty = true;
            return;
        };
        const view = self.viewOptions();
        const snapshot = self.browser.snapshot(render.visibleEntryCapacity(self.current_width, self.current_height, self.sidebar_collapsed, self.maximized, view));
        self.icons.ensureVisibleThumbnails(snapshot);
        render.draw(
            buffer.cr,
            self.current_width,
            self.current_height,
            snapshot,
            self.hovered,
            self.sidebar_collapsed,
            &self.icons,
            self.mode == .wallpaper_picker,
            dialogKindForRender(self.dialog.kind),
            self.dialog.inputText(),
            self.dialog.subjectText(),
            self.maximized,
            view,
        );
        c.cairo_surface_flush(buffer.surface);
        c.wl_surface_attach(self.wl_surface.?, buffer.buffer, 0, 0);
        c.wl_surface_damage_buffer(self.wl_surface.?, 0, 0, @intCast(self.current_width), @intCast(self.current_height));
        c.wl_surface_commit(self.wl_surface.?);
        buffer.markBusy();
        self.dirty = false;
    }

    fn acquireBuffer(self: *App, shm: *c.struct_wl_shm) !?*buffer_mod.ShmBuffer {
        for (&self.buffers) |*slot| {
            if (slot.*) |*buffer| {
                if (buffer.width != self.current_width or buffer.height != self.current_height) {
                    if (buffer.busy) continue;
                    buffer.deinit();
                    slot.* = null;
                }
            }
        }

        for (&self.buffers) |*slot| {
            if (slot.*) |*buffer| {
                if (!buffer.busy) return buffer;
                continue;
            }

            slot.* = try buffer_mod.ShmBuffer.init(shm, self.current_width, self.current_height, "axia-files");
            slot.*.?.installListener();
            return &slot.*.?;
        }

        return null;
    }

    fn updateHover(self: *App) void {
        const view = self.viewOptions();
        const new_hovered = render.hitTest(
            self.current_width,
            self.current_height,
            self.pointer_x,
            self.pointer_y,
            self.browser.snapshot(render.visibleEntryCapacity(self.current_width, self.current_height, self.sidebar_collapsed, self.maximized, view)),
            self.sidebar_collapsed,
            self.mode == .wallpaper_picker,
            dialogKindForRender(self.dialog.kind),
            self.maximized,
            view,
        );
        if (!hitEquals(new_hovered, self.hovered)) {
            self.hovered = new_hovered;
            self.dirty = true;
        }
    }

    fn scrollAtPointer(self: *App, direction: isize) void {
        if (!render.scrollRegionRect(self.current_width, self.current_height, self.sidebar_collapsed, self.maximized).contains(self.pointer_x, self.pointer_y)) {
            return;
        }
        if (isCtrlPressed(self)) {
            self.zoomBy(direction);
            return;
        }
        const view = self.viewOptionsWithoutContext();
        const columns = render.visibleColumns(self.current_width, self.current_height, self.sidebar_collapsed, self.maximized, view);
        const visible_limit = render.visibleEntryCapacity(self.current_width, self.current_height, self.sidebar_collapsed, self.maximized, view);
        self.browser.scrollItems(direction * @as(isize, @intCast(columns)), visible_limit);
        self.updateHover();
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
                if (self.maximized) {
                    c.xdg_toplevel_unset_maximized(toplevel);
                } else {
                    c.xdg_toplevel_set_maximized(toplevel);
                }
            },
            .close => self.running = false,
            .toggle_sidebar => self.sidebar_collapsed = !self.sidebar_collapsed,
            .up => self.browser.goParent() catch {},
            .breadcrumb_up => self.browser.goParent() catch {},
            .open_selected => self.openSelectedPath(),
            .new_folder => self.beginCreateFolderDialog(),
            .rename_selected => self.beginRenameDialog(),
            .delete_selected => self.beginDeleteDialog(),
            .dialog_confirm => self.confirmDialog(),
            .dialog_cancel => self.dialog.clear(),
            .previous => self.browser.previousPage(self.visibleLimit()),
            .next => self.browser.nextPage(self.visibleLimit()),
            .sort_modified => self.browser.toggleModifiedSort(),
            .context_details => {
                self.show_details = !self.show_details;
                self.context_menu = null;
            },
            .context_pin => {
                if (self.context_targets_selection) {
                    self.browser.pinSelectedDirectory() catch {};
                } else {
                    self.browser.pinCurrentDirectory() catch {};
                }
                self.context_menu = null;
            },
            .context_unpin => {
                if (self.context_targets_selection) {
                    self.browser.unpinSelectedDirectory() catch {};
                } else {
                    self.browser.unpinCurrentDirectory() catch {};
                }
                self.context_menu = null;
            },
            .context_new_folder => {
                self.context_menu = null;
                self.beginCreateFolderDialog();
            },
            .context_new_file => {
                self.context_menu = null;
                self.beginCreateFileDialog();
            },
            .context_open_terminal => {
                self.context_menu = null;
                self.openTerminalHere();
            },
            .context_select_all => {
                self.browser.selectAll() catch {};
                self.context_menu = null;
            },
            .context_paste => {
                self.context_menu = null;
                self.pasteFromClipboard();
            },
            .context_sort_name => {
                self.browser.sortByName();
                self.context_menu = null;
            },
            .context_sort_modified => {
                self.browser.sortByModified();
                self.context_menu = null;
            },
            .context_sort_size => {
                self.browser.sortBySize();
                self.context_menu = null;
            },
            .sidebar => |target| self.browser.openSidebar(target) catch {},
            .pinned_folder => |index| self.browser.openPinnedFolder(index) catch {},
            .entry => |index| {
                if (self.mode == .wallpaper_picker) {
                    self.handleWallpaperPickerEntry(index);
                } else {
                    self.handleBrowserEntry(index);
                }
            },
        }
        self.dirty = true;
    }

    fn handleBrowserEntry(self: *App, index: usize) void {
        self.context_menu = null;
        const entry = self.browser.visibleEntry(index) orelse return;
        const clicked_twice = self.registerEntryClick(entry.path);
        if (clicked_twice) {
            switch (entry.kind) {
                .directory => self.browser.openDirectory(entry.path) catch {},
                .file => self.openPathDefault(entry.path),
            }
            return;
        }

        if (isCtrlPressed(self)) {
            self.browser.toggleVisibleSelection(index) catch {};
        } else {
            self.browser.selectVisible(index) catch {};
        }
    }

    fn handleWallpaperPickerEntry(self: *App, index: usize) void {
        self.context_menu = null;
        const entry = self.browser.visibleEntry(index) orelse return;
        switch (entry.kind) {
            .directory => self.browser.openDirectory(entry.path) catch {},
            .file => {
                std.fs.File.stdout().deprecatedWriter().print("{s}\n", .{entry.path}) catch {};
                self.running = false;
            },
        }
    }

    fn openSelectedPath(self: *App) void {
        if (self.browser.selectedCount() != 1) return;
        const path = self.browser.selectedPath() orelse return;
        if (self.browser.hasSelectedDirectory()) {
            self.browser.activateSelected() catch {};
            return;
        }
        self.openPathDefault(path);
    }

    fn registerEntryClick(self: *App, path: []const u8) bool {
        const now_ms = std.time.milliTimestamp();
        const repeated = self.last_clicked_path != null and
            std.mem.eql(u8, self.last_clicked_path.?, path) and
            now_ms - self.last_click_ms <= double_click_threshold_ms;

        if (self.last_clicked_path) |existing| self.allocator.free(existing);
        self.last_clicked_path = self.allocator.dupe(u8, path) catch null;
        self.last_click_ms = now_ms;
        return repeated;
    }

    fn openPathDefault(self: *App, path: []const u8) void {
        const fallbacks = [_][]const []const u8{
            &.{ "xdg-open", path },
            &.{ "gio", "open", path },
        };

        for (fallbacks) |argv| {
            var child = std.process.Child.init(argv, self.allocator);
            child.stdin_behavior = .Ignore;
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Ignore;
            child.spawn() catch |err| switch (err) {
                error.FileNotFound => continue,
                else => {
                    log.err("failed to open file with default app: {}", .{err});
                    return;
                },
            };
            return;
        }

        log.err("no default opener found for files app", .{});
    }

    fn openTerminalHere(self: *App) void {
        const current_dir = self.browser.currentDirectory() orelse return;
        const fallbacks = [_][]const u8{
            "x-terminal-emulator",
            "foot",
            "alacritty",
            "kitty",
            "gnome-terminal",
            "konsole",
            "xterm",
        };

        for (fallbacks) |terminal| {
            var child = std.process.Child.init(&.{terminal}, self.allocator);
            child.cwd = current_dir;
            child.stdin_behavior = .Ignore;
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Ignore;
            child.spawn() catch |err| switch (err) {
                error.FileNotFound => continue,
                else => {
                    log.err("failed to open terminal: {}", .{err});
                    self.showToast(.failure, "Nao foi possivel abrir o terminal.");
                    return;
                },
            };
            return;
        }

        self.showToast(.failure, "Nenhum terminal encontrado.");
    }

    fn pasteFromClipboard(self: *App) void {
        var paths = self.readClipboardFilePaths() catch |err| {
            log.err("failed to read clipboard file paths: {}", .{err});
            self.showToast(.failure, "Nao foi possivel ler a area de transferencia.");
            return;
        };
        defer {
            for (paths.items) |path| self.allocator.free(path);
            paths.deinit(self.allocator);
        }

        if (paths.items.len == 0) {
            self.showToast(.info, "Nenhum arquivo para colar.");
            return;
        }

        const pasted = self.browser.pastePaths(paths.items) catch |err| {
            log.err("failed to paste files: {}", .{err});
            self.showToast(.failure, "Nao foi possivel colar.");
            return;
        };
        if (pasted == 0) {
            self.showToast(.info, "Nenhum arquivo para colar.");
        } else {
            self.showToast(.success, "Item colado.");
        }
    }

    fn readClipboardFilePaths(self: *App) !std.ArrayListUnmanaged([]u8) {
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "wl-paste", "--no-newline", "--type", "text/uri-list" },
            .max_output_bytes = 1024 * 1024,
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| if (code != 0) return error.ClipboardReadFailed,
            else => return error.ClipboardReadFailed,
        }

        var paths: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (paths.items) |path| self.allocator.free(path);
            paths.deinit(self.allocator);
        }

        var lines = std.mem.tokenizeAny(u8, result.stdout, "\r\n");
        while (lines.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t");
            if (line.len == 0 or line[0] == '#') continue;
            const path = try clipboardLineToPath(self.allocator, line);
            errdefer self.allocator.free(path);
            if (!std.fs.path.isAbsolute(path)) {
                self.allocator.free(path);
                continue;
            }
            try paths.append(self.allocator, path);
        }
        return paths;
    }

    fn openContextMenu(self: *App) void {
        if (self.mode == .wallpaper_picker or self.dialog.kind != .none) return;
        const hovered = self.hovered;
        var targets_selection = false;
        var kind: render.ContextMenuKind = .empty_space;
        switch (hovered) {
            .entry => |index| {
                self.browser.selectVisible(index) catch {};
                targets_selection = true;
                kind = .selection;
            },
            .none => {
                if (!render.scrollRegionRect(self.current_width, self.current_height, self.sidebar_collapsed, self.maximized).contains(self.pointer_x, self.pointer_y)) {
                    return;
                }
            },
            else => return,
        }
        self.context_targets_selection = targets_selection;
        const menu_width: f64 = if (kind == .empty_space) 360.0 else 220.0;
        const menu_height: f64 = if (kind == .empty_space) 338.0 else 136.0;
        self.context_menu = .{
            .x = @max(6.0, @min(self.pointer_x, @as(f64, @floatFromInt(self.current_width)) - menu_width - 12.0)),
            .y = @max(6.0, @min(self.pointer_y, @as(f64, @floatFromInt(self.current_height)) - menu_height - 12.0)),
            .kind = kind,
            .details_enabled = self.show_details,
            .can_pin = if (targets_selection) self.browser.canPinSelection() else !self.browser.isCurrentDirectoryPinned(),
            .can_unpin = if (targets_selection) self.browser.canUnpinSelection() else self.browser.canUnpinCurrentDirectory(),
            .sort_field = self.browser.sort_field,
        };
        self.updateHover();
        self.dirty = true;
    }

    fn zoomBy(self: *App, direction: isize) void {
        const previous = self.zoom_level;
        if (direction < 0 and self.zoom_level < 3) {
            self.zoom_level += 1;
        } else if (direction > 0 and self.zoom_level > 0) {
            self.zoom_level -= 1;
        }
        if (self.zoom_level == previous) return;
        self.context_menu = null;
        self.browser.scrollItems(0, self.visibleLimit());
        self.updateHover();
        self.dirty = true;
    }

    fn visibleLimit(self: *App) usize {
        return render.visibleEntryCapacity(self.current_width, self.current_height, self.sidebar_collapsed, self.maximized, self.viewOptionsWithoutContext());
    }

    fn viewOptions(self: *const App) render.ViewOptions {
        return .{
            .zoom_level = self.zoom_level,
            .show_details = self.show_details,
            .context_menu = self.context_menu,
        };
    }

    fn viewOptionsWithoutContext(self: *const App) render.ViewOptions {
        return .{
            .zoom_level = self.zoom_level,
            .show_details = self.show_details,
            .context_menu = null,
        };
    }

    fn setSeat(self: *App, seat: *c.struct_wl_seat) void {
        self.seat = seat;
        self.seat_listener = .{ .capabilities = handleSeatCapabilities, .name = handleSeatName };
        _ = c.wl_seat_add_listener(seat, &self.seat_listener, self);
    }

    fn beginCreateFolderDialog(self: *App) void {
        if (self.mode == .wallpaper_picker) return;
        self.dialog.clear();
        self.dialog.kind = .new_folder;
        self.setDialogInput("Nova pasta");
        self.dirty = true;
    }

    fn beginCreateFileDialog(self: *App) void {
        if (self.mode == .wallpaper_picker) return;
        self.dialog.clear();
        self.dialog.kind = .new_file;
        self.setDialogInput("Novo arquivo");
        self.dirty = true;
    }

    fn beginRenameDialog(self: *App) void {
        if (self.mode == .wallpaper_picker) return;
        if (self.browser.selectedCount() != 1) return;
        const name = self.browser.selectedName() orelse return;
        self.dialog.clear();
        self.dialog.kind = .rename;
        self.setDialogInput(name);
        self.setDialogSubject(name);
        self.dirty = true;
    }

    fn beginDeleteDialog(self: *App) void {
        if (self.mode == .wallpaper_picker) return;
        if (self.browser.selectedCount() == 0) return;
        self.dialog.clear();
        self.dialog.kind = if (self.browser.isViewingTrash()) .delete_permanent_confirm else .delete_confirm;
        if (self.browser.selectedCount() == 1) {
            const name = self.browser.selectedName() orelse return;
            self.setDialogSubject(name);
        } else {
            var buffer: [64]u8 = undefined;
            const subject = std.fmt.bufPrint(&buffer, "{d} itens selecionados", .{self.browser.selectedCount()}) catch "Itens selecionados";
            self.setDialogSubject(subject);
        }
        self.dirty = true;
    }

    fn beginPermanentDeleteDialog(self: *App) void {
        if (self.mode == .wallpaper_picker) return;
        if (self.browser.selectedCount() == 0) return;
        self.dialog.clear();
        self.dialog.kind = .delete_permanent_confirm;
        if (self.browser.selectedCount() == 1) {
            const name = self.browser.selectedName() orelse return;
            self.setDialogSubject(name);
        } else {
            var buffer: [64]u8 = undefined;
            const subject = std.fmt.bufPrint(&buffer, "{d} itens selecionados", .{self.browser.selectedCount()}) catch "Itens selecionados";
            self.setDialogSubject(subject);
        }
        self.dirty = true;
    }

    fn confirmDialog(self: *App) void {
        switch (self.dialog.kind) {
            .none => return,
            .new_folder => {
                self.browser.createDirectoryNamed(self.dialog.inputText()) catch |err| {
                    log.err("failed to create directory: {}", .{err});
                    self.showToast(.failure, "Nao foi possivel criar a pasta.");
                    return;
                };
                self.showToast(.success, "Pasta criada.");
            },
            .new_file => {
                self.browser.createFileNamed(self.dialog.inputText()) catch |err| {
                    log.err("failed to create file: {}", .{err});
                    self.showToast(.failure, "Nao foi possivel criar o arquivo.");
                    return;
                };
                self.showToast(.success, "Arquivo criado.");
            },
            .rename => {
                self.browser.renameSelectedTo(self.dialog.inputText()) catch |err| {
                    log.err("failed to rename entry: {}", .{err});
                    self.showToast(.failure, "Nao foi possivel renomear o item.");
                    return;
                };
                self.showToast(.success, "Item renomeado.");
            },
            .delete_confirm => {
                self.browser.deleteSelected() catch |err| {
                    log.err("failed to delete entry: {}", .{err});
                    self.showToast(.failure, "Nao foi possivel mover para a lixeira.");
                    return;
                };
                self.showToast(.info, "Item movido para a lixeira.");
            },
            .delete_permanent_confirm => {
                self.browser.deleteSelectedPermanently() catch |err| {
                    log.err("failed to delete entry permanently: {}", .{err});
                    self.showToast(.failure, "Nao foi possivel excluir permanentemente.");
                    return;
                };
                self.showToast(.warning, "Item excluido permanentemente.");
            },
        }
        self.dialog.clear();
        self.hovered = .none;
        self.dirty = true;
    }

    fn setDialogInput(self: *App, text: []const u8) void {
        const len = @min(self.dialog.input.len, text.len);
        @memcpy(self.dialog.input[0..len], text[0..len]);
        self.dialog.input_len = len;
    }

    fn setDialogSubject(self: *App, text: []const u8) void {
        const len = @min(self.dialog.subject.len, text.len);
        @memcpy(self.dialog.subject[0..len], text[0..len]);
        self.dialog.subject_len = len;
    }

    fn appendDialogText(self: *App, text: []const u8) void {
        if (self.dialog.kind == .none or self.dialog.kind == .delete_confirm or self.dialog.kind == .delete_permanent_confirm) return;
        const available = self.dialog.input.len - self.dialog.input_len;
        const len = @min(available, text.len);
        if (len == 0) return;
        @memcpy(self.dialog.input[self.dialog.input_len .. self.dialog.input_len + len], text[0..len]);
        self.dialog.input_len += len;
        self.dirty = true;
    }

    fn backspaceDialogText(self: *App) void {
        if (self.dialog.kind == .none or self.dialog.kind == .delete_confirm or self.dialog.kind == .delete_permanent_confirm or self.dialog.input_len == 0) return;
        var index = self.dialog.input_len - 1;
        while (index > 0 and (self.dialog.input[index] & 0b1100_0000) == 0b1000_0000) : (index -= 1) {}
        self.dialog.input_len = index;
        self.dirty = true;
    }

    fn clearXkb(self: *App) void {
        if (self.xkb_state) |state| c.xkb_state_unref(state);
        if (self.xkb_keymap) |keymap| c.xkb_keymap_unref(keymap);
        if (self.xkb_context) |context| c.xkb_context_unref(context);
        self.xkb_state = null;
        self.xkb_keymap = null;
        self.xkb_context = null;
    }

    fn showToast(self: *App, level: toast_model.Level, message: []const u8) void {
        const socket_path = self.ipc_socket_path orelse return;
        toast_client.show(self.allocator, socket_path, level, message) catch {};
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
        app.maximized = hasAttachedState(states);
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
        if (state != c.WL_POINTER_BUTTON_STATE_PRESSED) return;
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        app.last_button_serial = serial;
        if (button == 0x111) {
            app.openContextMenu();
            app.redraw() catch {};
            return;
        }
        if (button != 0x110) return;
        if (app.context_menu != null) {
            switch (app.hovered) {
                .context_details,
                .context_pin,
                .context_unpin,
                .context_new_folder,
                .context_new_file,
                .context_open_terminal,
                .context_select_all,
                .context_paste,
                .context_sort_name,
                .context_sort_modified,
                .context_sort_size,
                => {},
                else => app.context_menu = null,
            }
        }
        app.handleAction();
        app.updateHover();
        app.redraw() catch {};
    }
    fn handlePointerAxis(data: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, axis: u32, value: c.wl_fixed_t) callconv(.c) void {
        if (axis != c.WL_POINTER_AXIS_VERTICAL_SCROLL) return;
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        const amount = c.wl_fixed_to_double(value);
        if (@abs(amount) < 0.01) return;
        app.scrollAtPointer(if (amount > 0) 1 else -1);
    }
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

        if (app.dialog.kind != .none) {
            switch (keysym) {
                c.XKB_KEY_Escape => {
                    app.dialog.clear();
                    app.dirty = true;
                    return;
                },
                c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => {
                    app.confirmDialog();
                    return;
                },
                c.XKB_KEY_BackSpace => {
                    app.backspaceDialogText();
                    return;
                },
                else => {
                    var utf8_buf = [_]u8{0} ** 64;
                    const written = c.xkb_state_key_get_utf8(xkb_state, keycode, @ptrCast(&utf8_buf[0]), utf8_buf.len);
                    if (written > 0) {
                        const text = std.mem.sliceTo(utf8_buf[0..], 0);
                        app.appendDialogText(text);
                    }
                    return;
                },
            }
        }

        const ctrl_pressed = isCtrlPressed(app);
        const shift_pressed = isShiftPressed(app);
        if (ctrl_pressed and shift_pressed and (keysym == c.XKB_KEY_N or keysym == c.XKB_KEY_n)) {
            app.beginCreateFolderDialog();
            return;
        }
        if (ctrl_pressed and !shift_pressed and (keysym == c.XKB_KEY_A or keysym == c.XKB_KEY_a)) {
            app.browser.selectAll() catch {};
            app.context_menu = null;
            app.dirty = true;
            return;
        }
        if (ctrl_pressed and !shift_pressed and (keysym == c.XKB_KEY_V or keysym == c.XKB_KEY_v)) {
            app.context_menu = null;
            app.pasteFromClipboard();
            app.dirty = true;
            return;
        }

        switch (keysym) {
            c.XKB_KEY_Escape => {
                if (app.context_menu != null) {
                    app.context_menu = null;
                } else {
                    app.running = false;
                }
            },
            c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => app.openSelectedPath(),
            c.XKB_KEY_F2 => app.beginRenameDialog(),
            c.XKB_KEY_Delete => if (isShiftPressed(app)) app.beginPermanentDeleteDialog() else app.beginDeleteDialog(),
            else => return,
        }
        app.dirty = true;
    }

    fn handleKeyboardModifiers(data: ?*anyopaque, _: ?*c.struct_wl_keyboard, _: u32, mods_depressed: u32, mods_latched: u32, mods_locked: u32, group: u32) callconv(.c) void {
        const raw_app = data orelse return;
        const app: *App = @ptrCast(@alignCast(raw_app));
        const state = app.xkb_state orelse return;
        _ = c.xkb_state_update_mask(state, mods_depressed, mods_latched, mods_locked, 0, 0, group);
    }

    fn handleKeyboardRepeatInfo(_: ?*anyopaque, _: ?*c.struct_wl_keyboard, _: i32, _: i32) callconv(.c) void {}
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

fn hasAttachedState(states: [*c]c.struct_wl_array) bool {
    return hasState(states, c.XDG_TOPLEVEL_STATE_MAXIMIZED) or
        hasState(states, c.XDG_TOPLEVEL_STATE_TILED_LEFT) or
        hasState(states, c.XDG_TOPLEVEL_STATE_TILED_RIGHT) or
        hasState(states, c.XDG_TOPLEVEL_STATE_TILED_TOP) or
        hasState(states, c.XDG_TOPLEVEL_STATE_TILED_BOTTOM);
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
        .breadcrumb_up => rhs == .breadcrumb_up,
        .open_selected => rhs == .open_selected,
        .new_folder => rhs == .new_folder,
        .rename_selected => rhs == .rename_selected,
        .delete_selected => rhs == .delete_selected,
        .previous => rhs == .previous,
        .next => rhs == .next,
        .sort_modified => rhs == .sort_modified,
        .context_details => rhs == .context_details,
        .context_pin => rhs == .context_pin,
        .context_unpin => rhs == .context_unpin,
        .context_new_folder => rhs == .context_new_folder,
        .context_new_file => rhs == .context_new_file,
        .context_open_terminal => rhs == .context_open_terminal,
        .context_select_all => rhs == .context_select_all,
        .context_paste => rhs == .context_paste,
        .context_sort_name => rhs == .context_sort_name,
        .context_sort_modified => rhs == .context_sort_modified,
        .context_sort_size => rhs == .context_sort_size,
        .dialog_confirm => rhs == .dialog_confirm,
        .dialog_cancel => rhs == .dialog_cancel,
        .sidebar => |left_target| switch (rhs) {
            .sidebar => |right_target| left_target == right_target,
            else => false,
        },
        .pinned_folder => |left_index| switch (rhs) {
            .pinned_folder => |right_index| left_index == right_index,
            else => false,
        },
        .entry => |left_index| switch (rhs) {
            .entry => |right_index| left_index == right_index,
            else => false,
        },
    };
}

fn dialogKindForRender(kind: DialogKind) render.DialogKind {
    return switch (kind) {
        .none => .none,
        .new_folder => .new_folder,
        .new_file => .new_file,
        .rename => .rename,
        .delete_confirm => .delete_confirm,
        .delete_permanent_confirm => .delete_permanent_confirm,
    };
}

fn clipboardLineToPath(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, line, "file://")) {
        return try allocator.dupe(u8, line);
    }

    var rest = line["file://".len..];
    if (std.mem.startsWith(u8, rest, "localhost/")) {
        rest = rest["localhost".len..];
    } else if (rest.len > 0 and rest[0] != '/') {
        return error.UnsupportedFileUri;
    }
    return try percentDecode(allocator, rest);
}

fn percentDecode(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var decoded: std.ArrayListUnmanaged(u8) = .empty;
    errdefer decoded.deinit(allocator);

    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '%' and index + 2 < text.len) {
            const high = std.fmt.charToDigit(text[index + 1], 16) catch null;
            const low = std.fmt.charToDigit(text[index + 2], 16) catch null;
            if (high != null and low != null) {
                try decoded.append(allocator, @intCast(high.? * 16 + low.?));
                index += 3;
                continue;
            }
        }
        try decoded.append(allocator, text[index]);
        index += 1;
    }
    return try decoded.toOwnedSlice(allocator);
}

fn isShiftPressed(app: *const App) bool {
    const state = app.xkb_state orelse return false;
    const keymap = app.xkb_keymap orelse return false;
    const shift_index = c.xkb_keymap_mod_get_index(keymap, c.XKB_MOD_NAME_SHIFT);
    if (shift_index == c.XKB_MOD_INVALID) return false;
    return c.xkb_state_mod_index_is_active(state, shift_index, c.XKB_STATE_MODS_EFFECTIVE) == 1;
}

fn isCtrlPressed(app: *const App) bool {
    const state = app.xkb_state orelse return false;
    const keymap = app.xkb_keymap orelse return false;
    const ctrl_index = c.xkb_keymap_mod_get_index(keymap, c.XKB_MOD_NAME_CTRL);
    if (ctrl_index == c.XKB_MOD_INVALID) return false;
    return c.xkb_state_mod_index_is_active(state, ctrl_index, c.XKB_STATE_MODS_EFFECTIVE) == 1;
}
