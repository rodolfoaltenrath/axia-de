const std = @import("std");

pub const sidebar_count: usize = 5;
pub const visible_entry_count: usize = 12;

pub const EntryKind = enum {
    directory,
    file,
};

pub const Entry = struct {
    kind: EntryKind,
    name: []u8,
    path: []u8,
};

pub const EntryView = struct {
    kind: EntryKind = .file,
    name: [120]u8 = [_]u8{0} ** 120,
    name_len: usize = 0,

    pub fn text(self: *const EntryView) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const Snapshot = struct {
    current_dir: []const u8 = "",
    selected_path: []const u8 = "",
    count: usize = 0,
    total_count: usize = 0,
    page_start: usize = 0,
    has_previous: bool = false,
    has_next: bool = false,
    entries: [visible_entry_count]EntryView = [_]EntryView{.{}} ** visible_entry_count,
};

pub const SidebarTarget = enum {
    home,
    desktop,
    documents,
    downloads,
    pictures,
};

pub const sidebar_items = [_]struct {
    target: SidebarTarget,
    label: []const u8,
    subdir: ?[]const u8,
}{
    .{ .target = .home, .label = "Início", .subdir = null },
    .{ .target = .desktop, .label = "Área de Trabalho", .subdir = "Desktop" },
    .{ .target = .documents, .label = "Documentos", .subdir = "Documentos" },
    .{ .target = .downloads, .label = "Downloads", .subdir = "Downloads" },
    .{ .target = .pictures, .label = "Imagens", .subdir = "Imagens" },
};

pub const Browser = struct {
    allocator: std.mem.Allocator,
    current_dir: ?[]u8 = null,
    selected_path: ?[]u8 = null,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    page_start: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Browser {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Browser) void {
        self.clearEntries();
        if (self.current_dir) |dir| self.allocator.free(dir);
        if (self.selected_path) |path| self.allocator.free(path);
    }

    pub fn ensureDefaultDirectory(self: *Browser) !void {
        if (self.current_dir != null) return;
        try self.openSidebar(.home);
    }

    pub fn openSidebar(self: *Browser, target: SidebarTarget) !void {
        const home = try std.process.getEnvVarOwned(self.allocator, "HOME");
        defer self.allocator.free(home);

        const path = switch (target) {
            .home => try self.allocator.dupe(u8, home),
            else => blk: {
                const item = sidebar_items[@intFromEnum(target)];
                break :blk try std.fs.path.join(self.allocator, &.{ home, item.subdir.? });
            },
        };
        defer self.allocator.free(path);

        try self.openDirectory(path);
    }

    pub fn openDirectory(self: *Browser, path: []const u8) !void {
        const normalized = try normalizeAbsolute(self.allocator, path);
        defer self.allocator.free(normalized);

        var dir = try std.fs.openDirAbsolute(normalized, .{ .iterate = true });
        defer dir.close();

        self.clearEntries();

        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.name.len == 0 or entry.name[0] == '.') continue;

            const kind: ?EntryKind = switch (entry.kind) {
                .directory => .directory,
                .file => .file,
                else => null,
            };
            if (kind == null) continue;

            const joined_path = try std.fs.path.join(self.allocator, &.{ normalized, entry.name });
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

        if (self.current_dir) |existing| self.allocator.free(existing);
        self.current_dir = try self.allocator.dupe(u8, normalized);
        self.page_start = 0;
        if (self.selected_path) |selected| {
            self.allocator.free(selected);
            self.selected_path = null;
        }
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

    pub fn activateVisible(self: *Browser, visible_index: usize) !void {
        const entry = self.visibleEntry(visible_index) orelse return;
        switch (entry.kind) {
            .directory => try self.openDirectory(entry.path),
            .file => {
                if (self.selected_path) |selected| self.allocator.free(selected);
                self.selected_path = try self.allocator.dupe(u8, entry.path);
            },
        }
    }

    pub fn snapshot(self: *Browser) Snapshot {
        var state = Snapshot{};
        state.current_dir = self.current_dir orelse "";
        state.selected_path = self.selected_path orelse "";
        state.total_count = self.entries.items.len;
        state.page_start = self.page_start;
        state.has_previous = self.page_start > 0;
        state.has_next = self.page_start + visible_entry_count < self.entries.items.len;

        const end = @min(self.entries.items.len, self.page_start + visible_entry_count);
        state.count = end - self.page_start;
        for (0..state.count) |visible_index| {
            const entry = self.entries.items[self.page_start + visible_index];
            state.entries[visible_index].kind = entry.kind;
            const len = @min(entry.name.len, state.entries[visible_index].name.len);
            @memcpy(state.entries[visible_index].name[0..len], entry.name[0..len]);
            state.entries[visible_index].name_len = len;
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
};

fn normalizeAbsolute(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return try allocator.dupe(u8, path);
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    return try std.fs.path.join(allocator, &.{ cwd, path });
}

fn lessThan(_: void, lhs: Entry, rhs: Entry) bool {
    if (lhs.kind != rhs.kind) return lhs.kind == .directory;
    return std.ascii.lessThanIgnoreCase(lhs.name, rhs.name);
}
