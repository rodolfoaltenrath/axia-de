const default_workspace_count: usize = 4;

pub const Page = enum {
    wallpapers,
    appearance,
    panel,
    dock,
    displays,
    workspaces,
    network,
    bluetooth,
    printers,
    about,
};

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

pub const PreferencesState = struct {
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
};

pub const dock_size_options = [_]struct {
    preset: DockSizePreset,
    label: []const u8,
}{
    .{ .preset = .compact, .label = "Compacta" },
    .{ .preset = .comfortable, .label = "Normal" },
    .{ .preset = .large, .label = "Grande" },
};

pub const dock_icon_size_options = [_]struct {
    preset: DockIconSizePreset,
    label: []const u8,
}{
    .{ .preset = .small, .label = "Pequenos" },
    .{ .preset = .medium, .label = "Médios" },
    .{ .preset = .large, .label = "Grandes" },
};

pub const AccentSpec = struct {
    preset: AccentPreset,
    label: []const u8,
    description: []const u8,
    primary: [3]f64,
    secondary: [3]f64,
};

pub const accent_presets = [_]AccentSpec{
    .{
        .preset = .aurora,
        .label = "Aurora",
        .description = "Ciano frio e brilho oceânico.",
        .primary = .{ 0.34, 0.86, 0.98 },
        .secondary = .{ 0.16, 0.48, 0.66 },
    },
    .{
        .preset = .ember,
        .label = "Ember",
        .description = "Âmbar quente com contraste forte.",
        .primary = .{ 0.98, 0.70, 0.30 },
        .secondary = .{ 0.56, 0.24, 0.10 },
    },
    .{
        .preset = .moss,
        .label = "Moss",
        .description = "Verde suave para um desktop mais calmo.",
        .primary = .{ 0.56, 0.90, 0.62 },
        .secondary = .{ 0.18, 0.42, 0.26 },
    },
};

pub fn accentSpec(preset: AccentPreset) AccentSpec {
    return switch (preset) {
        .aurora => accent_presets[0],
        .ember => accent_presets[1],
        .moss => accent_presets[2],
    };
}

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

pub const DisplayInfo = struct {
    name: [48]u8 = [_]u8{0} ** 48,
    name_len: usize = 0,
    width: u32 = 0,
    height: u32 = 0,
    primary: bool = false,

    pub fn nameText(self: *const DisplayInfo) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const AppInfo = struct {
    id: [64]u8 = [_]u8{0} ** 64,
    id_len: usize = 0,
    title: [96]u8 = [_]u8{0} ** 96,
    title_len: usize = 0,
    focused: bool = false,

    pub fn idText(self: *const AppInfo) []const u8 {
        return self.id[0..self.id_len];
    }

    pub fn titleText(self: *const AppInfo) []const u8 {
        return self.title[0..self.title_len];
    }
};

pub const RuntimeState = struct {
    display_count: usize = 0,
    displays: [4]DisplayInfo = [_]DisplayInfo{.{}} ** 4,
    workspace_current: usize = 0,
    workspace_count: usize = default_workspace_count,
    app_count: usize = 0,
    apps: [16]AppInfo = [_]AppInfo{.{}} ** 16,
    socket_name: [64]u8 = [_]u8{0} ** 64,
    socket_name_len: usize = 0,

    pub fn socketNameText(self: *const RuntimeState) []const u8 {
        return self.socket_name[0..self.socket_name_len];
    }
};

pub const Hit = union(enum) {
    none,
    titlebar,
    minimize,
    maximize,
    close,
    nav: Page,
    wallpaper_preset: usize,
    browser_manual,
    accent_preset: AccentPreset,
    reduce_transparency,
    panel_show_seconds,
    panel_show_date,
    dock_size: DockSizePreset,
    dock_icon_size: DockIconSizePreset,
    dock_auto_hide,
    dock_strong_hover,
    workspace_wrap,
    startup_workspace: usize,
    scroll_thumb,
    scroll_track,
};
