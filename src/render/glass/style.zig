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
            .tint_rgba = .{ 0.09, 0.10, 0.12, 0.64 },
            .border_rgba = .{ 1.0, 1.0, 1.0, 0.12 },
            .highlight_rgba = .{ 1.0, 1.0, 1.0, 0.12 },
            .noise_opacity = 0.02,
        },
        .balanced => .{
            .downsample_factor = 4,
            .blur_radius = 14,
            .corner_radius = 0,
            .tint_rgba = .{ 0.09, 0.10, 0.12, 0.58 },
            .border_rgba = .{ 1.0, 1.0, 1.0, 0.13 },
            .highlight_rgba = .{ 1.0, 1.0, 1.0, 0.14 },
            .noise_opacity = 0.03,
        },
        .high => .{
            .downsample_factor = 2,
            .blur_radius = 18,
            .corner_radius = 0,
            .tint_rgba = .{ 0.09, 0.10, 0.12, 0.54 },
            .border_rgba = .{ 1.0, 1.0, 1.0, 0.14 },
            .highlight_rgba = .{ 1.0, 1.0, 1.0, 0.15 },
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
            .tint_rgba = .{ 0.10, 0.10, 0.12, 0.66 },
            .border_rgba = .{ 1.0, 1.0, 1.0, 0.14 },
            .highlight_rgba = .{ 1.0, 1.0, 1.0, 0.12 },
            .noise_opacity = 0.025,
        },
        .balanced => .{
            .downsample_factor = 4,
            .blur_radius = 16,
            .corner_radius = 18,
            .tint_rgba = .{ 0.10, 0.10, 0.12, 0.60 },
            .border_rgba = .{ 1.0, 1.0, 1.0, 0.15 },
            .highlight_rgba = .{ 1.0, 1.0, 1.0, 0.13 },
            .noise_opacity = 0.03,
        },
        .high => .{
            .downsample_factor = 2,
            .blur_radius = 20,
            .corner_radius = 18,
            .tint_rgba = .{ 0.10, 0.10, 0.12, 0.56 },
            .border_rgba = .{ 1.0, 1.0, 1.0, 0.16 },
            .highlight_rgba = .{ 1.0, 1.0, 1.0, 0.14 },
            .noise_opacity = 0.035,
        },
    };
}
