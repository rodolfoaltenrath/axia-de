const std = @import("std");

const log = std.log.scoped(.axia_prefs);

pub const AccentPreset = enum {
    aurora,
    ember,
    moss,
};

pub const DockSizePreset = enum {
    compact,
    comfortable,
    large,
};

pub const DockIconSizePreset = enum {
    small,
    medium,
    large,
};

pub const Preferences = struct {
    allocator: std.mem.Allocator,
    wallpaper_path: ?[]u8 = null,
    accent: AccentPreset = .aurora,
    reduce_transparency: bool = false,
    panel_show_seconds: bool = false,
    panel_show_date: bool = true,
    dock_size: DockSizePreset = .comfortable,
    dock_icon_size: DockIconSizePreset = .medium,
    dock_auto_hide: bool = false,
    dock_strong_hover: bool = false,
    workspace_wrap: bool = true,
    startup_workspace: usize = 0,

    pub fn deinit(self: *Preferences) void {
        if (self.wallpaper_path) |path| {
            self.allocator.free(path);
            self.wallpaper_path = null;
        }
    }

    pub fn save(self: *const Preferences) !void {
        const dir_path = try preferencesDirPath(self.allocator);
        defer self.allocator.free(dir_path);
        try std.fs.cwd().makePath(dir_path);

        const file_path = try preferencesPath(self.allocator);
        defer self.allocator.free(file_path);

        const contents = try std.fmt.allocPrint(
            self.allocator,
            \\# Axia-DE preferences
            \\wallpaper={s}
            \\accent={s}
            \\reduce_transparency={d}
            \\panel_show_seconds={d}
            \\panel_show_date={d}
            \\dock_size={s}
            \\dock_icon_size={s}
            \\dock_auto_hide={d}
            \\dock_strong_hover={d}
            \\workspace_wrap={d}
            \\startup_workspace={d}
            \\
        ,
            .{
                self.wallpaper_path orelse "",
                accentToString(self.accent),
                @intFromBool(self.reduce_transparency),
                @intFromBool(self.panel_show_seconds),
                @intFromBool(self.panel_show_date),
                dockSizeToString(self.dock_size),
                dockIconSizeToString(self.dock_icon_size),
                @intFromBool(self.dock_auto_hide),
                @intFromBool(self.dock_strong_hover),
                @intFromBool(self.workspace_wrap),
                self.startup_workspace,
            },
        );
        defer self.allocator.free(contents);

        try std.fs.cwd().writeFile(.{
            .sub_path = file_path,
            .data = contents,
        });
        log.info("saved preferences to {s}", .{file_path});
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
            continue;
        }

        if (std.mem.startsWith(u8, line, "accent=")) {
            prefs.accent = parseAccent(std.mem.trim(u8, line["accent=".len..], " \r\t"));
            continue;
        }

        if (std.mem.startsWith(u8, line, "reduce_transparency=")) {
            prefs.reduce_transparency = parseBool(std.mem.trim(u8, line["reduce_transparency=".len..], " \r\t"));
            continue;
        }

        if (std.mem.startsWith(u8, line, "panel_show_seconds=")) {
            prefs.panel_show_seconds = parseBool(std.mem.trim(u8, line["panel_show_seconds=".len..], " \r\t"));
            continue;
        }

        if (std.mem.startsWith(u8, line, "panel_show_date=")) {
            prefs.panel_show_date = parseBool(std.mem.trim(u8, line["panel_show_date=".len..], " \r\t"));
            continue;
        }

        if (std.mem.startsWith(u8, line, "dock_size=")) {
            prefs.dock_size = parseDockSize(std.mem.trim(u8, line["dock_size=".len..], " \r\t"));
            continue;
        }

        if (std.mem.startsWith(u8, line, "dock_icon_size=")) {
            prefs.dock_icon_size = parseDockIconSize(std.mem.trim(u8, line["dock_icon_size=".len..], " \r\t"));
            continue;
        }

        if (std.mem.startsWith(u8, line, "dock_auto_hide=")) {
            prefs.dock_auto_hide = parseBool(std.mem.trim(u8, line["dock_auto_hide=".len..], " \r\t"));
            continue;
        }

        if (std.mem.startsWith(u8, line, "dock_strong_hover=")) {
            prefs.dock_strong_hover = parseBool(std.mem.trim(u8, line["dock_strong_hover=".len..], " \r\t"));
            continue;
        }

        if (std.mem.startsWith(u8, line, "workspace_wrap=")) {
            prefs.workspace_wrap = parseBool(std.mem.trim(u8, line["workspace_wrap=".len..], " \r\t"));
            continue;
        }

        if (std.mem.startsWith(u8, line, "startup_workspace=")) {
            prefs.startup_workspace = std.fmt.parseUnsigned(usize, std.mem.trim(u8, line["startup_workspace=".len..], " \r\t"), 10) catch 0;
        }
    }

    return prefs;
}

pub fn saveWallpaper(allocator: std.mem.Allocator, wallpaper_path: []const u8) !void {
    var prefs = try load(allocator);
    defer prefs.deinit();

    if (prefs.wallpaper_path) |existing| allocator.free(existing);
    prefs.wallpaper_path = try allocator.dupe(u8, wallpaper_path);
    try prefs.save();
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

fn parseBool(value: []const u8) bool {
    return std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true") or std.ascii.eqlIgnoreCase(value, "yes");
}

fn parseAccent(value: []const u8) AccentPreset {
    if (std.ascii.eqlIgnoreCase(value, "ember")) return .ember;
    if (std.ascii.eqlIgnoreCase(value, "moss")) return .moss;
    return .aurora;
}

fn accentToString(accent: AccentPreset) []const u8 {
    return switch (accent) {
        .aurora => "aurora",
        .ember => "ember",
        .moss => "moss",
    };
}

fn parseDockSize(value: []const u8) DockSizePreset {
    if (std.ascii.eqlIgnoreCase(value, "compact")) return .compact;
    if (std.ascii.eqlIgnoreCase(value, "large")) return .large;
    return .comfortable;
}

fn dockSizeToString(size: DockSizePreset) []const u8 {
    return switch (size) {
        .compact => "compact",
        .comfortable => "comfortable",
        .large => "large",
    };
}

fn parseDockIconSize(value: []const u8) DockIconSizePreset {
    if (std.ascii.eqlIgnoreCase(value, "small")) return .small;
    if (std.ascii.eqlIgnoreCase(value, "large")) return .large;
    return .medium;
}

fn dockIconSizeToString(size: DockIconSizePreset) []const u8 {
    return switch (size) {
        .small => "small",
        .medium => "medium",
        .large => "large",
    };
}
