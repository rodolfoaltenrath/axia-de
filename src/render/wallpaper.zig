const std = @import("std");
const c = @import("../wl.zig").c;
const assets = @import("../assets.zig");

const log = std.log.scoped(.axia_wallpaper);

pub const WallpaperAsset = struct {
    allocator: std.mem.Allocator,
    image: *ImageBuffer,
    source_path: []u8,

    pub fn loadDefault(allocator: std.mem.Allocator) !?*WallpaperAsset {
        const path = try resolvePath(allocator);
        if (path == null) return null;
        errdefer allocator.free(path.?);
        return try loadFromOwnedPath(allocator, path.?);
    }

    pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !*WallpaperAsset {
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        return try loadFromOwnedPath(allocator, owned_path);
    }

    pub fn deinit(self: *WallpaperAsset) void {
        c.wlr_buffer_drop(&self.image.base);
        self.allocator.free(self.source_path);
        self.allocator.destroy(self);
    }

    pub fn buffer(self: *WallpaperAsset) *c.struct_wlr_buffer {
        return &self.image.base;
    }

    pub fn pixelData(self: *WallpaperAsset) []u8 {
        return self.image.pixels;
    }

    pub fn stride(self: *WallpaperAsset) usize {
        return self.image.stride;
    }

    pub fn width(self: *WallpaperAsset) u32 {
        return @intCast(self.image.base.width);
    }

    pub fn height(self: *WallpaperAsset) u32 {
        return @intCast(self.image.base.height);
    }

    fn resolvePath(allocator: std.mem.Allocator) !?[]u8 {
        const from_env = std.process.getEnvVarOwned(allocator, "AXIA_WALLPAPER") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        if (from_env) |path| {
            if (path.len == 0) {
                allocator.free(path);
            } else if (resolveImagePath(allocator, path)) |resolved| {
                allocator.free(path);
                return resolved;
            } else |_| {
                log.warn("AXIA_WALLPAPER points to missing file: {s}", .{path});
                allocator.free(path);
            }
        }

        const fallback_paths = [_][]const u8{
            "assets/wallpapers/axia-aurora.png",
            "assets/wallpapers/axia-default.png",
        };

        inline for (fallback_paths) |path| {
            if (resolveImagePath(allocator, path)) |resolved| {
                return resolved;
            } else |_| {}
        }

        log.warn("no wallpaper asset found, using abstract fallback background", .{});
        return null;
    }

    fn resolveImagePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        if (std.fs.path.isAbsolute(path)) {
            std.fs.accessAbsolute(path, .{}) catch return error.FileNotFound;
            return try allocator.dupe(u8, path);
        }

        if (assets.resolvePath(allocator, path)) |resolved| {
            return resolved;
        } else |_| {
            if (std.fs.cwd().access(path, .{})) {
                return try allocator.dupe(u8, path);
            } else |_| {
                return error.FileNotFound;
            }
        }
    }

    fn loadFromOwnedPath(allocator: std.mem.Allocator, owned_path: []u8) !*WallpaperAsset {
        const prepared = try prepareLoadPath(allocator, owned_path);
        defer allocator.free(prepared.load_path);

        const image = try ImageBuffer.loadPng(allocator, prepared.load_path);
        errdefer c.wlr_buffer_drop(&image.base);

        const asset = try allocator.create(WallpaperAsset);
        asset.* = .{
            .allocator = allocator,
            .image = image,
            .source_path = owned_path,
        };

        log.info("loaded wallpaper from {s}", .{asset.source_path});
        return asset;
    }
};

const PreparedPath = struct {
    load_path: []u8,
};

fn prepareLoadPath(allocator: std.mem.Allocator, path: []const u8) !PreparedPath {
    const resolved_path = try WallpaperAsset.resolveImagePath(allocator, path);
    defer allocator.free(resolved_path);

    if (endsWithIgnoreCase(path, ".png")) {
        return .{ .load_path = try allocator.dupe(u8, resolved_path) };
    }

    if (!isConvertibleImage(path)) {
        return error.UnsupportedWallpaperFormat;
    }

    const cache_path = try cacheConvertedPath(allocator);
    errdefer allocator.free(cache_path);

    var child = std.process.Child.init(&.{
        "magick",
        resolved_path,
        "-auto-orient",
        cache_path,
    }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) return error.WallpaperConversionFailed;
        },
        else => return error.WallpaperConversionFailed,
    }

    return .{ .load_path = cache_path };
}

fn cacheConvertedPath(allocator: std.mem.Allocator) ![]u8 {
    const cache_home = try cacheHome(allocator);
    defer allocator.free(cache_home);

    const dir = try std.fs.path.join(allocator, &.{ cache_home, "axia-de" });
    defer allocator.free(dir);
    try std.fs.cwd().makePath(dir);

    return try std.fs.path.join(allocator, &.{ dir, "converted-wallpaper.png" });
}

fn cacheHome(allocator: std.mem.Allocator) ![]u8 {
    const from_env = std.process.getEnvVarOwned(allocator, "XDG_CACHE_HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (from_env) |value| {
        if (value.len > 0) return value;
        allocator.free(value);
    }

    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, ".cache" });
}

fn isConvertibleImage(path: []const u8) bool {
    return endsWithIgnoreCase(path, ".jpg") or
        endsWithIgnoreCase(path, ".jpeg") or
        endsWithIgnoreCase(path, ".webp") or
        endsWithIgnoreCase(path, ".bmp");
}

fn endsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[haystack.len - needle.len ..], needle);
}

const ImageBuffer = struct {
    allocator: std.mem.Allocator,
    base: c.struct_wlr_buffer = undefined,
    pixels: []u8,
    stride: usize,
    format: u32,

    fn loadPng(allocator: std.mem.Allocator, path: []const u8) !*ImageBuffer {
        const z_path = try allocator.dupeZ(u8, path);
        defer allocator.free(z_path);

        const loaded = c.cairo_image_surface_create_from_png(z_path.ptr);
        if (c.cairo_surface_status(loaded) != c.CAIRO_STATUS_SUCCESS) {
            if (loaded != null) c.cairo_surface_destroy(loaded);
            return error.WallpaperLoadFailed;
        }
        defer c.cairo_surface_destroy(loaded);

        const width = c.cairo_image_surface_get_width(loaded);
        const height = c.cairo_image_surface_get_height(loaded);
        if (width <= 0 or height <= 0) return error.WallpaperInvalidDimensions;

        const converted = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, width, height);
        if (c.cairo_surface_status(converted) != c.CAIRO_STATUS_SUCCESS) {
            if (converted != null) c.cairo_surface_destroy(converted);
            return error.WallpaperSurfaceCreateFailed;
        }
        defer c.cairo_surface_destroy(converted);

        const cr = c.cairo_create(converted);
        if (cr == null or c.cairo_status(cr) != c.CAIRO_STATUS_SUCCESS) {
            if (cr != null) c.cairo_destroy(cr);
            return error.WallpaperContextCreateFailed;
        }
        defer c.cairo_destroy(cr);

        _ = c.cairo_set_source_surface(cr, loaded, 0, 0);
        _ = c.cairo_paint(cr);
        c.cairo_surface_flush(converted);

        const stride: usize = @intCast(c.cairo_image_surface_get_stride(converted));
        const size: usize = stride * @as(usize, @intCast(height));
        const src_ptr = c.cairo_image_surface_get_data(converted) orelse return error.WallpaperPixelAccessFailed;

        const pixels = try allocator.alloc(u8, size);
        @memcpy(pixels, src_ptr[0..size]);

        const image = try allocator.create(ImageBuffer);
        image.* = .{
            .allocator = allocator,
            .pixels = pixels,
            .stride = stride,
            .format = c.DRM_FORMAT_ARGB8888,
        };
        c.wlr_buffer_init(&image.base, &image_buffer_impl, width, height);
        return image;
    }

    fn destroy(buffer: [*c]c.struct_wlr_buffer) callconv(.c) void {
        const image: *ImageBuffer = @ptrCast(@alignCast(@as(*allowzero ImageBuffer, @fieldParentPtr("base", buffer))));
        image.allocator.free(image.pixels);
        image.allocator.destroy(image);
    }

    fn beginDataPtrAccess(
        buffer: [*c]c.struct_wlr_buffer,
        _: u32,
        data_out: [*c]?*anyopaque,
        format_out: [*c]u32,
        stride_out: [*c]usize,
    ) callconv(.c) bool {
        const image: *ImageBuffer = @ptrCast(@alignCast(@as(*allowzero ImageBuffer, @fieldParentPtr("base", buffer))));

        if (data_out != null) data_out[0] = image.pixels.ptr;
        if (format_out != null) format_out[0] = image.format;
        if (stride_out != null) stride_out[0] = image.stride;
        return true;
    }

    fn endDataPtrAccess(_: [*c]c.struct_wlr_buffer) callconv(.c) void {}
};

const image_buffer_impl = c.struct_wlr_buffer_impl{
    .destroy = ImageBuffer.destroy,
    .get_dmabuf = null,
    .get_shm = null,
    .begin_data_ptr_access = ImageBuffer.beginDataPtrAccess,
    .end_data_ptr_access = ImageBuffer.endDataPtrAccess,
};
