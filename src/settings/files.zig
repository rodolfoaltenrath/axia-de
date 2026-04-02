const std = @import("std");

pub const visible_entry_count: usize = 4;

pub const EntryKind = enum {
    directory,
    image,
};

pub const Entry = struct {
    kind: EntryKind,
    name: []u8,
    path: []u8,
};

pub const EntryView = struct {
    kind: EntryKind = .image,
    name: [96]u8 = [_]u8{0} ** 96,
    name_len: usize = 0,

    pub fn text(self: *const EntryView) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const Snapshot = struct {
    current_dir: []const u8 = "",
    count: usize = 0,
    total_count: usize = 0,
    page_start: usize = 0,
    has_previous: bool = false,
    has_next: bool = false,
    entries: [visible_entry_count]EntryView = [_]EntryView{.{}} ** visible_entry_count,
};

pub const Browser = struct {
    allocator: std.mem.Allocator,
    current_dir: ?[]u8 = null,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    page_start: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Browser {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Browser) void {
        self.clearEntries();
        if (self.current_dir) |dir| self.allocator.free(dir);
    }

    pub fn ensureDefaultDirectory(self: *Browser) !void {
        if (self.current_dir != null) return;

        const candidates = try defaultDirectories(self.allocator);
        defer {
            for (candidates) |path| self.allocator.free(path);
            self.allocator.free(candidates);
        }

        for (candidates) |candidate| {
            if (std.fs.openDirAbsolute(candidate, .{})) |opened_dir| {
                var dir = opened_dir;
                dir.close();
                try self.openDirectory(candidate);
                return;
            } else |_| {}
        }

        return error.NoDefaultBrowserDirectory;
    }

    pub fn openHome(self: *Browser) !void {
        const home = try std.process.getEnvVarOwned(self.allocator, "HOME");
        defer self.allocator.free(home);
        try self.openDirectory(home);
    }

    pub fn openPictures(self: *Browser) !void {
        try self.openKnownSubdir(&.{ "Pictures", "Imagens" });
    }

    pub fn openDownloads(self: *Browser) !void {
        try self.openKnownSubdir(&.{ "Downloads" });
    }

    pub fn openDirectory(self: *Browser, path: []const u8) !void {
        const normalized_path = try self.normalizePath(path);
        defer self.allocator.free(normalized_path);

        var dir = try std.fs.openDirAbsolute(normalized_path, .{ .iterate = true });
        defer dir.close();

        self.clearEntries();

        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.name.len == 0 or entry.name[0] == '.') continue;

            const kind: ?EntryKind = switch (entry.kind) {
                .directory => .directory,
                .file => if (isSupportedImage(entry.name)) .image else null,
                else => null,
            };
            if (kind == null) continue;

            const joined_path = try std.fs.path.join(self.allocator, &.{ normalized_path, entry.name });
            errdefer self.allocator.free(joined_path);

            const name = try self.allocator.dupe(u8, entry.name);
            errdefer self.allocator.free(name);

            try self.entries.append(self.allocator, .{
                .kind = kind.?,
                .name = name,
                .path = joined_path,
            });
        }

        std.sort.heap(Entry, self.entries.items, {}, lessThan);

        if (self.current_dir) |current_dir| self.allocator.free(current_dir);
        self.current_dir = try self.allocator.dupe(u8, normalized_path);
        self.page_start = 0;
    }

    pub fn goParent(self: *Browser) !void {
        const current_dir = self.current_dir orelse return;
        const parent = std.fs.path.dirname(current_dir) orelse return;
        if (parent.len == 0) return;
        try self.openDirectory(parent);
    }

    pub fn nextPage(self: *Browser) void {
        if (self.page_start + visible_entry_count < self.entries.items.len) {
            self.page_start += visible_entry_count;
        }
    }

    pub fn previousPage(self: *Browser) void {
        if (self.page_start >= visible_entry_count) {
            self.page_start -= visible_entry_count;
        } else {
            self.page_start = 0;
        }
    }

    pub fn visibleEntry(self: *Browser, visible_index: usize) ?Entry {
        const index = self.page_start + visible_index;
        if (index >= self.entries.items.len) return null;
        return self.entries.items[index];
    }

    pub fn snapshot(self: *Browser) Snapshot {
        var state = Snapshot{};
        state.current_dir = self.current_dir orelse "";
        state.total_count = self.entries.items.len;
        state.page_start = self.page_start;
        state.has_previous = self.page_start > 0;
        state.has_next = self.page_start + visible_entry_count < self.entries.items.len;

        const end = @min(self.entries.items.len, self.page_start + visible_entry_count);
        state.count = end - self.page_start;

        for (0..state.count) |visible_index| {
            const entry = self.entries.items[self.page_start + visible_index];
            state.entries[visible_index].kind = entry.kind;
            const name_len = @min(entry.name.len, state.entries[visible_index].name.len);
            @memcpy(state.entries[visible_index].name[0..name_len], entry.name[0..name_len]);
            state.entries[visible_index].name_len = name_len;
        }

        return state;
    }

    fn clearEntries(self: *Browser) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.path);
        }
        self.entries.clearAndFree(self.allocator);
        self.page_start = 0;
    }

    fn normalizePath(self: *Browser, path: []const u8) ![]u8 {
        if (std.fs.path.isAbsolute(path)) {
            return try self.allocator.dupe(u8, path);
        }

        if (self.current_dir) |current_dir| {
            return try std.fs.path.join(self.allocator, &.{ current_dir, path });
        }

        const cwd = try std.process.getCwdAlloc(self.allocator);
        defer self.allocator.free(cwd);
        return try std.fs.path.join(self.allocator, &.{ cwd, path });
    }

    fn openKnownSubdir(self: *Browser, names: []const []const u8) !void {
        const home = try std.process.getEnvVarOwned(self.allocator, "HOME");
        defer self.allocator.free(home);

        for (names) |name| {
            const path = try std.fs.path.join(self.allocator, &.{ home, name });
            defer self.allocator.free(path);

            if (std.fs.openDirAbsolute(path, .{})) |opened_dir| {
                var dir = opened_dir;
                dir.close();
                try self.openDirectory(path);
                return;
            } else |_| {}
        }

        try self.openDirectory(home);
    }
};

fn lessThan(_: void, lhs: Entry, rhs: Entry) bool {
    if (lhs.kind != rhs.kind) {
        return lhs.kind == .directory;
    }
    return std.ascii.lessThanIgnoreCase(lhs.name, rhs.name);
}

fn isSupportedImage(name: []const u8) bool {
    return endsWithIgnoreCase(name, ".png") or
        endsWithIgnoreCase(name, ".jpg") or
        endsWithIgnoreCase(name, ".jpeg") or
        endsWithIgnoreCase(name, ".webp") or
        endsWithIgnoreCase(name, ".bmp");
}

fn endsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[haystack.len - needle.len ..], needle);
}

fn defaultDirectories(allocator: std.mem.Allocator) ![][]u8 {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    const candidates = [_][]const u8{ "Pictures", "Imagens", "Wallpapers", "Downloads", "" };
    var paths = try allocator.alloc([]u8, candidates.len);
    errdefer {
        for (paths) |path| allocator.free(path);
        allocator.free(paths);
    }

    for (candidates, 0..) |suffix, index| {
        paths[index] = if (suffix.len == 0)
            try allocator.dupe(u8, home)
        else
            try std.fs.path.join(allocator, &.{ home, suffix });
    }

    return paths;
}
