const std = @import("std");
const c = @import("../wl.zig").c;
const default_workspace_count = @import("../shell/workspace.zig").default_workspace_count;
const settings_model = @import("../settings/model.zig");
const toast_model = @import("../toast/model.zig");

pub const WorkspaceState = struct {
    current: usize,
    count: usize,
};

pub const WorkspaceSummary = struct {
    window_count: usize = 0,
    focused: bool = false,
    preview_len: usize = 0,
    preview: [96]u8 = [_]u8{0} ** 96,
};

pub const WorkspaceSnapshot = struct {
    current: usize,
    count: usize,
    summaries: [default_workspace_count]WorkspaceSummary = [_]WorkspaceSummary{.{}} ** default_workspace_count,
};

pub const GetWorkspaceStateCallback = *const fn (?*anyopaque) WorkspaceSnapshot;
pub const ActivateWorkspaceCallback = *const fn (?*anyopaque, usize) void;
pub const MoveFocusedWorkspaceCallback = *const fn (?*anyopaque, usize) void;
pub const SetWallpaperCallback = *const fn (?*anyopaque, []const u8) void;
pub const ToggleLauncherCallback = *const fn (?*anyopaque) void;
pub const GetRuntimeStateCallback = *const fn (?*anyopaque) settings_model.RuntimeState;
pub const SetWorkspaceWrapCallback = *const fn (?*anyopaque, bool) void;
pub const FocusAppCallback = *const fn (?*anyopaque, []const u8) bool;
pub const ShowPreviewCallback = *const fn (?*anyopaque, []const u8, i32) void;
pub const HidePreviewCallback = *const fn (?*anyopaque) void;
pub const UpdateDockGlassCallback = *const fn (?*anyopaque, c.struct_wlr_box, i32) void;

pub const IpcServer = struct {
    allocator: std.mem.Allocator,
    event_loop: ?*c.struct_wl_event_loop = null,
    socket_path: ?[]u8 = null,
    fd: ?std.posix.socket_t = null,
    event_source: ?*c.struct_wl_event_source = null,
    toasts: toast_model.State = .{},
    next_toast_id: u32 = 1,
    ctx: ?*anyopaque = null,
    get_workspace_state_cb: ?GetWorkspaceStateCallback = null,
    activate_workspace_cb: ?ActivateWorkspaceCallback = null,
    move_focused_workspace_cb: ?MoveFocusedWorkspaceCallback = null,
    set_wallpaper_cb: ?SetWallpaperCallback = null,
    toggle_launcher_cb: ?ToggleLauncherCallback = null,
    get_runtime_state_cb: ?GetRuntimeStateCallback = null,
    set_workspace_wrap_cb: ?SetWorkspaceWrapCallback = null,
    focus_app_cb: ?FocusAppCallback = null,
    show_preview_cb: ?ShowPreviewCallback = null,
    hide_preview_cb: ?HidePreviewCallback = null,
    update_dock_glass_cb: ?UpdateDockGlassCallback = null,

    pub fn init(allocator: std.mem.Allocator) IpcServer {
        return .{ .allocator = allocator };
    }

    pub fn start(self: *IpcServer, event_loop: *c.struct_wl_event_loop, socket_name: [*c]const u8) !void {
        const runtime_dir = std.process.getEnvVarOwned(self.allocator, "XDG_RUNTIME_DIR") catch "/tmp";
        defer if (!std.mem.eql(u8, runtime_dir, "/tmp")) self.allocator.free(runtime_dir);

        const socket_path = try std.fmt.allocPrint(self.allocator, "{s}/axia-{s}.sock", .{ runtime_dir, std.mem.span(socket_name) });
        errdefer self.allocator.free(socket_path);

        std.fs.deleteFileAbsolute(socket_path) catch {};

        const address = try std.net.Address.initUnix(socket_path);
        const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK, 0);
        errdefer std.posix.close(fd);

        try std.posix.bind(fd, &address.any, address.getOsSockLen());
        try std.posix.listen(fd, 8);

        const source = c.wl_event_loop_add_fd(event_loop, fd, c.WL_EVENT_READABLE, handleReadable, self);
        if (source == null) return error.IpcEventSourceCreateFailed;
        self.event_loop = event_loop;
        self.socket_path = socket_path;
        self.fd = fd;
        self.event_source = source;
    }

    pub fn setWorkspaceCallbacks(
        self: *IpcServer,
        ctx: ?*anyopaque,
        get_workspace_state_cb: GetWorkspaceStateCallback,
        activate_workspace_cb: ActivateWorkspaceCallback,
        move_focused_workspace_cb: MoveFocusedWorkspaceCallback,
        set_wallpaper_cb: SetWallpaperCallback,
        toggle_launcher_cb: ToggleLauncherCallback,
        get_runtime_state_cb: GetRuntimeStateCallback,
        set_workspace_wrap_cb: SetWorkspaceWrapCallback,
        focus_app_cb: FocusAppCallback,
        show_preview_cb: ShowPreviewCallback,
        hide_preview_cb: HidePreviewCallback,
        update_dock_glass_cb: UpdateDockGlassCallback,
    ) void {
        self.ctx = ctx;
        self.get_workspace_state_cb = get_workspace_state_cb;
        self.activate_workspace_cb = activate_workspace_cb;
        self.move_focused_workspace_cb = move_focused_workspace_cb;
        self.set_wallpaper_cb = set_wallpaper_cb;
        self.toggle_launcher_cb = toggle_launcher_cb;
        self.get_runtime_state_cb = get_runtime_state_cb;
        self.set_workspace_wrap_cb = set_workspace_wrap_cb;
        self.focus_app_cb = focus_app_cb;
        self.show_preview_cb = show_preview_cb;
        self.hide_preview_cb = hide_preview_cb;
        self.update_dock_glass_cb = update_dock_glass_cb;
    }

    pub fn deinit(self: *IpcServer) void {
        if (self.event_source) |event_source| {
            _ = c.wl_event_source_remove(event_source);
        }
        if (self.fd) |fd| std.posix.close(fd);
        if (self.socket_path) |socket_path| {
            std.fs.deleteFileAbsolute(socket_path) catch {};
            self.allocator.free(socket_path);
        }
    }

    pub fn path(self: *const IpcServer) []const u8 {
        return self.socket_path orelse "";
    }

    fn handleReadable(fd: c_int, _: u32, data: ?*anyopaque) callconv(.c) c_int {
        const raw_server = data orelse return 0;
        const server: *IpcServer = @ptrCast(@alignCast(raw_server));

        while (true) {
            const client_fd = std.posix.accept(fd, null, null, std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK) catch |err| switch (err) {
                error.WouldBlock => break,
                else => return 0,
            };
            defer std.posix.close(client_fd);

            server.handleClient(client_fd);
        }

        return 0;
    }

    fn handleClient(self: *IpcServer, client_fd: std.posix.socket_t) void {
        var buffer: [128]u8 = undefined;
        const read_len = std.posix.read(client_fd, &buffer) catch return;
        if (read_len == 0) return;

        const request = std.mem.trim(u8, buffer[0..read_len], " \r\n\t");
        if (std.mem.eql(u8, request, "workspace get")) {
            self.writeWorkspaceState(client_fd);
            return;
        }

        if (std.mem.startsWith(u8, request, "workspace activate ")) {
            const raw_index = request["workspace activate ".len..];
            const index = std.fmt.parseUnsigned(usize, raw_index, 10) catch {
                _ = std.posix.write(client_fd, "error invalid-index\n") catch {};
                return;
            };
            if (self.activate_workspace_cb) |callback| {
                callback(self.ctx, index);
            }
            self.writeWorkspaceState(client_fd);
            return;
        }

        if (std.mem.startsWith(u8, request, "workspace move-focused ")) {
            const raw_index = request["workspace move-focused ".len..];
            const index = std.fmt.parseUnsigned(usize, raw_index, 10) catch {
                _ = std.posix.write(client_fd, "error invalid-index\n") catch {};
                return;
            };
            if (self.move_focused_workspace_cb) |callback| {
                callback(self.ctx, index);
            }
            self.writeWorkspaceState(client_fd);
            return;
        }

        if (std.mem.startsWith(u8, request, "wallpaper set ")) {
            const wallpaper_path = std.mem.trim(u8, request["wallpaper set ".len..], " \r\n\t");
            if (wallpaper_path.len == 0) {
                _ = std.posix.write(client_fd, "error invalid-path\n") catch {};
                return;
            }
            if (self.set_wallpaper_cb) |callback| {
                callback(self.ctx, wallpaper_path);
            }
            _ = std.posix.write(client_fd, "ok\n") catch {};
            return;
        }

        if (std.mem.eql(u8, request, "launcher toggle")) {
            if (self.toggle_launcher_cb) |callback| {
                callback(self.ctx);
            }
            _ = std.posix.write(client_fd, "ok\n") catch {};
            return;
        }

        if (std.mem.eql(u8, request, "runtime get")) {
            self.writeRuntimeState(client_fd);
            return;
        }

        if (std.mem.startsWith(u8, request, "workspace wrap ")) {
            const raw_enabled = std.mem.trim(u8, request["workspace wrap ".len..], " \r\n\t");
            const enabled = std.mem.eql(u8, raw_enabled, "1") or std.ascii.eqlIgnoreCase(raw_enabled, "true");
            if (self.set_workspace_wrap_cb) |callback| {
                callback(self.ctx, enabled);
            }
            _ = std.posix.write(client_fd, "ok\n") catch {};
            return;
        }

        if (std.mem.startsWith(u8, request, "app focus ")) {
            const app_id = std.mem.trim(u8, request["app focus ".len..], " \r\n\t");
            if (app_id.len == 0) {
                _ = std.posix.write(client_fd, "error invalid-app\n") catch {};
                return;
            }
            const handled = if (self.focus_app_cb) |callback| callback(self.ctx, app_id) else false;
            _ = std.posix.write(client_fd, if (handled) "ok\n" else "error not-found\n") catch {};
            return;
        }

        if (std.mem.startsWith(u8, request, "preview show ")) {
            const payload = std.mem.trim(u8, request["preview show ".len..], " \r\n\t");
            var parts = std.mem.tokenizeAny(u8, payload, " ");
            const app_id = parts.next() orelse {
                _ = std.posix.write(client_fd, "error invalid-preview\n") catch {};
                return;
            };
            const raw_anchor_x = parts.next() orelse {
                _ = std.posix.write(client_fd, "error invalid-preview\n") catch {};
                return;
            };
            const anchor_x = std.fmt.parseInt(i32, raw_anchor_x, 10) catch {
                _ = std.posix.write(client_fd, "error invalid-preview\n") catch {};
                return;
            };
            if (self.show_preview_cb) |callback| {
                callback(self.ctx, app_id, anchor_x);
            }
            _ = std.posix.write(client_fd, "ok\n") catch {};
            return;
        }

        if (std.mem.eql(u8, request, "preview hide")) {
            if (self.hide_preview_cb) |callback| {
                callback(self.ctx);
            }
            _ = std.posix.write(client_fd, "ok\n") catch {};
            return;
        }

        if (std.mem.startsWith(u8, request, "dock glass ")) {
            const payload = std.mem.trim(u8, request["dock glass ".len..], " \r\n\t");
            var parts = std.mem.tokenizeAny(u8, payload, " ");
            const raw_x = parts.next() orelse {
                _ = std.posix.write(client_fd, "error invalid-dock-glass\n") catch {};
                return;
            };
            const raw_y = parts.next() orelse {
                _ = std.posix.write(client_fd, "error invalid-dock-glass\n") catch {};
                return;
            };
            const raw_w = parts.next() orelse {
                _ = std.posix.write(client_fd, "error invalid-dock-glass\n") catch {};
                return;
            };
            const raw_h = parts.next() orelse {
                _ = std.posix.write(client_fd, "error invalid-dock-glass\n") catch {};
                return;
            };
            const raw_surface_h = parts.next() orelse {
                _ = std.posix.write(client_fd, "error invalid-dock-glass\n") catch {};
                return;
            };

            const rect = c.struct_wlr_box{
                .x = std.fmt.parseInt(i32, raw_x, 10) catch {
                    _ = std.posix.write(client_fd, "error invalid-dock-glass\n") catch {};
                    return;
                },
                .y = std.fmt.parseInt(i32, raw_y, 10) catch {
                    _ = std.posix.write(client_fd, "error invalid-dock-glass\n") catch {};
                    return;
                },
                .width = std.fmt.parseInt(i32, raw_w, 10) catch {
                    _ = std.posix.write(client_fd, "error invalid-dock-glass\n") catch {};
                    return;
                },
                .height = std.fmt.parseInt(i32, raw_h, 10) catch {
                    _ = std.posix.write(client_fd, "error invalid-dock-glass\n") catch {};
                    return;
                },
            };
            const surface_height = std.fmt.parseInt(i32, raw_surface_h, 10) catch {
                _ = std.posix.write(client_fd, "error invalid-dock-glass\n") catch {};
                return;
            };
            if (self.update_dock_glass_cb) |callback| {
                callback(self.ctx, rect, surface_height);
            }
            _ = std.posix.write(client_fd, "ok\n") catch {};
            return;
        }

        if (std.mem.startsWith(u8, request, "toast show ")) {
            const payload = std.mem.trim(u8, request["toast show ".len..], " \r\n\t");
            var parts = std.mem.tokenizeScalar(u8, payload, ' ');
            const raw_level = parts.next() orelse {
                _ = std.posix.write(client_fd, "error invalid-toast\n") catch {};
                return;
            };
            const message = std.mem.trimLeft(u8, payload[raw_level.len..], " ");
            const level = toast_model.parseLevel(raw_level) orelse {
                _ = std.posix.write(client_fd, "error invalid-toast\n") catch {};
                return;
            };
            if (message.len == 0) {
                _ = std.posix.write(client_fd, "error invalid-toast\n") catch {};
                return;
            }
            self.pushToast(level, message);
            _ = std.posix.write(client_fd, "ok\n") catch {};
            return;
        }

        if (std.mem.eql(u8, request, "toast get")) {
            self.writeToastState(client_fd);
            return;
        }

        _ = std.posix.write(client_fd, "error unknown-command\n") catch {};
    }

    fn writeWorkspaceState(self: *IpcServer, client_fd: std.posix.socket_t) void {
        const state = if (self.get_workspace_state_cb) |callback|
            callback(self.ctx)
        else
            WorkspaceSnapshot{ .current = 0, .count = 0 };

        var response: [2048]u8 = undefined;
        var stream = std.io.fixedBufferStream(&response);
        const writer = stream.writer();

        writer.print("ok {} {}\n", .{ state.current, state.count }) catch return;
        for (0..state.count) |index| {
            const summary = state.summaries[index];
            writer.print(
                "ws {} {} {} {s}\n",
                .{ index, summary.window_count, @intFromBool(summary.focused), summary.preview[0..summary.preview_len] },
            ) catch return;
        }

        _ = std.posix.write(client_fd, stream.getWritten()) catch {};
    }

    fn writeRuntimeState(self: *IpcServer, client_fd: std.posix.socket_t) void {
        const state = if (self.get_runtime_state_cb) |callback|
            callback(self.ctx)
        else
            settings_model.RuntimeState{};

        var response: [2048]u8 = undefined;
        var stream = std.io.fixedBufferStream(&response);
        const writer = stream.writer();

        writer.print(
            "ok runtime {} {} {} {s}\n",
            .{ state.workspace_current, state.workspace_count, state.display_count, state.socketNameText() },
        ) catch return;

        for (0..state.display_count) |index| {
            const display = state.displays[index];
            writer.print(
                "display {} {} {} {} {s}\n",
                .{ index, display.width, display.height, @intFromBool(display.primary), display.nameText() },
            ) catch return;
        }

        for (0..state.app_count) |index| {
            const app = state.apps[index];
            writer.print(
                "app {} {} {s} {s}\n",
                .{ index, @intFromBool(app.focused), app.idText(), app.titleText() },
            ) catch return;
        }

        _ = std.posix.write(client_fd, stream.getWritten()) catch {};
    }

    fn writeToastState(self: *IpcServer, client_fd: std.posix.socket_t) void {
        self.cleanupExpiredToasts();

        var response: [2048]u8 = undefined;
        var stream = std.io.fixedBufferStream(&response);
        const writer = stream.writer();

        writer.print("ok toasts {}\n", .{self.toasts.count}) catch return;
        for (0..self.toasts.count) |index| {
            const item = self.toasts.items[index];
            writer.print(
                "toast {} {s} {s}\n",
                .{ item.id, toast_model.levelName(item.level), item.messageText() },
            ) catch return;
        }

        _ = std.posix.write(client_fd, stream.getWritten()) catch {};
    }

    fn pushToast(self: *IpcServer, level: toast_model.Level, message: []const u8) void {
        self.cleanupExpiredToasts();
        if (self.toasts.count == self.toasts.items.len) {
            var index: usize = 1;
            while (index < self.toasts.count) : (index += 1) {
                self.toasts.items[index - 1] = self.toasts.items[index];
            }
            self.toasts.count -= 1;
        }

        var item = toast_model.Toast{
            .id = self.next_toast_id,
            .level = level,
            .created_ms = std.time.milliTimestamp(),
        };
        self.next_toast_id +%= 1;
        toast_model.copyMessage(&item, message);
        self.toasts.items[self.toasts.count] = item;
        self.toasts.count += 1;
    }

    fn cleanupExpiredToasts(self: *IpcServer) void {
        const now_ms = std.time.milliTimestamp();
        var write_index: usize = 0;
        for (0..self.toasts.count) |index| {
            const item = self.toasts.items[index];
            if (now_ms - item.created_ms >= item.duration_ms) continue;
            self.toasts.items[write_index] = item;
            write_index += 1;
        }
        self.toasts.count = write_index;
    }
};
