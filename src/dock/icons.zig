const std = @import("std");
const c = @import("wl.zig").c;
const runtime_catalog = @import("runtime_catalog");

const icon_sizes = [_][]const u8{ "256x256", "128x128", "96x96", "64x64", "48x48", "32x32", "24x24", "22x22", "16x16" };
const icon_roots = [_][]const u8{ ".local/share/icons", "/usr/local/share/icons", "/usr/share/icons" };
const icon_themes = [_][]const u8{ "hicolor", "AdwaitaLegacy", "Adwaita", "Pop", "Cosmic", "breeze", "breeze-dark" };
const icon_groups = [_][]const u8{ "apps", "places", "legacy", "categories", "devices", "mimetypes" };
const pixmap_roots = [_][]const u8{ ".local/share/pixmaps", "/usr/local/share/pixmaps", "/usr/share/pixmaps" };

pub const IconCache = struct {
    allocator: std.mem.Allocator,
    surfaces: std.ArrayListUnmanaged(?*c.cairo_surface_t) = .empty,

    pub fn init(allocator: std.mem.Allocator, entries: []const runtime_catalog.AppEntry) !IconCache {
        var cache = IconCache{ .allocator = allocator };
        errdefer cache.deinit();

        try cache.surfaces.ensureTotalCapacity(allocator, entries.len);
        for (entries) |entry| {
            cache.surfaces.appendAssumeCapacity(try loadSurfaceForEntry(allocator, entry));
        }

        return cache;
    }

    pub fn deinit(self: *IconCache) void {
        for (self.surfaces.items) |surface| {
            if (surface) |loaded| c.cairo_surface_destroy(loaded);
        }
        self.surfaces.deinit(self.allocator);
    }

    pub fn surfaceFor(self: *const IconCache, index: usize) ?*c.cairo_surface_t {
        if (index >= self.surfaces.items.len) return null;
        return self.surfaces.items[index];
    }
};

fn loadSurfaceForEntry(allocator: std.mem.Allocator, entry: runtime_catalog.AppEntry) !?*c.cairo_surface_t {
    var storage: [6][]const u8 = undefined;
    var candidate_count: usize = 0;

    if (entry.icon.len > 0) {
        storage[candidate_count] = entry.icon;
        candidate_count += 1;
    }

    const command_name = executableToken(entry.command);
    if (command_name.len > 0 and !containsIgnoreCaseInArray(storage[0..candidate_count], command_name)) {
        storage[candidate_count] = command_name;
        candidate_count += 1;
    }

    const aliases = iconAliases(entry);
    for (aliases) |alias| {
        if (alias.len == 0 or containsIgnoreCaseInArray(storage[0..candidate_count], alias) or candidate_count >= storage.len) continue;
        storage[candidate_count] = alias;
        candidate_count += 1;
    }

    for (storage[0..candidate_count]) |candidate| {
        if (try loadNamedOrAbsoluteSurface(allocator, candidate)) |surface| return surface;
    }

    return null;
}

fn loadNamedOrAbsoluteSurface(allocator: std.mem.Allocator, candidate: []const u8) !?*c.cairo_surface_t {
    if (candidate.len == 0) return null;

    if (std.fs.path.isAbsolute(candidate)) {
        if (!std.mem.endsWith(u8, candidate, ".png")) return null;
        if (!fileExistsAbsolute(candidate)) return null;
        return loadSurface(candidate);
    }

    if (try resolveThemedIconPath(allocator, candidate)) |path| {
        defer allocator.free(path);
        return loadSurface(path);
    }

    return null;
}

fn resolveThemedIconPath(allocator: std.mem.Allocator, icon_name: []const u8) !?[]u8 {
    const file_name = try std.fmt.allocPrint(allocator, "{s}.png", .{icon_name});
    defer allocator.free(file_name);

    for (pixmap_roots) |root| {
        if (try joinIfExists(allocator, &.{ root, file_name })) |path| return path;
    }

    for (icon_roots) |root| {
        for (icon_themes) |theme| {
            for (icon_sizes) |size| {
                for (icon_groups) |group| {
                    if (try joinIfExists(allocator, &.{ root, theme, size, group, file_name })) |path| return path;
                }
            }
        }
    }

    return null;
}

fn joinIfExists(allocator: std.mem.Allocator, parts: []const []const u8) !?[]u8 {
    const absolute = try resolveFirstPathPart(allocator, parts[0]);
    defer allocator.free(absolute);

    const joined = try std.fs.path.join(allocator, parts[1..]);
    defer allocator.free(joined);

    const path = try std.fs.path.join(allocator, &.{ absolute, joined });
    errdefer allocator.free(path);

    if (!fileExistsAbsolute(path)) {
        allocator.free(path);
        return null;
    }

    return path;
}

fn resolveFirstPathPart(allocator: std.mem.Allocator, part: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(part)) return allocator.dupe(u8, part);

    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, part });
}

fn fileExistsAbsolute(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn loadSurface(path: []const u8) !*c.cairo_surface_t {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const c_path = toCString(&path_buf, path);
    const maybe_surface = c.cairo_image_surface_create_from_png(c_path.ptr);
    const surface = maybe_surface orelse return error.IconLoadFailed;
    errdefer c.cairo_surface_destroy(surface);

    if (c.cairo_surface_status(surface) != c.CAIRO_STATUS_SUCCESS) {
        return error.IconLoadFailed;
    }
    return surface;
}

fn containsIgnoreCaseInArray(items: []const []const u8, candidate: []const u8) bool {
    for (items) |item| {
        if (std.ascii.eqlIgnoreCase(item, candidate)) return true;
    }
    return false;
}

fn executableToken(command: []const u8) []const u8 {
    var tokens = std.mem.tokenizeAny(u8, command, " \t");
    while (tokens.next()) |token| {
        const trimmed = std.mem.trim(u8, token, "\"'");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, "env")) continue;
        if (trimmed[0] == '-') continue;
        if (std.mem.indexOfScalar(u8, trimmed, '=')) |_| continue;
        return std.fs.path.stem(std.fs.path.basename(trimmed));
    }
    return "";
}

fn iconAliases(entry: runtime_catalog.AppEntry) []const []const u8 {
    if (std.ascii.eqlIgnoreCase(entry.label, "Terminal")) {
        return &.{ "ghostty", "utilities-terminal" };
    }
    if (std.ascii.eqlIgnoreCase(entry.label, "Firefox")) {
        return &.{ "firefox", "web-browser" };
    }
    if (std.ascii.eqlIgnoreCase(entry.label, "Arquivos")) {
        return &.{ "folder", "folder-open" };
    }
    if (std.ascii.eqlIgnoreCase(entry.label, "VS Code")) {
        return &.{ "visual-studio-code", "code" };
    }
    if (std.ascii.eqlIgnoreCase(entry.label, "Configurações")) {
        return &.{ "preferences-system", "preferences-desktop" };
    }
    if (std.ascii.eqlIgnoreCase(entry.label, "Rede")) {
        return &.{ "preferences-system-network", "network-workgroup" };
    }
    if (std.ascii.eqlIgnoreCase(entry.label, "Bluetooth")) {
        return &.{ "bluetooth", "preferences-system-bluetooth" };
    }
    if (std.ascii.eqlIgnoreCase(entry.label, "Impressoras")) {
        return &.{ "printer", "printer-network" };
    }
    return &.{};
}

fn toCString(buffer: []u8, text: []const u8) [:0]u8 {
    const len = @min(buffer.len - 1, text.len);
    @memcpy(buffer[0..len], text[0..len]);
    buffer[len] = 0;
    return buffer[0..len :0];
}
