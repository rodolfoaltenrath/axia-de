const std = @import("std");
const catalog = @import("apps_catalog");

pub const max_query_len: usize = 120;
pub const max_search_results: usize = 24;

pub const EntryView = struct {
    catalog_index: usize = 0,
    label: []const u8 = "",
    subtitle: []const u8 = "",
    shortcut: []const u8 = "",
    monogram: []const u8 = "",
    accent: [3]f64 = .{ 0.3, 0.7, 0.9 },
    enabled: bool = true,
};

pub const Snapshot = struct {
    query: []const u8 = "",
    count: usize = 0,
    selected: ?usize = null,
    entries: [max_search_results]EntryView = [_]EntryView{.{}} ** max_search_results,
};

pub const State = struct {
    query: [max_query_len]u8 = [_]u8{0} ** max_query_len,
    query_len: usize = 0,
    selected: usize = 0,

    pub fn appendText(self: *State, text: []const u8) void {
        for (text) |byte| {
            if (byte < 0x20) continue;
            if (self.query_len >= self.query.len) break;
            self.query[self.query_len] = byte;
            self.query_len += 1;
        }
        self.selected = 0;
    }

    pub fn backspace(self: *State) void {
        if (self.query_len == 0) return;
        self.query_len -= 1;
        self.selected = 0;
    }

    pub fn clear(self: *State) void {
        self.query_len = 0;
        self.selected = 0;
    }

    pub fn moveSelection(self: *State, limit: usize, delta: isize) void {
        const current_snapshot = self.snapshot(limit);
        if (current_snapshot.count == 0) {
            self.selected = 0;
            return;
        }

        const current: isize = @intCast(@min(self.selected, current_snapshot.count - 1));
        const next = std.math.clamp(current + delta, 0, @as(isize, @intCast(current_snapshot.count - 1)));
        self.selected = @intCast(next);
    }

    pub fn selectedCatalogIndex(self: *const State, limit: usize) ?usize {
        const current_snapshot = self.snapshot(limit);
        const selected = current_snapshot.selected orelse return null;
        return current_snapshot.entries[selected].catalog_index;
    }

    pub fn snapshot(self: *const State, limit: usize) Snapshot {
        var state = Snapshot{
            .query = self.query[0..self.query_len],
        };
        const capped_limit = @min(limit, state.entries.len);

        for (catalog.entries, 0..) |entry, index| {
            if (!matchesQuery(self.query[0..self.query_len], entry.label, entry.keywords, entry.subtitle)) continue;
            if (state.count >= capped_limit) break;

            state.entries[state.count] = .{
                .catalog_index = index,
                .label = entry.label,
                .subtitle = entry.subtitle,
                .shortcut = entry.shortcut,
                .monogram = entry.monogram,
                .accent = entry.accent,
                .enabled = entry.enabled,
            };
            state.count += 1;
        }

        if (state.count > 0) {
            state.selected = @min(self.selected, state.count - 1);
        }

        return state;
    }
};

fn matchesQuery(query: []const u8, label: []const u8, keywords: []const u8, subtitle: []const u8) bool {
    if (query.len == 0) return false;
    return containsIgnoreCase(label, query) or containsIgnoreCase(keywords, query) or containsIgnoreCase(subtitle, query);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}
