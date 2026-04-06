const std = @import("std");
const runtime_catalog = @import("runtime_catalog");
const empty_entries = [_]runtime_catalog.AppEntry{};

pub const max_query_len: usize = 120;
pub const max_search_results: usize = 24;

pub const EntryView = struct {
    catalog_index: usize = 0,
    label: []const u8 = "",
    subtitle: []const u8 = "",
    shortcut: []const u8 = "",
    monogram: []const u8 = "",
    accent: [3]f64 = .{ 0.3, 0.7, 0.9 },
    favorite: bool = false,
    enabled: bool = true,
};

pub const Snapshot = struct {
    query: []const u8 = "",
    count: usize = 0,
    showing_recent: bool = false,
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
        self.moveSelectionWithEntries(empty_entries[0..], empty_entries[0..], limit, delta);
    }

    pub fn moveSelectionWithEntries(
        self: *State,
        entries: []const runtime_catalog.AppEntry,
        recent_entries: []const runtime_catalog.AppEntry,
        limit: usize,
        delta: isize,
    ) void {
        const current_snapshot = self.snapshotWithEntries(entries, recent_entries, limit);
        if (current_snapshot.count == 0) {
            self.selected = 0;
            return;
        }

        const current: isize = @intCast(@min(self.selected, current_snapshot.count - 1));
        const next = std.math.clamp(current + delta, 0, @as(isize, @intCast(current_snapshot.count - 1)));
        self.selected = @intCast(next);
    }

    pub fn selectedCatalogIndex(self: *const State, limit: usize) ?usize {
        return self.selectedCatalogIndexWithEntries(empty_entries[0..], empty_entries[0..], limit);
    }

    pub fn selectedCatalogIndexWithEntries(
        self: *const State,
        entries: []const runtime_catalog.AppEntry,
        recent_entries: []const runtime_catalog.AppEntry,
        limit: usize,
    ) ?usize {
        const current_snapshot = self.snapshotWithEntries(entries, recent_entries, limit);
        const selected = current_snapshot.selected orelse return null;
        return current_snapshot.entries[selected].catalog_index;
    }

    pub fn snapshot(self: *const State, limit: usize) Snapshot {
        return self.snapshotWithEntries(empty_entries[0..], empty_entries[0..], limit);
    }

    pub fn snapshotWithEntries(
        self: *const State,
        entries: []const runtime_catalog.AppEntry,
        recent_entries: []const runtime_catalog.AppEntry,
        limit: usize,
    ) Snapshot {
        var state = Snapshot{
            .query = self.query[0..self.query_len],
        };
        const capped_limit = @min(limit, state.entries.len);
        var scores: [max_search_results]u16 = [_]u16{0} ** max_search_results;

        if (self.query_len == 0) {
            const count = @min(recent_entries.len, capped_limit);
            state.showing_recent = count > 0;

            for (recent_entries[0..count], 0..) |entry, index| {
                state.entries[index] = .{
                    .catalog_index = indexOfEntry(entries, entry.id) orelse continue,
                    .label = entry.label,
                    .subtitle = entry.subtitle,
                    .shortcut = "",
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

        for (entries, 0..) |entry, index| {
            const score = matchScore(self.query[0..self.query_len], entry) orelse continue;

            var insert_at = state.count;
            while (insert_at > 0) {
                const prev = insert_at - 1;
                if (!shouldInsertBefore(score, entry.label, scores[prev], state.entries[prev].label)) break;
                insert_at = prev;
            }
            if (insert_at >= capped_limit) continue;

            const next_count = @min(state.count + 1, capped_limit);
            var shift = next_count;
            while (shift > insert_at + 1) : (shift -= 1) {
                scores[shift - 1] = scores[shift - 2];
                state.entries[shift - 1] = state.entries[shift - 2];
            }

            state.entries[insert_at] = .{
                .catalog_index = index,
                .label = entry.label,
                .subtitle = entry.subtitle,
                .shortcut = entry.shortcut,
                .monogram = entry.monogram,
                .accent = entry.accent,
                .enabled = entry.enabled,
            };
            scores[insert_at] = score;
            state.count = next_count;
        }

        if (state.count > 0) {
            state.selected = @min(self.selected, state.count - 1);
        }

        return state;
    }
};

fn indexOfEntry(entries: []const runtime_catalog.AppEntry, id: []const u8) ?usize {
    for (entries, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.id, id)) return index;
    }
    return null;
}

fn shouldInsertBefore(score: u16, label: []const u8, previous_score: u16, previous_label: []const u8) bool {
    if (score != previous_score) return score > previous_score;
    return std.ascii.lessThanIgnoreCase(label, previous_label);
}

fn matchScore(query: []const u8, entry: runtime_catalog.AppEntry) ?u16 {
    if (query.len == 0) return null;

    var best: u16 = 0;
    best = @max(best, fieldScore(query, entry.label, .label));
    best = @max(best, fieldScore(query, execSearchKey(entry.command), .exec));
    best = @max(best, fieldScore(query, entry.keywords, .keywords));
    best = @max(best, fieldScore(query, entry.subtitle, .subtitle));
    if (best == 0) return null;
    return best;
}

const FieldKind = enum {
    label,
    exec,
    keywords,
    subtitle,
};

fn fieldScore(query: []const u8, value: []const u8, kind: FieldKind) u16 {
    if (value.len == 0) return 0;

    const exact: u16 = switch (kind) {
        .label => 1000,
        .exec => 900,
        .keywords => 680,
        .subtitle => 560,
    };
    const prefix: u16 = switch (kind) {
        .label => 920,
        .exec => 840,
        .keywords => 620,
        .subtitle => 500,
    };
    const contains: u16 = switch (kind) {
        .label => 820,
        .exec => 760,
        .keywords => 560,
        .subtitle => 440,
    };

    if (std.ascii.eqlIgnoreCase(value, query)) return exact;
    if (startsWithIgnoreCase(value, query)) return prefix;
    if (containsIgnoreCase(value, query)) return contains;
    return 0;
}

fn execSearchKey(command: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, command, " \r\n\t");
    if (trimmed.len == 0) return "";
    if (std.mem.startsWith(u8, trimmed, "exec ")) {
        return executableToken(std.mem.trimLeft(u8, trimmed[5..], " \t"));
    }
    return executableToken(trimmed);
}

fn executableToken(command: []const u8) []const u8 {
    var tokens = std.mem.tokenizeAny(u8, command, " \t");
    while (tokens.next()) |token| {
        const trimmed = std.mem.trim(u8, token, "\"'");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, "env")) continue;
        if (trimmed[0] == '-') continue;
        if (std.mem.indexOfScalar(u8, trimmed, '=')) |_| continue;
        return std.fs.path.basename(trimmed);
    }
    return "";
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
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
