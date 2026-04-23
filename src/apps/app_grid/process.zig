const std = @import("std");

const log = std.log.scoped(.axia_app_grid_process);

pub const AppGridProcess = struct {
    allocator: std.mem.Allocator,
    child: ?std.process.Child = null,

    pub fn init(allocator: std.mem.Allocator) AppGridProcess {
        return .{ .allocator = allocator };
    }

    pub fn spawn(self: *AppGridProcess, socket_name: [*c]const u8, ipc_socket_path: []const u8) void {
        if (self.child) |*child| {
            _ = child.kill() catch |err| switch (err) {
                error.AlreadyTerminated => {},
                else => {
                    log.err("failed to stop previous app grid: {}", .{err});
                },
            };
            _ = child.wait() catch {};
            self.child = null;
        }

        const exe_dir = std.fs.selfExeDirPathAlloc(self.allocator) catch |err| {
            log.err("failed to resolve exe dir for app grid: {}", .{err});
            return;
        };
        defer self.allocator.free(exe_dir);

        const app_grid_path = std.fs.path.join(self.allocator, &.{ exe_dir, "axia-app-grid" }) catch |err| {
            log.err("failed to build app grid path: {}", .{err});
            return;
        };
        defer self.allocator.free(app_grid_path);

        const argv = self.allocator.alloc([]const u8, 1) catch |err| {
            log.err("failed to allocate app grid argv: {}", .{err});
            return;
        };
        defer self.allocator.free(argv);
        argv[0] = app_grid_path;

        var env_map = std.process.EnvMap.init(self.allocator);
        defer env_map.deinit();

        const inherited = std.process.getEnvMap(self.allocator) catch |err| {
            log.err("failed to read env for app grid: {}", .{err});
            return;
        };
        defer {
            var copy = inherited;
            copy.deinit();
        }

        var it = inherited.iterator();
        while (it.next()) |entry| {
            env_map.put(entry.key_ptr.*, entry.value_ptr.*) catch |err| {
                log.err("failed to copy env for app grid: {}", .{err});
                return;
            };
        }

        env_map.put("WAYLAND_DISPLAY", std.mem.span(socket_name)) catch |err| {
            log.err("failed to set WAYLAND_DISPLAY for app grid: {}", .{err});
            return;
        };
        env_map.put("AXIA_BIN_DIR", exe_dir) catch |err| {
            log.err("failed to set AXIA_BIN_DIR for app grid: {}", .{err});
            return;
        };
        env_map.put("AXIA_IPC_SOCKET", ipc_socket_path) catch |err| {
            log.err("failed to set AXIA_IPC_SOCKET for app grid: {}", .{err});
            return;
        };

        var child = std.process.Child.init(argv, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        child.env_map = &env_map;
        child.spawn() catch |err| {
            log.err("failed to spawn app grid: {}", .{err});
            return;
        };

        self.child = child;
        log.info("app grid spawned", .{});
    }

    pub fn reapIfExited(self: *AppGridProcess) ?std.process.Child.Term {
        const child = if (self.child) |*active|
            active
        else
            return null;

        const result = std.posix.waitpid(child.id, std.posix.W.NOHANG);
        if (result.pid == 0) return null;

        const term = termFromStatus(result.status);
        self.child = null;
        return term;
    }

    pub fn deinit(self: *AppGridProcess) void {
        if (self.child) |*child| {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            self.child = null;
        }
    }
};

fn termFromStatus(status: u32) std.process.Child.Term {
    return if (std.posix.W.IFEXITED(status))
        .{ .Exited = std.posix.W.EXITSTATUS(status) }
    else if (std.posix.W.IFSIGNALED(status))
        .{ .Signal = std.posix.W.TERMSIG(status) }
    else if (std.posix.W.IFSTOPPED(status))
        .{ .Stopped = std.posix.W.STOPSIG(status) }
    else
        .{ .Unknown = status };
}
