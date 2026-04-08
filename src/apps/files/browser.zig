const std = @import("std");
const c = @cImport({
    @cInclude("sys/stat.h");
    @cInclude("time.h");
});

pub const sidebar_count: usize = 8;
pub const visible_entry_count: usize = 12;

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
    name: [120]u8 = [_]u8{0} ** 120,
    name_len: usize = 0,
    modified: [64]u8 = [_]u8{0} ** 64,
    modified_len: usize = 0,
    size: [32]u8 = [_]u8{0} ** 32,
    size_len: usize = 0,

    pub fn text(self: *const EntryView) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn modifiedText(self: *const EntryView) []const u8 {
        return self.modified[0..self.modified_len];
    }

    pub fn sizeText(self: *const EntryView) []const u8 {
        return self.size[0..self.size_len];
    }
};

pub const Snapshot = struct {
    current_dir: []const u8 = "",
    selected_path: []const u8 = "",
    selected_exists: bool = false,
    current_sidebar: ?SidebarTarget = null,
    selected_visible: bool = false,
    selected_visible_index: usize = 0,
    selected_is_file: bool = false,
    count: usize = 0,
    total_count: usize = 0,
    page_start: usize = 0,
    has_previous: bool = false,
    has_next: bool = false,
    modified_descending: bool = true,
    entries: [visible_entry_count]EntryView = [_]EntryView{.{}} ** visible_entry_count,
};

pub const SortField = enum {
    name,
    modified,
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
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    page_start: usize = 0,
    sort_field: SortField = .modified,
    modified_descending: bool = true,
    current_sidebar: ?SidebarTarget = null,

    pub fn init(allocator: std.mem.Allocator, mode: Mode) Browser {
        return .{
            .allocator = allocator,
            .mode = mode,
        };
    }

    pub fn deinit(self: *Browser) void {
        self.clearEntries();
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

            const metadata = try readEntryMetadata(self.allocator, joined_path, kind.?);

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

    pub fn toggleModifiedSort(self: *Browser) void {
        if (self.sort_field == .modified) {
            self.modified_descending = !self.modified_descending;
        } else {
            self.sort_field = .modified;
            self.modified_descending = true;
        }
        self.sortEntries();
    }

    pub fn scrollLines(self: *Browser, delta: isize) void {
        if (delta == 0) return;
        const max_start = self.maxPageStart();
        if (delta > 0) {
            const next = self.page_start + @as(usize, @intCast(delta));
            self.page_start = @min(next, max_start);
            return;
        }

        const amount: usize = @intCast(-delta);
        self.page_start = self.page_start -| amount;
    }

    pub fn visibleEntry(self: *Browser, visible_index: usize) ?Entry {
        const index = self.page_start + visible_index;
        if (index >= self.entries.items.len) return null;
        return self.entries.items[index];
    }

    pub fn selectedPath(self: *const Browser) ?[]const u8 {
        return self.selected_path;
    }

    pub fn hasSelection(self: *const Browser) bool {
        return self.selectedEntry() != null;
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
        return self.selected_path != null and std.mem.eql(u8, self.selected_path.?, path);
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
        const selected = self.selectedEntry() orelse return error.NoSelection;
        const trash_files = try self.trashFilesDir();
        defer self.allocator.free(trash_files);
        const trash_info = try self.trashInfoDir();
        defer self.allocator.free(trash_info);

        try ensureDirectoryPath(trash_files);
        try ensureDirectoryPath(trash_info);

        const trashed_name = try uniqueTrashName(self.allocator, trash_files, selected.name);
        defer self.allocator.free(trashed_name);

        const destination_path = try std.fs.path.join(self.allocator, &.{ trash_files, trashed_name });
        defer self.allocator.free(destination_path);

        try std.fs.renameAbsolute(selected.path, destination_path);
        try self.writeTrashInfo(trashed_name, selected.path);
        try self.openDirectory(current_dir);
    }

    pub fn deleteSelectedPermanently(self: *Browser) !void {
        const current_dir = self.current_dir orelse return error.NoCurrentDirectory;
        const selected = self.selectedEntry() orelse return error.NoSelection;
        switch (selected.kind) {
            .directory => try std.fs.deleteTreeAbsolute(selected.path),
            .file => try std.fs.deleteFileAbsolute(selected.path),
        }
        if (self.isViewingTrash()) {
            try self.removeTrashInfoFor(selected.name);
        }
        try self.openDirectory(current_dir);
    }

    pub fn isViewingTrash(self: *const Browser) bool {
        return self.current_sidebar == .trash;
    }

    pub fn selectVisible(self: *Browser, visible_index: usize) !void {
        const entry = self.visibleEntry(visible_index) orelse return;
        if (self.selected_path) |selected| self.allocator.free(selected);
        self.selected_path = try self.allocator.dupe(u8, entry.path);
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
        state.selected_exists = self.selectedEntry() != null;
        state.current_sidebar = self.current_sidebar;
        state.total_count = self.entries.items.len;
        state.page_start = self.page_start;
        state.has_previous = self.page_start > 0;
        state.has_next = self.page_start + visible_entry_count < self.entries.items.len;
        state.modified_descending = self.modified_descending;
        state.selected_is_file = self.hasSelectedFile();

        const end = @min(self.entries.items.len, self.page_start + visible_entry_count);
        state.count = end - self.page_start;
        for (0..state.count) |visible_index| {
            const entry = self.entries.items[self.page_start + visible_index];
            state.entries[visible_index].kind = entry.kind;
            const len = @min(entry.name.len, state.entries[visible_index].name.len);
            @memcpy(state.entries[visible_index].name[0..len], entry.name[0..len]);
            state.entries[visible_index].name_len = len;
            state.entries[visible_index].modified_len = formatModified(
                entry.modified_unix,
                state.entries[visible_index].modified[0..],
            );
            state.entries[visible_index].size_len = formatSize(
                entry,
                state.entries[visible_index].size[0..],
            );
            if (self.selected_path != null and std.mem.eql(u8, entry.path, self.selected_path.?)) {
                state.selected_visible = true;
                state.selected_visible_index = visible_index;
            }
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
            self.page_start = ((self.entries.items.len - 1) / visible_entry_count) * visible_entry_count;
        }
    }

    fn maxPageStart(self: *const Browser) usize {
        if (self.entries.items.len <= visible_entry_count) return 0;
        return self.entries.items.len - visible_entry_count;
    }

    fn selectedEntry(self: *const Browser) ?Entry {
        const selected = self.selected_path orelse return null;
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.path, selected)) return entry;
        }
        return null;
    }

    fn selectPath(self: *Browser, path: []const u8) !void {
        for (self.entries.items, 0..) |entry, index| {
            if (!std.mem.eql(u8, entry.path, path)) continue;
            if (self.selected_path) |selected| self.allocator.free(selected);
            self.selected_path = try self.allocator.dupe(u8, entry.path);
            if (index < self.page_start or index >= self.page_start + visible_entry_count) {
                self.page_start = (index / visible_entry_count) * visible_entry_count;
            }
            return;
        }
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
    };
}

const EntryMetadata = struct {
    modified_unix: i64,
    file_size_bytes: u64,
    child_count: usize,
};

fn readEntryMetadata(allocator: std.mem.Allocator, path: []const u8, kind: EntryKind) !EntryMetadata {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const c_path = toCString(&path_buf, path);
    var stat_buf: c.struct_stat = undefined;
    if (c.stat(c_path.ptr, &stat_buf) != 0) {
        return .{ .modified_unix = 0, .file_size_bytes = 0, .child_count = 0 };
    }

    return .{
        .modified_unix = @intCast(stat_buf.st_mtim.tv_sec),
        .file_size_bytes = if (kind == .file) @intCast(stat_buf.st_size) else 0,
        .child_count = if (kind == .directory) countDirectoryChildren(allocator, path) catch 0 else 0,
    };
}

fn countDirectoryChildren(allocator: std.mem.Allocator, path: []const u8) !usize {
    const normalized = try normalizeAbsolute(allocator, path);
    defer allocator.free(normalized);

    var dir = try std.fs.openDirAbsolute(normalized, .{ .iterate = true });
    defer dir.close();

    var count: usize = 0;
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        count += 1;
    }
    return count;
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
        .directory => std.fmt.bufPrint(buffer, "{d} itens", .{entry.child_count}) catch return writeText(buffer, "Pasta"),
        .file => std.fmt.bufPrint(buffer, "{d} bytes", .{entry.file_size_bytes}) catch return writeText(buffer, "Arquivo"),
    };
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
