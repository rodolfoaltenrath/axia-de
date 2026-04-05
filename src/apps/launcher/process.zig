const std = @import("std");

const log = std.log.scoped(.axia_launcher_process);

pub const LauncherProcess = struct {
    allocator: std.mem.Allocator,
    child: ?std.process.Child = null,

    pub fn init(allocator: std.mem.Allocator) LauncherProcess {
        return .{ .allocator = allocator };
    }

    pub fn spawn(self: *LauncherProcess, socket_name: [*c]const u8) void {
        if (self.child) |*child| {
            _ = child.kill() catch |err| switch (err) {
                error.AlreadyTerminated => {},
                else => {
                    log.err("failed to stop previous launcher: {}", .{err});
                },
            };
            _ = child.wait() catch {};
            self.child = null;
        }

        const exe_dir = std.fs.selfExeDirPathAlloc(self.allocator) catch |err| {
            log.err("failed to resolve exe dir for launcher: {}", .{err});
            return;
        };
        defer self.allocator.free(exe_dir);

        const launcher_path = std.fs.path.join(self.allocator, &.{ exe_dir, "axia-launcher" }) catch |err| {
            log.err("failed to build launcher path: {}", .{err});
            return;
        };
        defer self.allocator.free(launcher_path);

        const argv = self.allocator.alloc([]const u8, 1) catch |err| {
            log.err("failed to allocate launcher argv: {}", .{err});
            return;
        };
        defer self.allocator.free(argv);
        argv[0] = launcher_path;

        var env_map = std.process.EnvMap.init(self.allocator);
        defer env_map.deinit();

        const inherited = std.process.getEnvMap(self.allocator) catch |err| {
            log.err("failed to read env for launcher: {}", .{err});
            return;
        };
        defer {
            var copy = inherited;
            copy.deinit();
        }

        var it = inherited.iterator();
        while (it.next()) |entry| {
            env_map.put(entry.key_ptr.*, entry.value_ptr.*) catch |err| {
                log.err("failed to copy env for launcher: {}", .{err});
                return;
            };
        }

        env_map.put("WAYLAND_DISPLAY", std.mem.span(socket_name)) catch |err| {
            log.err("failed to set WAYLAND_DISPLAY for launcher: {}", .{err});
            return;
        };
        env_map.put("AXIA_BIN_DIR", exe_dir) catch |err| {
            log.err("failed to set AXIA_BIN_DIR for launcher: {}", .{err});
            return;
        };

        var child = std.process.Child.init(argv, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        child.env_map = &env_map;
        child.spawn() catch |err| {
            log.err("failed to spawn launcher: {}", .{err});
            return;
        };

        self.child = child;
        log.info("launcher spawned", .{});
    }

    pub fn deinit(self: *LauncherProcess) void {
        if (self.child) |*child| {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            self.child = null;
        }
    }
};
