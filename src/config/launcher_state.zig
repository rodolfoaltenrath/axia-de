const std = @import("std");
const runtime_catalog = @import("runtime_catalog");

const log = std.log.scoped(.axia_launcher_state);
const max_recent_entries: usize = 8;

pub const State = struct {
    allocator: std.mem.Allocator,
    favorite_ids: std.ArrayListUnmanaged([]u8) = .empty,
    recent_ids: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn deinit(self: *State) void {
        for (self.favorite_ids.items) |id| self.allocator.free(id);
        for (self.recent_ids.items) |id| self.allocator.free(id);
        self.favorite_ids.deinit(self.allocator);
        self.recent_ids.deinit(self.allocator);
    }

    pub fn save(self: *const State) !void {
        const dir_path = try stateDirPath(self.allocator);
        defer self.allocator.free(dir_path);
        try std.fs.cwd().makePath(dir_path);

        const file_path = try statePath(self.allocator);
        defer self.allocator.free(file_path);

        var contents = std.array_list.Managed(u8).init(self.allocator);
        defer contents.deinit();

        try contents.appendSlice("# Axia-DE launcher state\n");
        for (self.favorite_ids.items) |id| {
            try contents.writer().print("favorite={s}\n", .{id});
        }
        for (self.recent_ids.items) |id| {
            try contents.writer().print("recent={s}\n", .{id});
        }

        try std.fs.cwd().writeFile(.{
            .sub_path = file_path,
            .data = contents.items,
        });
        log.info("saved launcher state to {s}", .{file_path});
    }

    pub fn ensureDefaultFavorites(self: *State, catalog: *const runtime_catalog.Catalog) !void {
        if (self.favorite_ids.items.len > 0) return;

        for (catalog.entries.items) |entry| {
            if (!entry.favorite or entry.id.len == 0) continue;
            try self.favorite_ids.append(self.allocator, try self.allocator.dupe(u8, entry.id));
        }
        try self.save();
    }

    pub fn isFavorite(self: *const State, id: []const u8) bool {
        return containsId(self.favorite_ids.items, id);
    }

    pub fn toggleFavorite(self: *State, id: []const u8) !bool {
        if (id.len == 0) return false;

        if (removeId(&self.favorite_ids, self.allocator, id)) {
            return false;
        }

        try self.favorite_ids.append(self.allocator, try self.allocator.dupe(u8, id));
        return true;
    }

    pub fn setFavorite(self: *State, id: []const u8, enabled: bool) !void {
        if (id.len == 0) return;

        if (enabled) {
            if (!self.isFavorite(id)) {
                try self.favorite_ids.append(self.allocator, try self.allocator.dupe(u8, id));
            }
            return;
        }

        _ = removeId(&self.favorite_ids, self.allocator, id);
    }

    pub fn moveFavorite(self: *State, id: []const u8, target_index: usize) !bool {
        if (id.len == 0) return false;

        var source_index: ?usize = null;
        for (self.favorite_ids.items, 0..) |item, index| {
            if (std.mem.eql(u8, item, id)) {
                source_index = index;
                break;
            }
        }
        const from = source_index orelse return false;
        const bounded_target = @min(target_index, self.favorite_ids.items.len - 1);
        if (from == bounded_target) return false;

        const moved = self.favorite_ids.orderedRemove(from);
        try self.favorite_ids.insert(self.allocator, bounded_target, moved);
        return true;
    }

    pub fn recordRecent(self: *State, id: []const u8) !void {
        if (id.len == 0) return;

        if (removeId(&self.recent_ids, self.allocator, id)) {}
        try self.recent_ids.insert(self.allocator, 0, try self.allocator.dupe(u8, id));

        while (self.recent_ids.items.len > max_recent_entries) {
            const removed = self.recent_ids.pop() orelse break;
            self.allocator.free(removed);
        }
    }

    pub fn favoriteEntries(
        self: *const State,
        allocator: std.mem.Allocator,
        catalog: *const runtime_catalog.Catalog,
    ) !std.ArrayListUnmanaged(runtime_catalog.AppEntry) {
        var favorites: std.ArrayListUnmanaged(runtime_catalog.AppEntry) = .empty;
        errdefer favorites.deinit(allocator);

        for (self.favorite_ids.items) |id| {
            const entry = catalog.findById(id) orelse continue;
            if (!entry.enabled) continue;
            try favorites.append(allocator, entry);
        }

        return favorites;
    }

    pub fn recentEntries(
        self: *const State,
        allocator: std.mem.Allocator,
        catalog: *const runtime_catalog.Catalog,
        limit: usize,
    ) !std.ArrayListUnmanaged(runtime_catalog.AppEntry) {
        var recents: std.ArrayListUnmanaged(runtime_catalog.AppEntry) = .empty;
        errdefer recents.deinit(allocator);

        for (self.recent_ids.items) |id| {
            if (recents.items.len >= limit) break;
            const entry = catalog.findById(id) orelse continue;
            if (!entry.enabled) continue;
            try recents.append(allocator, entry);
        }

        return recents;
    }
};

pub fn ensureDefaultFavorites(allocator: std.mem.Allocator, catalog: *const runtime_catalog.Catalog) !void {
    var state = try load(allocator);
    defer state.deinit();
    try state.ensureDefaultFavorites(catalog);
}

pub fn loadFavoriteEntries(allocator: std.mem.Allocator, catalog: *const runtime_catalog.Catalog) !std.ArrayListUnmanaged(runtime_catalog.AppEntry) {
    var state = try load(allocator);
    defer state.deinit();
    try state.ensureDefaultFavorites(catalog);
    return state.favoriteEntries(allocator, catalog);
}

pub fn loadRecentEntries(
    allocator: std.mem.Allocator,
    catalog: *const runtime_catalog.Catalog,
    limit: usize,
) !std.ArrayListUnmanaged(runtime_catalog.AppEntry) {
    var state = try load(allocator);
    defer state.deinit();
    return state.recentEntries(allocator, catalog, limit);
}

pub fn recordRecentId(allocator: std.mem.Allocator, id: []const u8) !void {
    var state = try load(allocator);
    defer state.deinit();
    try state.recordRecent(id);
    try state.save();
}

pub fn setFavoriteEnabled(allocator: std.mem.Allocator, id: []const u8, enabled: bool) !void {
    var state = try load(allocator);
    defer state.deinit();
    try state.setFavorite(id, enabled);
    try state.save();
}

pub fn moveFavoriteId(allocator: std.mem.Allocator, id: []const u8, target_index: usize) !bool {
    var state = try load(allocator);
    defer state.deinit();
    const changed = try state.moveFavorite(id, target_index);
    if (changed) try state.save();
    return changed;
}

pub fn load(allocator: std.mem.Allocator) !State {
    const path = try statePath(allocator);
    defer allocator.free(path);

    const contents = std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024) catch |err| switch (err) {
        error.FileNotFound => return .{ .allocator = allocator },
        else => return err,
    };
    defer allocator.free(contents);

    var state = State{ .allocator = allocator };
    errdefer state.deinit();

    var lines = std.mem.tokenizeScalar(u8, contents, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.startsWith(u8, line, "favorite=")) {
            const value = std.mem.trim(u8, line["favorite=".len..], " \r\t");
            if (value.len == 0 or containsId(state.favorite_ids.items, value)) continue;
            try state.favorite_ids.append(allocator, try allocator.dupe(u8, value));
            continue;
        }

        if (std.mem.startsWith(u8, line, "recent=")) {
            const value = std.mem.trim(u8, line["recent=".len..], " \r\t");
            if (value.len == 0 or containsId(state.recent_ids.items, value)) continue;
            try state.recent_ids.append(allocator, try allocator.dupe(u8, value));
            continue;
        }
    }

    return state;
}

fn containsId(items: []const []u8, id: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, id)) return true;
    }
    return false;
}

fn removeId(list: *std.ArrayListUnmanaged([]u8), allocator: std.mem.Allocator, id: []const u8) bool {
    for (list.items, 0..) |item, index| {
        if (!std.mem.eql(u8, item, id)) continue;
        allocator.free(item);
        _ = list.orderedRemove(index);
        return true;
    }
    return false;
}

fn statePath(allocator: std.mem.Allocator) ![]u8 {
    const dir_path = try stateDirPath(allocator);
    defer allocator.free(dir_path);
    return try std.fs.path.join(allocator, &.{ dir_path, "launcher.conf" });
}

fn stateDirPath(allocator: std.mem.Allocator) ![]u8 {
    const config_home = try configHome(allocator);
    defer allocator.free(config_home);
    return try std.fs.path.join(allocator, &.{ config_home, "axia-de" });
}

fn configHome(allocator: std.mem.Allocator) ![]u8 {
    const from_env = std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (from_env) |value| {
        if (value.len > 0) return value;
        allocator.free(value);
    }

    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, ".config" });
}
