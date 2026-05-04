pub const GlassKind = enum {
    top_bar,
    dock,
    shell_overlay,
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
    backdrop_overscan_x_px: i32,
    backdrop_overscan_top_px: i32,
    backdrop_overscan_bottom_px: i32,
    saturation_boost: f32,
    bottom_tone_alpha: f32,
    tint_rgba: [4]f32,
    border_rgba: [4]f32,
    highlight_rgba: [4]f32,
    noise_opacity: f32,
};

pub fn styleFor(kind: GlassKind, quality: GlassQuality) GlassStyle {
    return switch (kind) {
        .top_bar => topBarStyle(quality),
        .dock => dockStyle(quality),
        .shell_overlay => shellOverlayStyle(quality),
    };
}

fn topBarStyle(quality: GlassQuality) GlassStyle {
    return switch (quality) {
        .low => .{
            .downsample_factor = 4,
            .blur_radius = 22,
            .corner_radius = 0,
            .backdrop_overscan_x_px = 0,
            .backdrop_overscan_top_px = 0,
            .backdrop_overscan_bottom_px = 0,
            .saturation_boost = 1.10,
            .bottom_tone_alpha = 0.0,
            .tint_rgba = .{ 0.93, 0.96, 1.0, 0.050 },
            .border_rgba = .{ 0.98, 0.992, 1.0, 0.088 },
            .highlight_rgba = .{ 1.0, 1.0, 1.0, 0.0 },
            .noise_opacity = 0.022,
        },
        .balanced => .{
            .downsample_factor = 2,
            .blur_radius = 30,
            .corner_radius = 0,
            .backdrop_overscan_x_px = 0,
            .backdrop_overscan_top_px = 0,
            .backdrop_overscan_bottom_px = 0,
            .saturation_boost = 1.16,
            .bottom_tone_alpha = 0.0,
            .tint_rgba = .{ 0.94, 0.97, 1.0, 0.056 },
            .border_rgba = .{ 0.985, 0.995, 1.0, 0.100 },
            .highlight_rgba = .{ 1.0, 1.0, 1.0, 0.0 },
            .noise_opacity = 0.026,
        },
        .high => .{
            .downsample_factor = 2,
            .blur_radius = 36,
            .corner_radius = 0,
            .backdrop_overscan_x_px = 0,
            .backdrop_overscan_top_px = 0,
            .backdrop_overscan_bottom_px = 0,
            .saturation_boost = 1.22,
            .bottom_tone_alpha = 0.0,
            .tint_rgba = .{ 0.95, 0.975, 1.0, 0.062 },
            .border_rgba = .{ 0.99, 0.997, 1.0, 0.112 },
            .highlight_rgba = .{ 1.0, 1.0, 1.0, 0.0 },
            .noise_opacity = 0.028,
        },
    };
}

fn dockStyle(quality: GlassQuality) GlassStyle {
    return switch (quality) {
        .low => .{
            .downsample_factor = 4,
            .blur_radius = 22,
            .corner_radius = 17,
            .backdrop_overscan_x_px = 24,
            .backdrop_overscan_top_px = 110,
            .backdrop_overscan_bottom_px = 42,
            .saturation_boost = 1.10,
            .bottom_tone_alpha = 0.0,
            .tint_rgba = .{ 0.93, 0.96, 1.0, 0.050 },
            .border_rgba = .{ 0.98, 0.992, 1.0, 0.088 },
            .highlight_rgba = .{ 1.0, 1.0, 1.0, 0.0 },
            .noise_opacity = 0.022,
        },
        .balanced => .{
            .downsample_factor = 2,
            .blur_radius = 30,
            .corner_radius = 17,
            .backdrop_overscan_x_px = 40,
            .backdrop_overscan_top_px = 160,
            .backdrop_overscan_bottom_px = 72,
            .saturation_boost = 1.16,
            .bottom_tone_alpha = 0.0,
            .tint_rgba = .{ 0.94, 0.97, 1.0, 0.056 },
            .border_rgba = .{ 0.985, 0.995, 1.0, 0.100 },
            .highlight_rgba = .{ 1.0, 1.0, 1.0, 0.0 },
            .noise_opacity = 0.026,
        },
        .high => .{
            .downsample_factor = 2,
            .blur_radius = 36,
            .corner_radius = 17,
            .backdrop_overscan_x_px = 48,
            .backdrop_overscan_top_px = 220,
            .backdrop_overscan_bottom_px = 104,
            .saturation_boost = 1.22,
            .bottom_tone_alpha = 0.0,
            .tint_rgba = .{ 0.95, 0.975, 1.0, 0.062 },
            .border_rgba = .{ 0.99, 0.997, 1.0, 0.112 },
            .highlight_rgba = .{ 1.0, 1.0, 1.0, 0.0 },
            .noise_opacity = 0.028,
        },
    };
}

fn shellOverlayStyle(quality: GlassQuality) GlassStyle {
    return switch (quality) {
        .low => .{
            .downsample_factor = 4,
            .blur_radius = 18,
            .corner_radius = 20,
            .backdrop_overscan_x_px = 18,
            .backdrop_overscan_top_px = 18,
            .backdrop_overscan_bottom_px = 18,
            .saturation_boost = 1.04,
            .bottom_tone_alpha = 0.014,
            .tint_rgba = .{ 0.10, 0.14, 0.20, 0.38 },
            .border_rgba = .{ 0.96, 0.985, 1.0, 0.10 },
            .highlight_rgba = .{ 1.0, 1.0, 1.0, 0.08 },
            .noise_opacity = 0.018,
        },
        .balanced => .{
            .downsample_factor = 2,
            .blur_radius = 24,
            .corner_radius = 22,
            .backdrop_overscan_x_px = 28,
            .backdrop_overscan_top_px = 26,
            .backdrop_overscan_bottom_px = 26,
            .saturation_boost = 1.06,
            .bottom_tone_alpha = 0.012,
            .tint_rgba = .{ 0.10, 0.15, 0.22, 0.33 },
            .border_rgba = .{ 0.97, 0.99, 1.0, 0.115 },
            .highlight_rgba = .{ 1.0, 1.0, 1.0, 0.09 },
            .noise_opacity = 0.022,
        },
        .high => .{
            .downsample_factor = 2,
            .blur_radius = 30,
            .corner_radius = 24,
            .backdrop_overscan_x_px = 36,
            .backdrop_overscan_top_px = 32,
            .backdrop_overscan_bottom_px = 32,
            .saturation_boost = 1.08,
            .bottom_tone_alpha = 0.010,
            .tint_rgba = .{ 0.11, 0.16, 0.24, 0.29 },
            .border_rgba = .{ 0.975, 0.992, 1.0, 0.13 },
            .highlight_rgba = .{ 1.0, 1.0, 1.0, 0.10 },
            .noise_opacity = 0.024,
        },
    };
}
