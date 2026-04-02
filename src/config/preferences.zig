const std = @import("std");

const log = std.log.scoped(.axia_prefs);

pub const Preferences = struct {
    allocator: std.mem.Allocator,
    wallpaper_path: ?[]u8 = null,

    pub fn deinit(self: *Preferences) void {
        if (self.wallpaper_path) |path| {
            self.allocator.free(path);
            self.wallpaper_path = null;
        }
    }
};

pub fn load(allocator: std.mem.Allocator) !Preferences {
    const path = try preferencesPath(allocator);
    defer allocator.free(path);

    const contents = std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024) catch |err| switch (err) {
        error.FileNotFound => return .{ .allocator = allocator },
        else => return err,
    };
    defer allocator.free(contents);

    var prefs = Preferences{ .allocator = allocator };
    var lines = std.mem.tokenizeScalar(u8, contents, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.startsWith(u8, line, "wallpaper=")) {
            const value = std.mem.trim(u8, line["wallpaper=".len..], " \r\t");
            if (value.len > 0) {
                prefs.wallpaper_path = try allocator.dupe(u8, value);
            }
        }
    }

    return prefs;
}

pub fn saveWallpaper(allocator: std.mem.Allocator, wallpaper_path: []const u8) !void {
    const dir_path = try preferencesDirPath(allocator);
    defer allocator.free(dir_path);
    try std.fs.cwd().makePath(dir_path);

    const file_path = try preferencesPath(allocator);
    defer allocator.free(file_path);

    const contents = try std.fmt.allocPrint(allocator, "# Axia-DE preferences\nwallpaper={s}\n", .{wallpaper_path});
    defer allocator.free(contents);

    try std.fs.cwd().writeFile(.{
        .sub_path = file_path,
        .data = contents,
    });
    log.info("saved preferences to {s}", .{file_path});
}

fn preferencesPath(allocator: std.mem.Allocator) ![]u8 {
    const dir_path = try preferencesDirPath(allocator);
    defer allocator.free(dir_path);
    return try std.fs.path.join(allocator, &.{ dir_path, "preferences.conf" });
}

fn preferencesDirPath(allocator: std.mem.Allocator) ![]u8 {
    const config_home = try configHome(allocator);
    defer allocator.free(config_home);
    return try std.fs.path.join(allocator, &.{ config_home, "axia-de" });
}

fn configHome(allocator: std.mem.Allocator) ![]u8 {
    const from_env = std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (from_env) |value| {
        if (value.len > 0) return value;
        allocator.free(value);
    }

    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, ".config" });
}
