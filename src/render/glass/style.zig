pub const GlassKind = enum {
    top_bar,
    dock,
};

pub const GlassQuality = enum {
    low,
    balanced,
    high,
};

pub const GlassStyle = struct {
    downsample_factor: u8,
    blur_radius: f32,
    corner_radius: f32,
    tint_rgba: [4]f32,
    border_rgba: [4]f32,
    highlight_rgba: [4]f32,
    noise_opacity: f32,
};

pub fn styleFor(kind: GlassKind, quality: GlassQuality) GlassStyle {
    return switch (kind) {
        .top_bar => topBarStyle(quality),
        .dock => dockStyle(quality),
    };
}

fn topBarStyle(quality: GlassQuality) GlassStyle {
    return switch (quality) {
        .low => .{
            .downsample_factor = 8,
            .blur_radius = 10,
            .corner_radius = 0,
            .tint_rgba = .{ 0.28, 0.45, 0.76, 0.30 },
            .border_rgba = .{ 0.78, 0.90, 1.0, 0.22 },
            .highlight_rgba = .{ 0.84, 0.95, 1.0, 0.11 },
            .noise_opacity = 0.02,
        },
        .balanced => .{
            .downsample_factor = 4,
            .blur_radius = 14,
            .corner_radius = 0,
            .tint_rgba = .{ 0.30, 0.48, 0.82, 0.28 },
            .border_rgba = .{ 0.80, 0.92, 1.0, 0.24 },
            .highlight_rgba = .{ 0.86, 0.96, 1.0, 0.12 },
            .noise_opacity = 0.03,
        },
        .high => .{
            .downsample_factor = 2,
            .blur_radius = 18,
            .corner_radius = 0,
            .tint_rgba = .{ 0.32, 0.50, 0.86, 0.26 },
            .border_rgba = .{ 0.82, 0.94, 1.0, 0.26 },
            .highlight_rgba = .{ 0.88, 0.97, 1.0, 0.13 },
            .noise_opacity = 0.035,
        },
    };
}

fn dockStyle(quality: GlassQuality) GlassStyle {
    return switch (quality) {
        .low => .{
            .downsample_factor = 8,
            .blur_radius = 12,
            .corner_radius = 16,
            .tint_rgba = .{ 0.32, 0.50, 0.82, 0.30 },
            .border_rgba = .{ 0.78, 0.90, 1.0, 0.28 },
            .highlight_rgba = .{ 0.82, 0.94, 1.0, 0.13 },
            .noise_opacity = 0.025,
        },
        .balanced => .{
            .downsample_factor = 4,
            .blur_radius = 16,
            .corner_radius = 18,
            .tint_rgba = .{ 0.34, 0.52, 0.86, 0.28 },
            .border_rgba = .{ 0.80, 0.92, 1.0, 0.30 },
            .highlight_rgba = .{ 0.84, 0.95, 1.0, 0.14 },
            .noise_opacity = 0.03,
        },
        .high => .{
            .downsample_factor = 2,
            .blur_radius = 20,
            .corner_radius = 18,
            .tint_rgba = .{ 0.36, 0.54, 0.90, 0.26 },
            .border_rgba = .{ 0.82, 0.94, 1.0, 0.32 },
            .highlight_rgba = .{ 0.86, 0.96, 1.0, 0.15 },
            .noise_opacity = 0.035,
        },
    };
}
