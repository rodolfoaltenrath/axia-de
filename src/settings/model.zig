pub const Page = enum {
    wallpapers,
    appearance,
    panel,
    displays,
    workspaces,
    about,
};

pub const WallpaperPreset = struct {
    label: []const u8,
    description: []const u8,
    path: []const u8,
    colors: [3][4]f64,
};

pub const wallpaper_presets = [_]WallpaperPreset{
    .{
        .label = "Aurora",
        .description = "Azul profundo com brilho ciano.",
        .path = "assets/wallpapers/axia-aurora.png",
        .colors = .{
            .{ 0.04, 0.08, 0.14, 1.0 },
            .{ 0.18, 0.40, 0.58, 1.0 },
            .{ 0.48, 0.84, 0.96, 1.0 },
        },
    },
    .{
        .label = "Duna",
        .description = "Tons quentes com contraste noturno.",
        .path = "assets/wallpapers/axia-duna.png",
        .colors = .{
            .{ 0.10, 0.07, 0.08, 1.0 },
            .{ 0.36, 0.22, 0.16, 1.0 },
            .{ 0.89, 0.61, 0.34, 1.0 },
        },
    },
    .{
        .label = "Glaciar",
        .description = "Camadas frias e brilho leve.",
        .path = "assets/wallpapers/axia-glaciar.png",
        .colors = .{
            .{ 0.03, 0.08, 0.12, 1.0 },
            .{ 0.18, 0.30, 0.38, 1.0 },
            .{ 0.72, 0.89, 0.96, 1.0 },
        },
    },
};
