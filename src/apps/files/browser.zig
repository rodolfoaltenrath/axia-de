const std = @import("std");
const c = @cImport({
    @cInclude("sys/stat.h");
    @cInclude("time.h");
});

pub const sidebar_count: usize = 9;
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
    recents,
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
    .{ .target = .recents, .label = "Recentes", .icon = "R", .subdir = null },
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
        const home = try std.process.getEnvVarOwned(self.allocator, "HOME");
        defer self.allocator.free(home);

        const path = switch (target) {
            .recents, .trash, .network => try self.allocator.dupe(u8, home),
            .home => try self.allocator.dupe(u8, home),
            else => blk: {
                const item = sidebar_items[@intFromEnum(target)];
                break :blk try std.fs.path.join(self.allocator, &.{ home, item.subdir.? });
            },
        };
        defer self.allocator.free(path);

        self.openDirectory(path) catch |err| switch (err) {
            error.FileNotFound => try self.openDirectory(home),
            else => return err,
        };
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
        state.modified_descending = self.modified_descending;

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
};

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
