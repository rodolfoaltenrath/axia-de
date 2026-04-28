const std = @import("std");

pub const env_var = "AXIA_ASSET_DIR";
pub const install_asset_dir = "share/axia-de/assets";
pub const dev_asset_dir = "assets";

pub fn resolvePath(allocator: std.mem.Allocator, asset_path: []const u8) ![]u8 {
    if (asset_path.len == 0) return error.AssetPathEmpty;

    if (std.fs.path.isAbsolute(asset_path)) {
        if (absoluteExists(asset_path)) return try allocator.dupe(u8, asset_path);
        return error.AssetNotFound;
    }

    const relative = stripDevPrefix(asset_path);

    if (try resolveFromEnv(allocator, relative)) |path| return path;
    if (try resolveFromInstallPrefix(allocator, relative)) |path| return path;
    if (try resolveFromCwd(allocator, asset_path)) |path| return path;
    if (!std.mem.eql(u8, relative, asset_path)) {
        if (try resolveFromCwd(allocator, relative)) |path| return path;
    }

    return error.AssetNotFound;
}

fn stripDevPrefix(path: []const u8) []const u8 {
    const prefix = dev_asset_dir ++ "/";
    if (std.mem.startsWith(u8, path, prefix)) return path[prefix.len..];
    return path;
}

fn resolveFromEnv(allocator: std.mem.Allocator, relative: []const u8) !?[]u8 {
    const asset_dir = std.process.getEnvVarOwned(allocator, env_var) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    };
    defer allocator.free(asset_dir);

    if (asset_dir.len == 0) return null;
    const path = try std.fs.path.join(allocator, &.{ asset_dir, relative });
    errdefer allocator.free(path);
    if (absoluteOrRelativeExists(path)) return path;
    allocator.free(path);
    return null;
}

fn resolveFromInstallPrefix(allocator: std.mem.Allocator, relative: []const u8) !?[]u8 {
    const exe_dir = std.fs.selfExeDirPathAlloc(allocator) catch return null;
    defer allocator.free(exe_dir);

    const path = try std.fs.path.join(allocator, &.{ exe_dir, "..", install_asset_dir, relative });
    errdefer allocator.free(path);
    if (absoluteOrRelativeExists(path)) return path;
    allocator.free(path);
    return null;
}

fn resolveFromCwd(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    if (!relativeExists(path)) return null;
    return try allocator.dupe(u8, path);
}

fn absoluteOrRelativeExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) return absoluteExists(path);
    return relativeExists(path);
}

fn absoluteExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn relativeExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}
