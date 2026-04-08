const std = @import("std");

pub const max_toasts: usize = 4;
pub const max_message_len: usize = 160;

pub const Level = enum {
    info,
    success,
    warning,
    failure,
};

pub const Toast = struct {
    id: u32 = 0,
    level: Level = .info,
    created_ms: i64 = 0,
    duration_ms: i64 = 2800,
    message: [max_message_len]u8 = [_]u8{0} ** max_message_len,
    message_len: usize = 0,

    pub fn messageText(self: *const Toast) []const u8 {
        return self.message[0..self.message_len];
    }
};

pub const State = struct {
    count: usize = 0,
    items: [max_toasts]Toast = [_]Toast{.{}} ** max_toasts,
};

pub fn levelName(level: Level) []const u8 {
    return switch (level) {
        .info => "info",
        .success => "success",
        .warning => "warning",
        .failure => "error",
    };
}

pub fn parseLevel(text: []const u8) ?Level {
    if (std.ascii.eqlIgnoreCase(text, "info")) return .info;
    if (std.ascii.eqlIgnoreCase(text, "success")) return .success;
    if (std.ascii.eqlIgnoreCase(text, "warning")) return .warning;
    if (std.ascii.eqlIgnoreCase(text, "error")) return .failure;
    return null;
}

pub fn copyMessage(dest: *Toast, text: []const u8) void {
    const len = @min(text.len, dest.message.len);
    @memcpy(dest.message[0..len], text[0..len]);
    dest.message_len = len;
}

pub fn equal(a: State, b: State) bool {
    if (a.count != b.count) return false;
    for (0..a.count) |index| {
        const lhs = a.items[index];
        const rhs = b.items[index];
        if (lhs.id != rhs.id or lhs.level != rhs.level or lhs.message_len != rhs.message_len) return false;
        if (!std.mem.eql(u8, lhs.messageText(), rhs.messageText())) return false;
    }
    return true;
}
