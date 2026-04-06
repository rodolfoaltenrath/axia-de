const std = @import("std");
const c = @import("../wl.zig").c;
const default_workspace_count = @import("../shell/workspace.zig").default_workspace_count;
const settings_model = @import("../settings/model.zig");

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

pub const IpcServer = struct {
    allocator: std.mem.Allocator,
    event_loop: ?*c.struct_wl_event_loop = null,
    socket_path: ?[]u8 = null,
    fd: ?std.posix.socket_t = null,
    event_source: ?*c.struct_wl_event_source = null,
    ctx: ?*anyopaque = null,
    get_workspace_state_cb: ?GetWorkspaceStateCallback = null,
    activate_workspace_cb: ?ActivateWorkspaceCallback = null,
    move_focused_workspace_cb: ?MoveFocusedWorkspaceCallback = null,
    set_wallpaper_cb: ?SetWallpaperCallback = null,
    toggle_launcher_cb: ?ToggleLauncherCallback = null,
    get_runtime_state_cb: ?GetRuntimeStateCallback = null,
    set_workspace_wrap_cb: ?SetWorkspaceWrapCallback = null,

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
    ) void {
        self.ctx = ctx;
        self.get_workspace_state_cb = get_workspace_state_cb;
        self.activate_workspace_cb = activate_workspace_cb;
        self.move_focused_workspace_cb = move_focused_workspace_cb;
        self.set_wallpaper_cb = set_wallpaper_cb;
        self.toggle_launcher_cb = toggle_launcher_cb;
        self.get_runtime_state_cb = get_runtime_state_cb;
        self.set_workspace_wrap_cb = set_workspace_wrap_cb;
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

        _ = std.posix.write(client_fd, stream.getWritten()) catch {};
    }
};
