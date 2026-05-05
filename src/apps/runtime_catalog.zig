const std = @import("std");
const static_catalog = @import("apps_catalog");

pub const AppEntry = static_catalog.AppEntry;

const default_browser_id = "default-browser";

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(AppEntry) = .empty,
    owned_strings: std.ArrayListUnmanaged([]u8) = .empty,
    default_browser_desktop_id: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator) Catalog {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Catalog) void {
        for (self.owned_strings.items) |text| self.allocator.free(text);
        self.owned_strings.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

    pub fn loadDefault(self: *Catalog) !void {
        try self.appendStaticFallbacks();
        try self.loadDesktopDirectories();
        try self.applyDefaultBrowserMetadata();
    }

    pub fn favoriteEntries(self: *const Catalog, allocator: std.mem.Allocator) !std.ArrayListUnmanaged(AppEntry) {
        var favorites: std.ArrayListUnmanaged(AppEntry) = .empty;
        errdefer favorites.deinit(allocator);

        for (self.entries.items) |entry| {
            if (!entry.favorite or !entry.enabled) continue;
            try favorites.append(allocator, entry);
        }
        return favorites;
    }

    pub fn findById(self: *const Catalog, id: []const u8) ?AppEntry {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.id, id)) return entry;
        }
        return null;
    }

    pub fn findByRuntimeApp(self: *const Catalog, app_id: []const u8, title: []const u8) ?AppEntry {
        if (self.isDefaultBrowserRuntime(app_id)) {
            if (self.findById(default_browser_id)) |entry| return entry;
        }

        if (self.findById(app_id)) |entry| return entry;

        if (std.mem.endsWith(u8, app_id, ".desktop")) {
            if (self.findById(app_id[0 .. app_id.len - ".desktop".len])) |entry| return entry;
        }

        for (self.entries.items) |entry| {
            if (std.ascii.eqlIgnoreCase(execBasename(entry.command), app_id)) return entry;
            if (title.len > 0 and (containsIgnoreCase(title, entry.label) or containsIgnoreCase(entry.label, title))) {
                return entry;
            }
        }

        return null;
    }

    fn findByIdMutable(self: *Catalog, id: []const u8) ?*AppEntry {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.id, id)) return entry;
        }
        return null;
    }

    fn appendStaticFallbacks(self: *Catalog) !void {
        for (static_catalog.entries) |entry| {
            try self.entries.append(self.allocator, entry);
        }
    }

    fn applyDefaultBrowserMetadata(self: *Catalog) !void {
        const default_desktop_id = try self.queryDefaultBrowserDesktopId() orelse return;
        defer self.allocator.free(default_desktop_id);

        const browser_entry = self.findById(default_desktop_id) orelse return;
        const default_entry = self.findByIdMutable(default_browser_id) orelse return;

        self.default_browser_desktop_id = try self.ownText(default_desktop_id);
        default_entry.command = try self.defaultBrowserLaunchCommand(browser_entry.command);
        default_entry.icon = browser_entry.icon;
        default_entry.accent = browser_entry.accent;

        const subtitle = try std.fmt.allocPrint(
            self.allocator,
            "Navegador padrão: {s}",
            .{browser_entry.label},
        );
        errdefer self.allocator.free(subtitle);
        try self.owned_strings.append(self.allocator, subtitle);
        default_entry.subtitle = subtitle;

        const keywords = try std.fmt.allocPrint(
            self.allocator,
            "browser navegador internet web default padrão {s} {s}",
            .{ browser_entry.label, default_desktop_id },
        );
        errdefer self.allocator.free(keywords);
        try self.owned_strings.append(self.allocator, keywords);
        default_entry.keywords = keywords;
    }

    fn queryDefaultBrowserDesktopId(self: *Catalog) !?[]u8 {
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "xdg-settings", "get", "default-web-browser" },
            .max_output_bytes = 4 * 1024,
        }) catch return null;
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| if (code != 0) return null,
            else => return null,
        }

        const trimmed = std.mem.trim(u8, result.stdout, " \r\n\t");
        if (trimmed.len == 0) return null;
        return try self.allocator.dupe(u8, normalizeDesktopId(trimmed));
    }

    fn defaultBrowserLaunchCommand(self: *Catalog, command: []const u8) ![]const u8 {
        const browser_exec = executableToken(command);
        if (browser_exec.len == 0) return self.ownText(command);

        const base = std.fs.path.basename(browser_exec);
        if (isChromiumFamilyBrowser(base)) {
            return self.ownFormatted(
                "{s} --user-data-dir=\"${{XDG_RUNTIME_DIR:-/tmp}}/axia-de-{s}\" --password-store=basic --no-first-run --new-window about:blank",
                .{ browser_exec, profileNameForBrowser(base) },
            );
        }

        if (std.ascii.eqlIgnoreCase(base, "firefox")) {
            return self.ownFormatted(
                "{s} --new-instance --profile \"${{XDG_RUNTIME_DIR:-/tmp}}/axia-de-firefox\" about:blank",
                .{browser_exec},
            );
        }

        return self.ownText(command);
    }

    fn isDefaultBrowserRuntime(self: *const Catalog, app_id: []const u8) bool {
        if (self.default_browser_desktop_id.len == 0 or app_id.len == 0) return false;

        const normalized_app_id = normalizeDesktopId(app_id);
        if (std.ascii.eqlIgnoreCase(normalized_app_id, self.default_browser_desktop_id)) return true;

        const browser_entry = self.findById(self.default_browser_desktop_id) orelse return false;
        const browser_exec = execBasename(browser_entry.command);
        return browser_exec.len > 0 and std.ascii.eqlIgnoreCase(browser_exec, normalized_app_id);
    }

    fn loadDesktopDirectories(self: *Catalog) !void {
        const dirs = [_][]const u8{
            ".local/share/applications",
            "/usr/local/share/applications",
            "/usr/share/applications",
            "/var/lib/flatpak/exports/share/applications",
        };

        for (dirs) |dir| {
            try self.loadDesktopDirectory(dir);
        }
    }

    fn loadDesktopDirectory(self: *Catalog, path: []const u8) !void {
        const absolute = try resolveApplicationDir(self.allocator, path);
        defer self.allocator.free(absolute);

        var dir = std.fs.openDirAbsolute(absolute, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".desktop")) continue;

            const desktop_path = try std.fs.path.join(self.allocator, &.{ absolute, entry.name });
            defer self.allocator.free(desktop_path);
            try self.loadDesktopFile(desktop_path);
        }
    }

    fn loadDesktopFile(self: *Catalog, path: []const u8) !void {
        var file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close();

        const data = try file.readToEndAlloc(self.allocator, 256 * 1024);
        defer self.allocator.free(data);

        const parsed = parseDesktopEntry(data) orelse return;
        if (!parsed.valid()) return;

        const stripped_exec = stripExecFieldCodes(self.allocator, parsed.exec orelse return) catch return;
        defer self.allocator.free(stripped_exec);
        const command = std.mem.trim(u8, stripped_exec, " \r\n\t");
        if (command.len == 0) return;
        const desktop_id = desktopIdFromPath(path);

        if (self.findDuplicate(parsed.name.?, command)) |duplicate_index| {
            try self.mergeDesktopMetadata(duplicate_index, parsed, desktop_id);
            return;
        }

        const label = try self.ownText(parsed.name.?);
        const id = try self.ownText(desktop_id);
        const command_owned = try self.ownText(command);
        const subtitle = try self.ownText(parsed.comment orelse "Aplicativo do sistema");
        const keywords = try self.ownSearchKeywords(parsed.keywords orelse "", desktop_id);
        const monogram = try self.ownText(monogramForLabel(parsed.name.?));
        const icon = try self.ownText(parsed.icon orelse "");

        try self.entries.append(self.allocator, .{
            .label = label,
            .id = id,
            .command = command_owned,
            .monogram = monogram,
            .icon = icon,
            .accent = accentForLabel(parsed.name.?),
            .subtitle = subtitle,
            .keywords = keywords,
            .shortcut = "",
            .enabled = true,
            .favorite = false,
        });
    }

    fn ownText(self: *Catalog, text: []const u8) ![]u8 {
        const copy = try self.allocator.dupe(u8, text);
        try self.owned_strings.append(self.allocator, copy);
        return copy;
    }

    fn ownFormatted(self: *Catalog, comptime fmt: []const u8, args: anytype) ![]u8 {
        const text = try std.fmt.allocPrint(self.allocator, fmt, args);
        errdefer self.allocator.free(text);
        try self.owned_strings.append(self.allocator, text);
        return text;
    }

    fn ownSearchKeywords(self: *Catalog, keywords: []const u8, desktop_id: []const u8) ![]u8 {
        if (desktop_id.len == 0) return self.ownText(keywords);
        if (keywords.len == 0) return self.ownText(desktop_id);
        if (containsIgnoreCase(keywords, desktop_id)) return self.ownText(keywords);

        const combined = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ keywords, desktop_id });
        errdefer self.allocator.free(combined);
        try self.owned_strings.append(self.allocator, combined);
        return combined;
    }

    fn mergeDesktopMetadata(self: *Catalog, index: usize, parsed: ParsedDesktopEntry, desktop_id: []const u8) !void {
        var entry = &self.entries.items[index];

        if (entry.id.len == 0 and desktop_id.len > 0) {
            entry.id = try self.ownText(desktop_id);
        }
        if (entry.icon.len == 0 and parsed.icon != null) {
            entry.icon = try self.ownText(parsed.icon.?);
        }
        if ((entry.subtitle.len == 0 or std.mem.eql(u8, entry.subtitle, "Aplicativo do sistema")) and parsed.comment != null) {
            entry.subtitle = try self.ownText(parsed.comment.?);
        }
        if (entry.keywords.len == 0 or (desktop_id.len > 0 and !containsIgnoreCase(entry.keywords, desktop_id))) {
            entry.keywords = try self.ownSearchKeywords(parsed.keywords orelse entry.keywords, desktop_id);
        }
    }

    fn findDuplicate(self: *const Catalog, label: []const u8, command: []const u8) ?usize {
        const command_base = execBasename(command);
        for (self.entries.items, 0..) |entry, index| {
            if (std.ascii.eqlIgnoreCase(entry.label, label)) return index;
            if (command_base.len > 0 and std.ascii.eqlIgnoreCase(execBasename(entry.command), command_base)) return index;
        }
        return null;
    }
};

const ParsedDesktopEntry = struct {
    name: ?[]const u8 = null,
    comment: ?[]const u8 = null,
    keywords: ?[]const u8 = null,
    exec: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    type_name: ?[]const u8 = null,
    hidden: bool = false,
    no_display: bool = false,

    fn valid(self: ParsedDesktopEntry) bool {
        return !self.hidden and !self.no_display and
            self.name != null and self.exec != null and
            self.type_name != null and std.mem.eql(u8, self.type_name.?, "Application");
    }
};

fn parseDesktopEntry(data: []const u8) ?ParsedDesktopEntry {
    var parsed = ParsedDesktopEntry{};
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    var in_section = false;

    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[') {
            if (std.mem.eql(u8, line, "[Desktop Entry]")) {
                in_section = true;
                continue;
            }
            if (in_section) break;
            continue;
        }

        if (!in_section) continue;

        const equals_index = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..equals_index], " \t");
        const value = std.mem.trim(u8, line[equals_index + 1 ..], " \t");

        if (std.mem.eql(u8, key, "Name[pt_BR]")) {
            parsed.name = value;
        } else if (std.mem.eql(u8, key, "Name") and parsed.name == null) {
            parsed.name = value;
        } else if (std.mem.eql(u8, key, "Comment[pt_BR]")) {
            parsed.comment = value;
        } else if (std.mem.eql(u8, key, "Comment") and parsed.comment == null) {
            parsed.comment = value;
        } else if (std.mem.eql(u8, key, "Keywords[pt_BR]")) {
            parsed.keywords = value;
        } else if (std.mem.eql(u8, key, "Keywords") and parsed.keywords == null) {
            parsed.keywords = value;
        } else if (std.mem.eql(u8, key, "Exec")) {
            parsed.exec = value;
        } else if (std.mem.eql(u8, key, "Icon")) {
            parsed.icon = value;
        } else if (std.mem.eql(u8, key, "Type")) {
            parsed.type_name = value;
        } else if (std.mem.eql(u8, key, "NoDisplay")) {
            parsed.no_display = parseBool(value);
        } else if (std.mem.eql(u8, key, "Hidden")) {
            parsed.hidden = parseBool(value);
        }
    }

    return if (in_section) parsed else null;
}

fn parseBool(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "true") or std.mem.eql(u8, value, "1");
}

fn desktopIdFromPath(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    return normalizeDesktopId(base);
}

fn normalizeDesktopId(base: []const u8) []const u8 {
    if (std.mem.endsWith(u8, base, ".desktop")) {
        return base[0 .. base.len - ".desktop".len];
    }
    return base;
}

fn stripExecFieldCodes(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = try std.array_list.Managed(u8).initCapacity(allocator, value.len);
    defer out.deinit();

    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        if (value[i] == '%') {
            if (i + 1 >= value.len) break;
            if (value[i + 1] == '%') {
                try out.append('%');
            }
            i += 1;
            continue;
        }
        try out.append(value[i]);
    }

    return out.toOwnedSlice();
}

fn resolveApplicationDir(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);

    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, path });
}

fn execBasename(command: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, command, " \r\n\t");
    if (trimmed.len == 0) return "";

    const without_exec = if (std.mem.startsWith(u8, trimmed, "exec "))
        std.mem.trimLeft(u8, trimmed[5..], " \t")
    else
        trimmed;

    const first = executableToken(without_exec);
    if (first.len == 0) return "";
    if (std.fs.path.basename(first).len == 0) return first;
    return std.fs.path.basename(first);
}

fn executableToken(command: []const u8) []const u8 {
    var tokens = std.mem.tokenizeAny(u8, command, " \t");
    while (tokens.next()) |token| {
        const trimmed = std.mem.trim(u8, token, "\"'");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, "env")) continue;
        if (trimmed[0] == '-') continue;
        if (std.mem.indexOfScalar(u8, trimmed, '=')) |_| continue;
        return trimmed;
    }
    return "";
}

fn isChromiumFamilyBrowser(executable: []const u8) bool {
    const chromium_names = [_][]const u8{
        "brave",
        "brave-browser",
        "chromium",
        "chromium-browser",
        "google-chrome",
        "google-chrome-stable",
        "microsoft-edge",
        "microsoft-edge-stable",
        "vivaldi",
        "opera",
    };

    for (chromium_names) |name| {
        if (std.ascii.eqlIgnoreCase(executable, name)) return true;
    }
    return false;
}

fn profileNameForBrowser(executable: []const u8) []const u8 {
    if (std.mem.indexOf(u8, executable, "brave") != null) return "brave";
    if (std.mem.indexOf(u8, executable, "chrom") != null) return "chromium";
    if (std.mem.indexOf(u8, executable, "chrome") != null) return "chrome";
    if (std.mem.indexOf(u8, executable, "edge") != null) return "edge";
    if (std.mem.indexOf(u8, executable, "vivaldi") != null) return "vivaldi";
    if (std.mem.indexOf(u8, executable, "opera") != null) return "opera";
    return "browser";
}

fn monogramForLabel(label: []const u8) []const u8 {
    var storage: [2]u8 = .{ '?', 0 };
    var first_index: ?usize = null;
    var second_index: ?usize = null;

    for (label, 0..) |byte, index| {
        if (!std.ascii.isAlphabetic(byte)) continue;
        if (first_index == null) {
            first_index = index;
            continue;
        }

        const prev = if (index > 0) label[index - 1] else ' ';
        if (prev == ' ' or prev == '-' or prev == '_') {
            second_index = index;
            break;
        }
    }

    if (first_index == null) return storage[0..1];
    storage[0] = std.ascii.toUpper(label[first_index.?]);
    if (second_index) |idx| {
        storage[1] = std.ascii.toUpper(label[idx]);
        return storage[0..2];
    }
    return storage[0..1];
}

fn accentForLabel(label: []const u8) [3]f64 {
    var hash = std.hash.Wyhash.init(0);
    hash.update(label);
    const value = hash.final();
    const hue = @as(f64, @floatFromInt(value % 360)) / 360.0;
    return hsvToRgb(hue, 0.58, 0.94);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn hsvToRgb(h: f64, s: f64, v: f64) [3]f64 {
    const scaled = h * 6.0;
    const i: u32 = @intFromFloat(@floor(scaled));
    const f = scaled - @floor(scaled);
    const p = v * (1.0 - s);
    const q = v * (1.0 - f * s);
    const t = v * (1.0 - (1.0 - f) * s);
    return switch (i % 6) {
        0 => .{ v, t, p },
        1 => .{ q, v, p },
        2 => .{ p, v, t },
        3 => .{ p, q, v },
        4 => .{ t, p, v },
        else => .{ v, p, q },
    };
}
