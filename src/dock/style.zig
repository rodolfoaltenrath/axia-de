const std = @import("std");
const prefs = @import("axia_prefs");

pub const Style = struct {
    item_size: f64,
    icon_tile_size: f64,
    item_gap: f64,
    padding_x: f64,
    padding_y: f64,
    corner_radius: f64,
    top_margin: f64,
    bottom_margin: f64,
    hidden_peek: f64,
    shadow_alpha: f64,
    shell_fill_alpha: f64,
    shell_highlight_alpha: f64,
    strong_hover: bool,

    pub fn dockHeight(self: Style) f64 {
        return self.item_size + self.padding_y * 2.0;
    }

    pub fn preferredSurfaceHeight(self: Style) u32 {
        return @intFromFloat(@ceil(self.dockHeight() + self.top_margin + self.bottom_margin));
    }

    pub fn hiddenOffset(self: Style) f64 {
        return self.dockHeight() + self.bottom_margin - self.hidden_peek;
    }
};

pub const Config = struct {
    style: Style,
    auto_hide: bool,
};

pub fn configFromPreferences(stored: prefs.Preferences) Config {
    return .{
        .style = styleFromPreferences(stored),
        .auto_hide = stored.dock_auto_hide,
    };
}

pub fn defaultConfig() Config {
    return .{
        .style = .{
            .item_size = 40,
            .icon_tile_size = 30,
            .item_gap = 6,
            .padding_x = 14,
            .padding_y = 6,
            .corner_radius = 18,
            .top_margin = 0,
            .bottom_margin = 2,
            .hidden_peek = 10,
            .shadow_alpha = 0.12,
            .shell_fill_alpha = 0.24,
            .shell_highlight_alpha = 0.028,
            .strong_hover = false,
        },
        .auto_hide = false,
    };
}

pub fn eql(a: Config, b: Config) bool {
    return a.auto_hide == b.auto_hide and std.meta.eql(a.style, b.style);
}

fn styleFromPreferences(stored: prefs.Preferences) Style {
    var style = switch (stored.dock_size) {
        .compact => Style{
            .item_size = 36,
            .icon_tile_size = 24,
            .item_gap = 5,
            .padding_x = 12,
            .padding_y = 5,
            .corner_radius = 16,
            .top_margin = 0,
            .bottom_margin = 2,
            .hidden_peek = 9,
            .shadow_alpha = 0.10,
            .shell_fill_alpha = 0.23,
            .shell_highlight_alpha = 0.024,
            .strong_hover = stored.dock_strong_hover,
        },
        .comfortable => Style{
            .item_size = 40,
            .icon_tile_size = 30,
            .item_gap = 6,
            .padding_x = 14,
            .padding_y = 6,
            .corner_radius = 18,
            .top_margin = 0,
            .bottom_margin = 2,
            .hidden_peek = 10,
            .shadow_alpha = 0.12,
            .shell_fill_alpha = 0.24,
            .shell_highlight_alpha = 0.028,
            .strong_hover = stored.dock_strong_hover,
        },
        .large => Style{
            .item_size = 46,
            .icon_tile_size = 34,
            .item_gap = 8,
            .padding_x = 16,
            .padding_y = 7,
            .corner_radius = 20,
            .top_margin = 0,
            .bottom_margin = 2,
            .hidden_peek = 11,
            .shadow_alpha = 0.14,
            .shell_fill_alpha = 0.25,
            .shell_highlight_alpha = 0.032,
            .strong_hover = stored.dock_strong_hover,
        },
    };

    style.icon_tile_size = switch (stored.dock_icon_size) {
        .small => style.icon_tile_size - 4,
        .medium => style.icon_tile_size,
        .large => style.icon_tile_size + 4,
    };
    return style;
}
