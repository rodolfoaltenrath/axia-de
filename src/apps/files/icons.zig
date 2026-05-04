const std = @import("std");
const c = @import("client_wl").c;
const assets = @import("axia_assets");
const browser = @import("browser.zig");

pub const SidebarIcons = struct {
    allocator: std.mem.Allocator,
    surfaces: [browser.sidebar_items.len]?*c.cairo_surface_t = [_]?*c.cairo_surface_t{null} ** browser.sidebar_items.len,
    folder_surface: ?*c.cairo_surface_t = null,
    thumbnails: std.ArrayListUnmanaged(ThumbnailEntry) = .empty,

    pub fn init(allocator: std.mem.Allocator) !SidebarIcons {
        var icons = SidebarIcons{ .allocator = allocator };
        errdefer icons.deinit();

        inline for (browser.sidebar_items, 0..) |item, index| {
            const path = try assets.resolvePath(allocator, assetPathFor(item.target));
            defer allocator.free(path);
            icons.surfaces[index] = try loadSurface(path);
        }
        const folder_path = try assets.resolvePath(allocator, "assets/icons/sistema/folder.svg");
        defer allocator.free(folder_path);
        icons.folder_surface = try loadSurface(folder_path);

        return icons;
    }

    pub fn deinit(self: *SidebarIcons) void {
        _ = self.allocator;
        for (self.surfaces) |surface| {
            if (surface) |loaded| c.cairo_surface_destroy(loaded);
        }
        if (self.folder_surface) |loaded| c.cairo_surface_destroy(loaded);
        for (self.thumbnails.items) |entry| {
            self.allocator.free(entry.path);
            if (entry.surface) |surface| c.cairo_surface_destroy(surface);
        }
        self.thumbnails.deinit(self.allocator);
    }

    pub fn surfaceFor(self: *const SidebarIcons, target: browser.SidebarTarget) ?*c.cairo_surface_t {
        return self.surfaces[@intFromEnum(target)];
    }

    pub fn folderSurface(self: *const SidebarIcons) ?*c.cairo_surface_t {
        return self.folder_surface;
    }

    pub fn ensureVisibleThumbnails(self: *SidebarIcons, snapshot: browser.Snapshot) void {
        var generated_this_frame: usize = 0;
        for (0..snapshot.count) |index| {
            const entry = snapshot.entries[index];
            if (entry.kind != .file) continue;
            if (!self.hasThumbnailRecord(entry.pathText())) {
                if (generated_this_frame >= 6) continue;
                generated_this_frame += 1;
            }
            self.ensureThumbnail(entry.pathText(), entry.modified_unix, entry.file_size_bytes) catch {};
        }
    }

    pub fn thumbnailFor(self: *const SidebarIcons, path: []const u8) ?*c.cairo_surface_t {
        for (self.thumbnails.items) |entry| {
            if (std.mem.eql(u8, entry.path, path)) return entry.surface;
        }
        return null;
    }

    fn hasThumbnailRecord(self: *const SidebarIcons, path: []const u8) bool {
        for (self.thumbnails.items) |entry| {
            if (std.mem.eql(u8, entry.path, path)) return true;
        }
        return false;
    }

    fn ensureThumbnail(self: *SidebarIcons, path: []const u8, modified_unix: i64, file_size_bytes: u64) !void {
        if (!isThumbnailCandidate(path)) return;
        for (self.thumbnails.items) |*entry| {
            if (!std.mem.eql(u8, entry.path, path)) continue;
            if (entry.modified_unix == modified_unix and entry.file_size_bytes == file_size_bytes) return;
            if (entry.surface) |surface| c.cairo_surface_destroy(surface);
            entry.modified_unix = modified_unix;
            entry.file_size_bytes = file_size_bytes;
            entry.surface = try self.buildThumbnailSurface(path, modified_unix, file_size_bytes);
            return;
        }

        const surface = try self.buildThumbnailSurface(path, modified_unix, file_size_bytes);
        try self.thumbnails.append(self.allocator, .{
            .path = try self.allocator.dupe(u8, path),
            .modified_unix = modified_unix,
            .file_size_bytes = file_size_bytes,
            .surface = surface,
        });
    }

    fn buildThumbnailSurface(self: *SidebarIcons, path: []const u8, modified_unix: i64, file_size_bytes: u64) !?*c.cairo_surface_t {
        if (hasExtension(path, ".png")) {
            return loadSurface(path) catch null;
        }

        const thumb_path = try thumbnailPath(self.allocator, path, modified_unix, file_size_bytes);
        defer self.allocator.free(thumb_path);

        if (absoluteExists(thumb_path)) {
            return loadSurface(thumb_path) catch null;
        }
        if (try freedesktopThumbnailPath(self.allocator, path, .normal)) |xdg_thumb| {
            defer self.allocator.free(xdg_thumb);
            if (absoluteExists(xdg_thumb)) return loadSurface(xdg_thumb) catch null;
        }
        if (try freedesktopThumbnailPath(self.allocator, path, .large)) |xdg_thumb| {
            defer self.allocator.free(xdg_thumb);
            if (absoluteExists(xdg_thumb)) return loadSurface(xdg_thumb) catch null;
        }
        return null;
    }

    fn assetPathFor(target: browser.SidebarTarget) []const u8 {
        return switch (target) {
            .home => "assets/icons/files/home.png",
            .documents => "assets/icons/files/documentos.png",
            .downloads => "assets/icons/files/downloads.png",
            .music => "assets/icons/files/musicas.png",
            .pictures => "assets/icons/files/imagens.png",
            .videos => "assets/icons/files/videos.png",
            .trash => "assets/icons/files/lixeira.png",
            .network => "assets/icons/files/redes.png",
        };
    }

    fn loadSurface(path: []const u8) !*c.cairo_surface_t {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const c_path = toCString(&path_buf, path);
        const maybe_surface = c.cairo_image_surface_create_from_png(c_path.ptr);
        const surface = maybe_surface orelse return error.IconLoadFailed;
        if (c.cairo_surface_status(surface) != c.CAIRO_STATUS_SUCCESS) {
            return error.IconLoadFailed;
        }
        return surface;
    }

    fn toCString(buffer: []u8, text: []const u8) [:0]u8 {
        const len = @min(buffer.len - 1, text.len);
        @memcpy(buffer[0..len], text[0..len]);
        buffer[len] = 0;
        return buffer[0..len :0];
    }
};

const ThumbnailEntry = struct {
    path: []u8,
    modified_unix: i64,
    file_size_bytes: u64,
    surface: ?*c.cairo_surface_t,
};

fn isThumbnailCandidate(path: []const u8) bool {
    return hasExtension(path, ".png") or
        hasExtension(path, ".jpg") or
        hasExtension(path, ".jpeg") or
        hasExtension(path, ".webp") or
        hasExtension(path, ".bmp") or
        hasExtension(path, ".gif") or
        hasExtension(path, ".pdf");
}

fn hasExtension(path: []const u8, extension: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(path, extension);
}

fn thumbnailPath(allocator: std.mem.Allocator, path: []const u8, modified_unix: i64, file_size_bytes: u64) ![]u8 {
    const cache_dir = try thumbnailCacheDir(allocator);
    defer allocator.free(cache_dir);
    var hash = std.hash.Wyhash.init(0);
    hash.update(path);
    var meta_buf: [64]u8 = undefined;
    const meta = std.fmt.bufPrint(&meta_buf, ":{d}:{d}", .{ modified_unix, file_size_bytes }) catch "";
    hash.update(meta);
    const value = hash.final();
    const file_name = try std.fmt.allocPrint(allocator, "{x}.png", .{value});
    defer allocator.free(file_name);
    return try std.fs.path.join(allocator, &.{ cache_dir, file_name });
}

const FreedesktopThumbnailSize = enum {
    normal,
    large,
};

fn freedesktopThumbnailPath(allocator: std.mem.Allocator, path: []const u8, size: FreedesktopThumbnailSize) !?[]u8 {
    const uri = try fileUriForPath(allocator, path);
    defer allocator.free(uri);

    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(uri, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);

    const file_name = try std.fmt.allocPrint(allocator, "{s}.png", .{hex[0..]});
    defer allocator.free(file_name);
    const cache_dir = try thumbnailRootDir(allocator);
    defer allocator.free(cache_dir);
    return try std.fs.path.join(allocator, &.{ cache_dir, "thumbnails", thumbnailSizeDir(size), file_name });
}

fn fileUriForPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var uri: std.ArrayListUnmanaged(u8) = .empty;
    errdefer uri.deinit(allocator);
    try uri.appendSlice(allocator, "file://");
    for (path) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '/' or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try uri.append(allocator, byte);
        } else {
            try uri.writer(allocator).print("%{X:0>2}", .{byte});
        }
    }
    return try uri.toOwnedSlice(allocator);
}

fn thumbnailSizeDir(size: FreedesktopThumbnailSize) []const u8 {
    return switch (size) {
        .normal => "normal",
        .large => "large",
    };
}

fn thumbnailRootDir(allocator: std.mem.Allocator) ![]u8 {
    const cache_home = std.process.getEnvVarOwned(allocator, "XDG_CACHE_HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (cache_home) |value| {
        if (value.len > 0) return value;
        allocator.free(value);
    }

    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, ".cache" });
}

fn thumbnailCacheDir(allocator: std.mem.Allocator) ![]u8 {
    const cache_home = std.process.getEnvVarOwned(allocator, "XDG_CACHE_HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (cache_home) |value| {
        defer allocator.free(value);
        if (value.len > 0) return try std.fs.path.join(allocator, &.{ value, "axia-de", "files-thumbnails" });
    }

    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, ".cache", "axia-de", "files-thumbnails" });
}

fn absoluteExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}
