pub const AppEntry = struct {
    label: []const u8,
    command: []const u8,
    monogram: []const u8,
    accent: [3]f64,
};

pub const entries = [_]AppEntry{
    .{
        .label = "Terminal",
        .command = "command -v cosmic-terminal >/dev/null 2>&1 && exec cosmic-terminal || exec alacritty",
        .monogram = "T",
        .accent = .{ 0.23, 0.78, 0.72 },
    },
    .{
        .label = "Firefox",
        .command = "firefox",
        .monogram = "F",
        .accent = .{ 0.95, 0.48, 0.20 },
    },
    .{
        .label = "Arquivos",
        .command = "exec \"$AXIA_BIN_DIR/axia-files\"",
        .monogram = "A",
        .accent = .{ 0.29, 0.66, 0.94 },
    },
    .{
        .label = "VS Code",
        .command = "code",
        .monogram = "VS",
        .accent = .{ 0.20, 0.55, 0.96 },
    },
    .{
        .label = "Steam",
        .command = "steam",
        .monogram = "S",
        .accent = .{ 0.35, 0.47, 0.66 },
    },
};
