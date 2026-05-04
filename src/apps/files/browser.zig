const std = @import("std");
const c = @cImport({
    @cInclude("sys/stat.h");
    @cInclude("time.h");
});

pub const sidebar_count: usize = 8;
pub const max_visible_entry_count: usize = 192;
pub const max_pinned_count: usize = 12;

pub const EntryKind = enum {
    directory,
    file,
};

pub const Entry = struct {
    kind: EntryKind,
    name: []u8,
    path: []u8,
    modified_unix: i64,
    file_size_bytes: u64,
    child_count: usize,
};

pub const EntryView = struct {
    kind: EntryKind = .file,
    selected: bool = false,
    name: []const u8 = "",
    path: []const u8 = "",
    modified: [64]u8 = [_]u8{0} ** 64,
    modified_len: usize = 0,
    size: [32]u8 = [_]u8{0} ** 32,
    size_len: usize = 0,
    modified_unix: i64 = 0,
    file_size_bytes: u64 = 0,

    pub fn text(self: *const EntryView) []const u8 {
        return self.name;
    }

    pub fn pathText(self: *const EntryView) []const u8 {
        return self.path;
    }

    pub fn modifiedText(self: *const EntryView) []const u8 {
        return self.modified[0..self.modified_len];
    }

    pub fn sizeText(self: *const EntryView) []const u8 {
        return self.size[0..self.size_len];
    }
};

pub const PinnedFolderView = struct {
    label: []const u8 = "",
    path: []const u8 = "",

    pub fn labelText(self: *const PinnedFolderView) []const u8 {
        return self.label;
    }

    pub fn pathText(self: *const PinnedFolderView) []const u8 {
        return self.path;
    }
};

pub const Snapshot = struct {
    current_dir: []const u8 = "",
    selected_path: []const u8 = "",
    selected_exists: bool = false,
    current_sidebar: ?SidebarTarget = null,
    selected_visible: bool = false,
    selected_visible_index: usize = 0,
    selected_count: usize = 0,
    selected_file_count: usize = 0,
    selected_is_file: bool = false,
    count: usize = 0,
    total_count: usize = 0,
    page_start: usize = 0,
    has_previous: bool = false,
    has_next: bool = false,
    modified_descending: bool = true,
    entries: [max_visible_entry_count]EntryView = [_]EntryView{.{}} ** max_visible_entry_count,
    selected_size: [32]u8 = [_]u8{0} ** 32,
    selected_size_len: usize = 0,
    pinned_count: usize = 0,
    pinned: [max_pinned_count]PinnedFolderView = [_]PinnedFolderView{.{}} ** max_pinned_count,

    pub fn selectedSizeText(self: *const Snapshot) []const u8 {
        return self.selected_size[0..self.selected_size_len];
    }
};

pub const SortField = enum {
    name,
    modified,
    size,
};

pub const SidebarTarget = enum {
    home,
    documents,
    downloads,
    music,
    pictures,
    videos,
    trash,
    network,
};

pub const Mode = enum {
    browser,
    wallpaper_picker,
};

const PinnedFolder = struct {
    label: []u8,
    path: []u8,
};

pub const sidebar_items = [_]struct {
    target: SidebarTarget,
    label: []const u8,
    icon: []const u8,
    subdir: ?[]const u8,
}{
    .{ .target = .home, .label = "Pasta pessoal", .icon = "H", .subdir = null },
    .{ .target = .documents, .label = "Documentos", .icon = "D", .subdir = "Documentos" },
    .{ .target = .downloads, .label = "Downloads", .icon = "V", .subdir = "Downloads" },
    .{ .target = .music, .label = "Músicas", .icon = "M", .subdir = "Músicas" },
    .{ .target = .pictures, .label = "Imagens", .icon = "I", .subdir = "Imagens" },
    .{ .target = .videos, .label = "Vídeos", .icon = "F", .subdir = "Vídeos" },
    .{ .target = .trash, .label = "Lixeira", .icon = "L", .subdir = null },
    .{ .target = .network, .label = "Redes", .icon = "N", .subdir = null },
};

pub const Browser = struct {
    allocator: std.mem.Allocator,
    mode: Mode = .browser,
    current_dir: ?[]u8 = null,
    selected_path: ?[]u8 = null,
    selected_paths: std.ArrayListUnmanaged([]u8) = .empty,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    pinned_folders: std.ArrayListUnmanaged(PinnedFolder) = .empty,
    page_start: usize = 0,
    sort_field: SortField = .modified,
    modified_descending: bool = true,
    current_sidebar: ?SidebarTarget = null,

    pub fn init(allocator: std.mem.Allocator, mode: Mode) Browser {
        var result = Browser{
            .allocator = allocator,
            .mode = mode,
        };
        result.loadPinnedFolders() catch |err| {
            std.log.scoped(.axia_files).warn("failed to load pinned folders: {}", .{err});
        };
        return result;
    }

    pub fn deinit(self: *Browser) void {
        self.clearEntries();
        self.clearSelection();
        self.selected_paths.deinit(self.allocator);
        self.clearPinnedFolders();
        self.pinned_folders.deinit(self.allocator);
        if (self.current_dir) |dir| self.allocator.free(dir);
        if (self.selected_path) |path| self.allocator.free(path);
    }

    pub fn ensureDefaultDirectory(self: *Browser) !void {
        if (self.current_dir != null) return;
        if (self.mode == .wallpaper_picker) {
            self.openSidebar(.pictures) catch |err| switch (err) {
                error.FileNotFound => try self.openSidebar(.home),
                else => return err,
            };
            return;
        }
        try self.openSidebar(.home);
    }

    pub fn openSidebar(self: *Browser, target: SidebarTarget) !void {
        const fallback_home = try std.process.getEnvVarOwned(self.allocator, "HOME");
        defer self.allocator.free(fallback_home);

        const path = switch (target) {
            .trash => try self.trashFilesDir(),
            .network => blk: {
                break :blk try self.allocator.dupe(u8, fallback_home);
            },
            .home => blk: {
                break :blk try self.allocator.dupe(u8, fallback_home);
            },
            else => blk: {
                const item = sidebar_items[@intFromEnum(target)];
                break :blk try std.fs.path.join(self.allocator, &.{ fallback_home, item.subdir.? });
            },
        };
        defer self.allocator.free(path);

        self.openDirectory(path) catch |err| switch (err) {
            error.FileNotFound => try self.openDirectory(fallback_home),
            else => return err,
        };
        self.current_sidebar = target;
    }

    pub fn openPinnedFolder(self: *Browser, index: usize) !void {
        if (index >= self.pinned_folders.items.len) return;
        try self.openDirectory(self.pinned_folders.items[index].path);
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
                .file => if (self.mode == .wallpaper_picker and !isSupportedImage(entry.name)) null else .file,
                else => null,
            };
            if (kind == null) continue;

            const joined_path = try std.fs.path.join(self.allocator, &.{ normalized, entry.name });
            errdefer self.allocator.free(joined_path);

            const name = try self.allocator.dupe(u8, entry.name);
            errdefer self.allocator.free(name);

            const metadata = readEntryMetadata(joined_path, kind.?);

            try self.entries.append(self.allocator, .{
                .kind = kind.?,
                .name = name,
                .path = joined_path,
                .modified_unix = metadata.modified_unix,
                .file_size_bytes = metadata.file_size_bytes,
                .child_count = metadata.child_count,
            });
        }

        self.sortEntries();

        if (self.current_dir) |existing| self.allocator.free(existing);
        self.current_dir = try self.allocator.dupe(u8, normalized);
        self.current_sidebar = inferSidebarTarget(self.allocator, normalized);
        self.page_start = 0;
        self.clearSelection();
    }

    pub fn goParent(self: *Browser) !void {
        const current_dir = self.current_dir orelse return;
        const parent = std.fs.path.dirname(current_dir) orelse return;
        if (parent.len == 0) return;
        try self.openDirectory(parent);
    }

    pub fn nextPage(self: *Browser, visible_limit: usize) void {
        const limit = boundedVisibleLimit(visible_limit);
        if (self.page_start + limit < self.entries.items.len) {
            self.page_start = @min(self.page_start + limit, self.maxPageStartFor(limit));
        }
    }

    pub fn previousPage(self: *Browser, visible_limit: usize) void {
        const limit = boundedVisibleLimit(visible_limit);
        if (self.page_start >= limit) {
            self.page_start -= limit;
        } else {
            self.page_start = 0;
        }
    }

    pub fn toggleModifiedSort(self: *Browser) void {
        if (self.sort_field == .modified) {
            self.modified_descending = !self.modified_descending;
        } else {
            self.sort_field = .modified;
            self.modified_descending = true;
        }
        self.sortEntries();
    }

    pub fn sortByName(self: *Browser) void {
        self.sort_field = .name;
        self.sortEntries();
    }

    pub fn sortByModified(self: *Browser) void {
        self.sort_field = .modified;
        self.modified_descending = true;
        self.sortEntries();
    }

    pub fn sortBySize(self: *Browser) void {
        self.sort_field = .size;
        self.sortEntries();
    }

    pub fn scrollItems(self: *Browser, delta: isize, visible_limit: usize) void {
        if (delta == 0) return;
        const max_start = self.maxPageStartFor(boundedVisibleLimit(visible_limit));
        if (delta > 0) {
            const next = self.page_start + @as(usize, @intCast(delta));
            self.page_start = @min(next, max_start);
            return;
        }

        const amount: usize = @intCast(-delta);
        self.page_start = self.page_start -| amount;
    }

    pub fn isCurrentDirectoryPinned(self: *const Browser) bool {
        const current_dir = self.current_dir orelse return false;
        return self.findPinnedFolder(current_dir) != null;
    }

    pub fn canPinSelection(self: *const Browser) bool {
        const entry = self.selectedEntry() orelse return false;
        return entry.kind == .directory and self.findPinnedFolder(entry.path) == null;
    }

    pub fn canUnpinSelection(self: *const Browser) bool {
        const entry = self.selectedEntry() orelse return false;
        return entry.kind == .directory and self.findPinnedFolder(entry.path) != null;
    }

    pub fn canUnpinCurrentDirectory(self: *const Browser) bool {
        const current_dir = self.current_dir orelse return false;
        return self.findPinnedFolder(current_dir) != null;
    }

    pub fn pinSelectedDirectory(self: *Browser) !void {
        const entry = self.selectedEntry() orelse return error.NoSelection;
        if (entry.kind != .directory) return error.NoSelection;
        try self.pinDirectory(entry.path);
    }

    pub fn pinCurrentDirectory(self: *Browser) !void {
        const current_dir = self.current_dir orelse return error.NoCurrentDirectory;
        try self.pinDirectory(current_dir);
    }

    pub fn unpinSelectedDirectory(self: *Browser) !void {
        const entry = self.selectedEntry() orelse return error.NoSelection;
        try self.unpinDirectory(entry.path);
    }

    pub fn unpinCurrentDirectory(self: *Browser) !void {
        const current_dir = self.current_dir orelse return error.NoCurrentDirectory;
        try self.unpinDirectory(current_dir);
    }

    pub fn visibleEntry(self: *Browser, visible_index: usize) ?Entry {
        const index = self.page_start + visible_index;
        if (index >= self.entries.items.len) return null;
        return self.entries.items[index];
    }

    pub fn visibleCount(self: *const Browser, visible_limit: usize) usize {
        const limit = boundedVisibleLimit(visible_limit);
        const end = @min(self.entries.items.len, self.page_start + limit);
        return end - self.page_start;
    }

    pub fn pinnedFolderCount(self: *const Browser) usize {
        return @min(self.pinned_folders.items.len, max_pinned_count);
    }

    pub fn selectedPath(self: *const Browser) ?[]const u8 {
        return self.selected_path;
    }

    pub fn currentDirectory(self: *const Browser) ?[]const u8 {
        return self.current_dir;
    }

    pub fn hasSelection(self: *const Browser) bool {
        return self.selectedEntry() != null;
    }

    pub fn selectedCount(self: *const Browser) usize {
        return self.selected_paths.items.len;
    }

    pub fn hasSelectedFile(self: *const Browser) bool {
        const entry = self.selectedEntry() orelse return false;
        return entry.kind == .file;
    }

    pub fn hasSelectedDirectory(self: *const Browser) bool {
        const entry = self.selectedEntry() orelse return false;
        return entry.kind == .directory;
    }

    pub fn isSelectedPath(self: *const Browser, path: []const u8) bool {
        for (self.selected_paths.items) |selected| {
            if (std.mem.eql(u8, selected, path)) return true;
        }
        return false;
    }

    pub fn selectedName(self: *const Browser) ?[]const u8 {
        const entry = self.selectedEntry() orelse return null;
        return entry.name;
    }

    pub fn activateSelected(self: *Browser) !void {
        const entry = self.selectedEntry() orelse return;
        switch (entry.kind) {
            .directory => try self.openDirectory(entry.path),
            .file => {},
        }
    }

    pub fn createDirectoryNamed(self: *Browser, name: []const u8) !void {
        const current_dir = self.current_dir orelse return error.NoCurrentDirectory;
        const trimmed = std.mem.trim(u8, name, " \t\r\n");
        if (trimmed.len == 0) return error.InvalidName;
        if (std.mem.indexOfScalar(u8, trimmed, '/') != null) return error.InvalidName;

        const target_path = try std.fs.path.join(self.allocator, &.{ current_dir, trimmed });
        defer self.allocator.free(target_path);
        try std.fs.makeDirAbsolute(target_path);
        try self.openDirectory(current_dir);
        try self.selectPath(target_path);
    }

    pub fn createFileNamed(self: *Browser, name: []const u8) !void {
        const current_dir = self.current_dir orelse return error.NoCurrentDirectory;
        const trimmed = std.mem.trim(u8, name, " \t\r\n");
        if (trimmed.len == 0) return error.InvalidName;
        if (std.mem.indexOfScalar(u8, trimmed, '/') != null) return error.InvalidName;

        const target_path = try std.fs.path.join(self.allocator, &.{ current_dir, trimmed });
        defer self.allocator.free(target_path);
        var file = try std.fs.createFileAbsolute(target_path, .{ .exclusive = true });
        file.close();
        try self.openDirectory(current_dir);
        try self.selectPath(target_path);
    }

    pub fn renameSelectedTo(self: *Browser, name: []const u8) !void {
        const current_dir = self.current_dir orelse return error.NoCurrentDirectory;
        const selected = self.selectedEntry() orelse return error.NoSelection;
        const trimmed = std.mem.trim(u8, name, " \t\r\n");
        if (trimmed.len == 0) return error.InvalidName;
        if (std.mem.indexOfScalar(u8, trimmed, '/') != null) return error.InvalidName;
        if (std.mem.eql(u8, trimmed, selected.name)) return;

        const target_path = try std.fs.path.join(self.allocator, &.{ current_dir, trimmed });
        defer self.allocator.free(target_path);
        try std.fs.renameAbsolute(selected.path, target_path);
        try self.openDirectory(current_dir);
        try self.selectPath(target_path);
    }

    pub fn deleteSelected(self: *Browser) !void {
        if (self.isViewingTrash()) {
            return try self.deleteSelectedPermanently();
        }

        const current_dir = self.current_dir orelse return error.NoCurrentDirectory;
        const trash_files = try self.trashFilesDir();
        defer self.allocator.free(trash_files);
        const trash_info = try self.trashInfoDir();
        defer self.allocator.free(trash_info);

        try ensureDirectoryPath(trash_files);
        try ensureDirectoryPath(trash_info);

        if (self.selected_paths.items.len == 0) return error.NoSelection;
        for (self.selected_paths.items) |path| {
            const selected = self.entryForPath(path) orelse continue;
            const trashed_name = try uniqueTrashName(self.allocator, trash_files, selected.name);
            defer self.allocator.free(trashed_name);

            const destination_path = try std.fs.path.join(self.allocator, &.{ trash_files, trashed_name });
            defer self.allocator.free(destination_path);

            try std.fs.renameAbsolute(selected.path, destination_path);
            try self.writeTrashInfo(trashed_name, selected.path);
        }
        try self.openDirectory(current_dir);
    }

    pub fn deleteSelectedPermanently(self: *Browser) !void {
        const current_dir = self.current_dir orelse return error.NoCurrentDirectory;
        if (self.selected_paths.items.len == 0) return error.NoSelection;
        for (self.selected_paths.items) |path| {
            const selected = self.entryForPath(path) orelse continue;
            switch (selected.kind) {
                .directory => try std.fs.deleteTreeAbsolute(selected.path),
                .file => try std.fs.deleteFileAbsolute(selected.path),
            }
            if (self.isViewingTrash()) {
                try self.removeTrashInfoFor(selected.name);
            }
        }
        try self.openDirectory(current_dir);
    }

    pub fn pastePaths(self: *Browser, paths: []const []const u8) !usize {
        const current_dir = self.current_dir orelse return error.NoCurrentDirectory;
        var pasted: usize = 0;
        var last_pasted: ?[]u8 = null;
        defer if (last_pasted) |path| self.allocator.free(path);

        for (paths) |source| {
            if (source.len == 0) continue;
            const normalized = try normalizeAbsolute(self.allocator, source);
            defer self.allocator.free(normalized);
            if (std.mem.eql(u8, normalized, current_dir)) continue;

            const name = basenameLabel(normalized);
            const target_name = try uniqueNameInDir(self.allocator, current_dir, name);
            defer self.allocator.free(target_name);
            const target_path = try std.fs.path.join(self.allocator, &.{ current_dir, target_name });
            defer self.allocator.free(target_path);

            if (isDirectoryPath(normalized)) {
                try copyDirectoryRecursive(self.allocator, normalized, target_path);
            } else {
                try std.fs.copyFileAbsolute(normalized, target_path, .{});
            }

            if (last_pasted) |path| self.allocator.free(path);
            last_pasted = try self.allocator.dupe(u8, target_path);
            pasted += 1;
        }

        if (pasted > 0) {
            try self.openDirectory(current_dir);
            if (last_pasted) |path| try self.selectPath(path);
        }
        return pasted;
    }

    pub fn isViewingTrash(self: *const Browser) bool {
        return self.current_sidebar == .trash;
    }

    pub fn selectVisible(self: *Browser, visible_index: usize) !void {
        const entry = self.visibleEntry(visible_index) orelse return;
        try self.setSingleSelection(entry.path);
    }

    pub fn selectAll(self: *Browser) !void {
        self.clearSelection();
        for (self.entries.items) |entry| {
            try self.addSelectedPath(entry.path);
        }
        if (self.entries.items.len > 0) {
            try self.setPrimarySelection(self.entries.items[0].path);
        }
    }

    pub fn toggleVisibleSelection(self: *Browser, visible_index: usize) !void {
        const entry = self.visibleEntry(visible_index) orelse return;
        if (self.removeSelectedPath(entry.path)) return;
        try self.addSelectedPath(entry.path);
        try self.setPrimarySelection(entry.path);
    }

    pub fn activateVisible(self: *Browser, visible_index: usize) !void {
        const entry = self.visibleEntry(visible_index) orelse return;
        switch (entry.kind) {
            .directory => try self.openDirectory(entry.path),
            .file => {
                try self.setSingleSelection(entry.path);
            },
        }
    }

    pub fn snapshot(self: *Browser, visible_limit: usize) Snapshot {
        var state = Snapshot{};
        state.current_dir = self.current_dir orelse "";
        state.selected_path = self.selected_path orelse "";
        state.selected_count = self.selected_paths.items.len;
        state.selected_exists = state.selected_count > 0;
        state.current_sidebar = self.current_sidebar;
        state.total_count = self.entries.items.len;
        const limit = boundedVisibleLimit(visible_limit);
        if (self.page_start > self.maxPageStartFor(limit)) self.page_start = self.maxPageStartFor(limit);
        state.page_start = self.page_start;
        state.has_previous = self.page_start > 0;
        state.has_next = self.page_start + limit < self.entries.items.len;
        state.modified_descending = self.modified_descending;
        state.selected_is_file = self.hasSelectedFile();
        var selected_total_size: u64 = 0;
        for (self.selected_paths.items) |path| {
            const selected = self.entryForPath(path) orelse continue;
            if (selected.kind == .file) {
                state.selected_file_count += 1;
                selected_total_size += selected.file_size_bytes;
            }
        }
        if (state.selected_count == 1) {
            if (self.selectedEntry()) |selected| {
                state.selected_size_len = formatSize(selected, state.selected_size[0..]);
            }
        } else if (state.selected_count > 1 and state.selected_file_count == state.selected_count) {
            state.selected_size_len = formatByteSize(selected_total_size, state.selected_size[0..]);
        }

        const end = @min(self.entries.items.len, self.page_start + limit);
        state.count = end - self.page_start;
        for (0..state.count) |visible_index| {
            const entry = self.entries.items[self.page_start + visible_index];
            state.entries[visible_index].kind = entry.kind;
            state.entries[visible_index].selected = self.isSelectedPath(entry.path);
            state.entries[visible_index].name = entry.name;
            state.entries[visible_index].path = entry.path;
            state.entries[visible_index].modified_unix = entry.modified_unix;
            state.entries[visible_index].file_size_bytes = entry.file_size_bytes;
            state.entries[visible_index].modified_len = formatModified(
                entry.modified_unix,
                state.entries[visible_index].modified[0..],
            );
            state.entries[visible_index].size_len = formatSize(
                entry,
                state.entries[visible_index].size[0..],
            );
            if (state.entries[visible_index].selected) {
                state.selected_visible = true;
                state.selected_visible_index = visible_index;
            }
        }

        state.pinned_count = @min(self.pinned_folders.items.len, max_pinned_count);
        for (0..state.pinned_count) |index| {
            const pinned = self.pinned_folders.items[index];
            state.pinned[index].label = pinned.label;
            state.pinned[index].path = pinned.path;
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

    fn sortEntries(self: *Browser) void {
        std.sort.heap(Entry, self.entries.items, self.*, lessThan);
        if (self.page_start >= self.entries.items.len and self.entries.items.len > 0) {
            self.page_start = self.maxPageStartFor(max_visible_entry_count);
        }
    }

    fn maxPageStartFor(self: *const Browser, visible_limit: usize) usize {
        const limit = boundedVisibleLimit(visible_limit);
        if (self.entries.items.len <= limit) return 0;
        return self.entries.items.len - limit;
    }

    fn selectedEntry(self: *const Browser) ?Entry {
        const selected = self.selected_path orelse return null;
        return self.entryForPath(selected);
    }

    fn entryForPath(self: *const Browser, selected: []const u8) ?Entry {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.path, selected)) return entry;
        }
        return null;
    }

    fn setSingleSelection(self: *Browser, path: []const u8) !void {
        self.clearSelection();
        try self.addSelectedPath(path);
        try self.setPrimarySelection(path);
    }

    fn addSelectedPath(self: *Browser, path: []const u8) !void {
        if (self.isSelectedPath(path)) return;
        try self.selected_paths.append(self.allocator, try self.allocator.dupe(u8, path));
    }

    fn removeSelectedPath(self: *Browser, path: []const u8) bool {
        for (self.selected_paths.items, 0..) |selected, index| {
            if (!std.mem.eql(u8, selected, path)) continue;
            const removed = self.selected_paths.orderedRemove(index);
            self.allocator.free(removed);
            if (self.selected_path != null and std.mem.eql(u8, self.selected_path.?, path)) {
                self.allocator.free(self.selected_path.?);
                self.selected_path = null;
                if (self.selected_paths.items.len > 0) {
                    self.selected_path = self.allocator.dupe(u8, self.selected_paths.items[0]) catch null;
                }
            }
            return true;
        }
        return false;
    }

    fn setPrimarySelection(self: *Browser, path: []const u8) !void {
        if (self.selected_path) |selected| self.allocator.free(selected);
        self.selected_path = try self.allocator.dupe(u8, path);
    }

    fn clearSelection(self: *Browser) void {
        if (self.selected_path) |selected| self.allocator.free(selected);
        self.selected_path = null;
        for (self.selected_paths.items) |selected| self.allocator.free(selected);
        self.selected_paths.clearRetainingCapacity();
    }

    fn selectPath(self: *Browser, path: []const u8) !void {
        for (self.entries.items, 0..) |entry, index| {
            if (!std.mem.eql(u8, entry.path, path)) continue;
            try self.setSingleSelection(entry.path);
            if (index < self.page_start or index >= self.page_start + max_visible_entry_count) {
                self.page_start = (index / max_visible_entry_count) * max_visible_entry_count;
            }
            return;
        }
    }

    fn pinDirectory(self: *Browser, path: []const u8) !void {
        if (self.findPinnedFolder(path) != null) return;
        if (self.pinned_folders.items.len >= max_pinned_count) return error.TooManyPinnedFolders;

        const normalized = try normalizeAbsolute(self.allocator, path);
        defer self.allocator.free(normalized);

        var dir = try std.fs.openDirAbsolute(normalized, .{});
        dir.close();

        try self.pinned_folders.append(self.allocator, .{
            .label = try self.allocator.dupe(u8, basenameLabel(normalized)),
            .path = try self.allocator.dupe(u8, normalized),
        });
        try self.savePinnedFolders();
    }

    fn unpinDirectory(self: *Browser, path: []const u8) !void {
        const index = self.findPinnedFolder(path) orelse return;
        const removed = self.pinned_folders.orderedRemove(index);
        self.allocator.free(removed.label);
        self.allocator.free(removed.path);
        try self.savePinnedFolders();
    }

    fn findPinnedFolder(self: *const Browser, path: []const u8) ?usize {
        for (self.pinned_folders.items, 0..) |pinned, index| {
            if (std.mem.eql(u8, pinned.path, path)) return index;
        }
        return null;
    }

    fn clearPinnedFolders(self: *Browser) void {
        for (self.pinned_folders.items) |pinned| {
            self.allocator.free(pinned.label);
            self.allocator.free(pinned.path);
        }
        self.pinned_folders.clearRetainingCapacity();
    }

    fn loadPinnedFolders(self: *Browser) !void {
        const path = try pinnedFoldersPath(self.allocator);
        defer self.allocator.free(path);

        const contents = std.fs.cwd().readFileAlloc(self.allocator, path, 64 * 1024) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(contents);

        var lines = std.mem.tokenizeScalar(u8, contents, '\n');
        while (lines.next()) |line_raw| {
            if (self.pinned_folders.items.len >= max_pinned_count) break;
            const line = std.mem.trim(u8, line_raw, " \r\t");
            if (line.len == 0 or line[0] == '#') continue;
            if (self.findPinnedFolder(line) != null) continue;
            var dir = std.fs.openDirAbsolute(line, .{}) catch continue;
            dir.close();
            try self.pinned_folders.append(self.allocator, .{
                .label = try self.allocator.dupe(u8, basenameLabel(line)),
                .path = try self.allocator.dupe(u8, line),
            });
        }
    }

    fn savePinnedFolders(self: *Browser) !void {
        const dir_path = try axiaConfigDir(self.allocator);
        defer self.allocator.free(dir_path);
        try std.fs.cwd().makePath(dir_path);

        const path = try pinnedFoldersPath(self.allocator);
        defer self.allocator.free(path);

        var contents = std.array_list.Managed(u8).init(self.allocator);
        defer contents.deinit();
        try contents.appendSlice("# Axia Files pinned folders\n");
        for (self.pinned_folders.items) |pinned| {
            try contents.writer().print("{s}\n", .{pinned.path});
        }
        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = contents.items });
    }

    fn trashBaseDir(self: *const Browser) ![]u8 {
        const home = try std.process.getEnvVarOwned(self.allocator, "HOME");
        defer self.allocator.free(home);
        return try std.fs.path.join(self.allocator, &.{ home, ".local", "share", "Trash" });
    }

    fn trashFilesDir(self: *const Browser) ![]u8 {
        const base = try self.trashBaseDir();
        defer self.allocator.free(base);
        return try std.fs.path.join(self.allocator, &.{ base, "files" });
    }

    fn trashInfoDir(self: *const Browser) ![]u8 {
        const base = try self.trashBaseDir();
        defer self.allocator.free(base);
        return try std.fs.path.join(self.allocator, &.{ base, "info" });
    }

    fn writeTrashInfo(self: *Browser, trashed_name: []const u8, original_path: []const u8) !void {
        const info_dir = try self.trashInfoDir();
        defer self.allocator.free(info_dir);
        try ensureDirectoryPath(info_dir);

        const info_name = try std.fmt.allocPrint(self.allocator, "{s}.trashinfo", .{trashed_name});
        defer self.allocator.free(info_name);
        const info_path = try std.fs.path.join(self.allocator, &.{ info_dir, info_name });
        defer self.allocator.free(info_path);

        var file = try std.fs.createFileAbsolute(info_path, .{ .truncate = true, .read = false });
        defer file.close();

        var date_buf: [32]u8 = undefined;
        const date = formatTrashDeletionDate(&date_buf);
        const contents = try std.fmt.allocPrint(
            self.allocator,
            "[Trash Info]\nPath={s}\nDeletionDate={s}\n",
            .{ original_path, date },
        );
        defer self.allocator.free(contents);
        try file.writeAll(contents);
    }

    fn removeTrashInfoFor(self: *Browser, trashed_name: []const u8) !void {
        const info_dir = try self.trashInfoDir();
        defer self.allocator.free(info_dir);
        const info_name = try std.fmt.allocPrint(self.allocator, "{s}.trashinfo", .{trashed_name});
        defer self.allocator.free(info_name);
        const info_path = try std.fs.path.join(self.allocator, &.{ info_dir, info_name });
        defer self.allocator.free(info_path);
        std.fs.deleteFileAbsolute(info_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
};

fn inferSidebarTarget(allocator: std.mem.Allocator, normalized: []const u8) ?SidebarTarget {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return null;
    defer allocator.free(home);
    const trash = std.fs.path.join(allocator, &.{ home, ".local", "share", "Trash", "files" }) catch return null;
    defer allocator.free(trash);

    if (std.mem.eql(u8, normalized, home)) return .home;
    if (std.mem.eql(u8, normalized, trash)) return .trash;

    for (sidebar_items) |item| {
        if (item.subdir == null) continue;
        const candidate = std.fs.path.join(allocator, &.{ home, item.subdir.? }) catch {
            continue;
        };
        defer allocator.free(candidate);
        if (std.mem.eql(u8, normalized, candidate)) return item.target;
    }

    return null;
}

fn ensureDirectoryPath(path: []const u8) !void {
    try std.fs.cwd().makePath(path);
}

fn uniqueTrashName(allocator: std.mem.Allocator, trash_dir: []const u8, original_name: []const u8) ![]u8 {
    var candidate = try allocator.dupe(u8, original_name);
    errdefer allocator.free(candidate);

    var index: usize = 1;
    while (pathExists(trash_dir, candidate)) {
        allocator.free(candidate);
        candidate = try appendDuplicateSuffix(allocator, original_name, index);
        index += 1;
    }
    return candidate;
}

fn pathExists(base_dir: []const u8, name: []const u8) bool {
    const full_path = std.fs.path.join(std.heap.page_allocator, &.{ base_dir, name }) catch return false;
    defer std.heap.page_allocator.free(full_path);
    std.fs.accessAbsolute(full_path, .{}) catch return false;
    return true;
}

fn uniqueNameInDir(allocator: std.mem.Allocator, base_dir: []const u8, original_name: []const u8) ![]u8 {
    var candidate = try allocator.dupe(u8, original_name);
    errdefer allocator.free(candidate);

    var index: usize = 1;
    while (pathExists(base_dir, candidate)) {
        allocator.free(candidate);
        candidate = try appendDuplicateSuffix(allocator, original_name, index);
        index += 1;
    }
    return candidate;
}

fn appendDuplicateSuffix(allocator: std.mem.Allocator, original_name: []const u8, index: usize) ![]u8 {
    const extension = std.fs.path.extension(original_name);
    if (extension.len == 0 or extension.len == original_name.len) {
        return try std.fmt.allocPrint(allocator, "{s} ({d})", .{ original_name, index });
    }
    const stem = original_name[0 .. original_name.len - extension.len];
    return try std.fmt.allocPrint(allocator, "{s} ({d}){s}", .{ stem, index, extension });
}

fn formatTrashDeletionDate(buffer: []u8) []const u8 {
    var now: c.time_t = @intCast(std.time.timestamp());
    var local_time: c.struct_tm = undefined;
    if (c.localtime_r(&now, &local_time) == null) return "1970-01-01T00:00:00";
    const len = c.strftime(buffer.ptr, buffer.len, "%Y-%m-%dT%H:%M:%S", &local_time);
    return buffer[0..len];
}

fn normalizeAbsolute(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return try allocator.dupe(u8, path);
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    return try std.fs.path.join(allocator, &.{ cwd, path });
}

fn isDirectoryPath(path: []const u8) bool {
    var dir = std.fs.openDirAbsolute(path, .{}) catch return false;
    dir.close();
    return true;
}

fn copyDirectoryRecursive(allocator: std.mem.Allocator, source: []const u8, destination: []const u8) !void {
    try std.fs.makeDirAbsolute(destination);
    var source_dir = try std.fs.openDirAbsolute(source, .{ .iterate = true });
    defer source_dir.close();

    var iterator = source_dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.name.len == 0) continue;
        const source_child = try std.fs.path.join(allocator, &.{ source, entry.name });
        defer allocator.free(source_child);
        const destination_child = try std.fs.path.join(allocator, &.{ destination, entry.name });
        defer allocator.free(destination_child);

        switch (entry.kind) {
            .directory => try copyDirectoryRecursive(allocator, source_child, destination_child),
            .file => try std.fs.copyFileAbsolute(source_child, destination_child, .{}),
            else => {},
        }
    }
}

fn boundedVisibleLimit(value: usize) usize {
    return std.math.clamp(value, 1, max_visible_entry_count);
}

fn basenameLabel(path: []const u8) []const u8 {
    if (path.len == 0) return "Pasta";
    const base = std.fs.path.basename(path);
    if (base.len == 0) return path;
    return base;
}

fn pinnedFoldersPath(allocator: std.mem.Allocator) ![]u8 {
    const dir_path = try axiaConfigDir(allocator);
    defer allocator.free(dir_path);
    return try std.fs.path.join(allocator, &.{ dir_path, "files-pins.conf" });
}

fn axiaConfigDir(allocator: std.mem.Allocator) ![]u8 {
    const config_home = std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (config_home) |value| {
        defer allocator.free(value);
        if (value.len > 0) return try std.fs.path.join(allocator, &.{ value, "axia-de" });
    }

    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return try std.fs.path.join(allocator, &.{ home, ".config", "axia-de" });
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

fn lessThan(browser_state: Browser, lhs: Entry, rhs: Entry) bool {
    if (lhs.kind != rhs.kind) return lhs.kind == .directory;

    return switch (browser_state.sort_field) {
        .name => std.ascii.lessThanIgnoreCase(lhs.name, rhs.name),
        .modified => blk: {
            if (lhs.modified_unix != rhs.modified_unix) {
                break :blk if (browser_state.modified_descending)
                    lhs.modified_unix > rhs.modified_unix
                else
                    lhs.modified_unix < rhs.modified_unix;
            }
            break :blk std.ascii.lessThanIgnoreCase(lhs.name, rhs.name);
        },
        .size => blk: {
            const lhs_size = if (lhs.kind == .directory) lhs.child_count else lhs.file_size_bytes;
            const rhs_size = if (rhs.kind == .directory) rhs.child_count else rhs.file_size_bytes;
            if (lhs_size != rhs_size) break :blk lhs_size > rhs_size;
            break :blk std.ascii.lessThanIgnoreCase(lhs.name, rhs.name);
        },
    };
}

const EntryMetadata = struct {
    modified_unix: i64,
    file_size_bytes: u64,
    child_count: usize,
};

fn readEntryMetadata(path: []const u8, kind: EntryKind) EntryMetadata {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const c_path = toCString(&path_buf, path);
    var stat_buf: c.struct_stat = undefined;
    if (c.stat(c_path.ptr, &stat_buf) != 0) {
        return .{ .modified_unix = 0, .file_size_bytes = 0, .child_count = 0 };
    }

    return .{
        .modified_unix = @intCast(stat_buf.st_mtim.tv_sec),
        .file_size_bytes = if (kind == .file) @intCast(stat_buf.st_size) else 0,
        .child_count = 0,
    };
}

fn formatModified(timestamp: i64, buffer: []u8) usize {
    if (timestamp <= 0) return writeText(buffer, "—");

    var raw_time: c.time_t = @intCast(timestamp);
    var tm_value: c.struct_tm = undefined;
    _ = c.localtime_r(&raw_time, &tm_value);

    const months = [_][]const u8{
        "jan.", "fev.", "mar.", "abr.", "mai.", "jun.", "jul.", "ago.", "set.", "out.", "nov.", "dez.",
    };

    const month_index: usize = @intCast(@max(tm_value.tm_mon, 0));
    const hour: u32 = @intCast(@max(tm_value.tm_hour, 0));
    const minute: u32 = @intCast(@max(tm_value.tm_min, 0));

    const text = std.fmt.bufPrint(
        buffer,
        "{d} de {s} de {d}, {d:0>2}:{d:0>2}",
        .{
            tm_value.tm_mday,
            months[@min(month_index, months.len - 1)],
            tm_value.tm_year + 1900,
            hour,
            minute,
        },
    ) catch return writeText(buffer, "—");
    return text.len;
}

fn formatSize(entry: Entry, buffer: []u8) usize {
    const text = switch (entry.kind) {
        .directory => return writeText(buffer, "Pasta"),
        .file => std.fmt.bufPrint(buffer, "{d} bytes", .{entry.file_size_bytes}) catch return writeText(buffer, "Arquivo"),
    };
    return text.len;
}

fn formatByteSize(bytes: u64, buffer: []u8) usize {
    const text = std.fmt.bufPrint(buffer, "{d} bytes", .{bytes}) catch return writeText(buffer, "Arquivos");
    return text.len;
}

fn writeText(target: []u8, text: []const u8) usize {
    const len = @min(target.len, text.len);
    @memcpy(target[0..len], text[0..len]);
    return len;
}

fn toCString(buffer: []u8, text: []const u8) [:0]u8 {
    const len = @min(buffer.len - 1, text.len);
    @memcpy(buffer[0..len], text[0..len]);
    buffer[len] = 0;
    return buffer[0..len :0];
}
