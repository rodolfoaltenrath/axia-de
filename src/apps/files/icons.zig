const std = @import("std");
const c = @import("client_wl").c;
const assets = @import("axia_assets");
const browser = @import("browser.zig");

pub const SidebarIcons = struct {
    allocator: std.mem.Allocator,
    surfaces: [browser.sidebar_items.len]?*c.cairo_surface_t = [_]?*c.cairo_surface_t{null} ** browser.sidebar_items.len,

    pub fn init(allocator: std.mem.Allocator) !SidebarIcons {
        var icons = SidebarIcons{ .allocator = allocator };
        errdefer icons.deinit();

        inline for (browser.sidebar_items, 0..) |item, index| {
            const path = try assets.resolvePath(allocator, assetPathFor(item.target));
            defer allocator.free(path);
            icons.surfaces[index] = try loadSurface(path);
        }

        return icons;
    }

    pub fn deinit(self: *SidebarIcons) void {
        _ = self.allocator;
        for (self.surfaces) |surface| {
            if (surface) |loaded| c.cairo_surface_destroy(loaded);
        }
    }

    pub fn surfaceFor(self: *const SidebarIcons, target: browser.SidebarTarget) ?*c.cairo_surface_t {
        return self.surfaces[@intFromEnum(target)];
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
