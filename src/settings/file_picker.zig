const std = @import("std");

pub fn pickImagePath(allocator: std.mem.Allocator) !?[]u8 {
    const files_path = try resolveFilesExecutablePath(allocator);
    defer allocator.free(files_path);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ files_path, "pick-wallpaper" },
        .max_output_bytes = 32 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code == 0 and std.mem.trim(u8, result.stdout, " \r\n\t").len == 0) return null;
            if (code != 0) return error.FileChooserFailed;
        },
        else => return error.FileChooserFailed,
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \r\n\t");
    if (trimmed.len == 0) return null;
    if (!isSupportedImage(trimmed)) return error.UnsupportedSelection;
    return @as(?[]u8, try allocator.dupe(u8, trimmed));
}

fn resolveFilesExecutablePath(allocator: std.mem.Allocator) ![]u8 {
    const env_bin_dir = std.process.getEnvVarOwned(allocator, "AXIA_BIN_DIR") catch null;
    if (env_bin_dir) |bin_dir| {
        defer allocator.free(bin_dir);
        return std.fs.path.join(allocator, &.{ bin_dir, "axia-files" });
    }

    const exe_dir = try std.fs.selfExeDirPathAlloc(allocator);
    defer allocator.free(exe_dir);
    return std.fs.path.join(allocator, &.{ exe_dir, "axia-files" });
}

fn isSupportedImage(path: []const u8) bool {
    return endsWithIgnoreCase(path, ".png") or
        endsWithIgnoreCase(path, ".jpg") or
        endsWithIgnoreCase(path, ".jpeg") or
        endsWithIgnoreCase(path, ".webp") or
        endsWithIgnoreCase(path, ".bmp");
}

fn endsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[haystack.len - needle.len ..], needle);
}
