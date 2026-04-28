const std = @import("std");
const assets = @import("axia_assets");
const settings_model = @import("settings_model");

test "development asset paths resolve" {
    const allocator = std.testing.allocator;

    const wallpaper = try assets.resolvePath(allocator, "assets/wallpapers/axia-aurora.png");
    defer allocator.free(wallpaper);
    try std.testing.expect(wallpaper.len > 0);

    const files_icon = try assets.resolvePath(allocator, "assets/icons/files/home.png");
    defer allocator.free(files_icon);
    try std.testing.expect(files_icon.len > 0);
}

test "pre-alpha packaging metadata exists" {
    const files = [_][]const u8{
        "packaging/bin/axia-session",
        "packaging/wayland-sessions/axia-de.desktop",
        "packaging/applications/axia-files.desktop",
        "packaging/applications/axia-settings.desktop",
        "docs/smoke-test.md",
        "docs/known-issues.md",
        "scripts/prealpha-check.sh",
        "scripts/dev-install.sh",
        "scripts/dev-session.sh",
        "scripts/dev-restart.sh",
    };

    for (files) |path| {
        try std.fs.cwd().access(path, .{});
    }
}

test "pre-alpha scripts and desktop entries are wired" {
    const session_stat = try std.fs.cwd().statFile("packaging/bin/axia-session");
    try std.testing.expect(session_stat.mode & 0o111 != 0);

    const check_stat = try std.fs.cwd().statFile("scripts/prealpha-check.sh");
    try std.testing.expect(check_stat.mode & 0o111 != 0);
    const dev_install_stat = try std.fs.cwd().statFile("scripts/dev-install.sh");
    try std.testing.expect(dev_install_stat.mode & 0o111 != 0);
    const dev_session_stat = try std.fs.cwd().statFile("scripts/dev-session.sh");
    try std.testing.expect(dev_session_stat.mode & 0o111 != 0);
    const dev_restart_stat = try std.fs.cwd().statFile("scripts/dev-restart.sh");
    try std.testing.expect(dev_restart_stat.mode & 0o111 != 0);

    try expectFileContains("packaging/bin/axia-session", "exec \"$bin_dir/axia-de\"");
    try expectFileContains("packaging/bin/axia-session", "AXIA_BIN_DIR");
    try expectFileContains("packaging/bin/axia-session", "AXIA_ASSET_DIR");
    try expectFileContains("packaging/wayland-sessions/axia-de.desktop", "Exec=axia-session");
    try expectFileContains("packaging/wayland-sessions/axia-de.desktop", "TryExec=axia-de");
    try expectFileContains("packaging/applications/axia-files.desktop", "Exec=axia-files");
    try expectFileContains("packaging/applications/axia-settings.desktop", "Exec=axia-settings");
    try expectFileContains("docs/smoke-test.md", "scripts/prealpha-check.sh");
    try expectFileContains("docs/known-issues.md", "pre-alpha");
    try expectFileContains("README.md", "scripts/dev-session.sh");
    try expectFileContains("README.md", "scripts/dev-restart.sh");
}

test "installed wallpaper paths still match presets" {
    try std.testing.expect(settings_model.wallpaperPathMatches(
        "assets/wallpapers/axia-aurora.png",
        "assets/wallpapers/axia-aurora.png",
    ));
    try std.testing.expect(settings_model.wallpaperPathMatches(
        "/usr/share/axia-de/assets/wallpapers/axia-aurora.png",
        "assets/wallpapers/axia-aurora.png",
    ));
    try std.testing.expect(!settings_model.wallpaperPathMatches(
        "/usr/share/axia-de/assets/wallpapers/axia-duna.png",
        "assets/wallpapers/axia-aurora.png",
    ));
}

fn expectFileContains(path: []const u8, needle: []const u8) !void {
    const contents = try std.fs.cwd().readFileAlloc(std.testing.allocator, path, 64 * 1024);
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, needle) != null);
}
