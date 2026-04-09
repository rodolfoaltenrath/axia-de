const std = @import("std");

pub const max_notifications: usize = 48;
pub const max_message_len: usize = 160;
pub const retention_ms: i64 = 48 * 60 * 60 * 1000;

pub const Level = enum {
    info,
    success,
    warning,
    failure,
};

pub const Notification = struct {
    id: u32 = 0,
    level: Level = .info,
    created_ms: i64 = 0,
    message: [max_message_len]u8 = [_]u8{0} ** max_message_len,
    message_len: usize = 0,

    pub fn messageText(self: *const Notification) []const u8 {
        return self.message[0..self.message_len];
    }
};

pub const State = struct {
    count: usize = 0,
    do_not_disturb: bool = false,
    items: [max_notifications]Notification = [_]Notification{.{}} ** max_notifications,
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

pub fn copyMessage(dest: *Notification, text: []const u8) void {
    const len = @min(text.len, dest.message.len);
    @memcpy(dest.message[0..len], text[0..len]);
    dest.message_len = len;
}

pub fn equal(a: State, b: State) bool {
    if (a.count != b.count or a.do_not_disturb != b.do_not_disturb) return false;
    for (0..a.count) |index| {
        const lhs = a.items[index];
        const rhs = b.items[index];
        if (lhs.id != rhs.id or lhs.level != rhs.level or lhs.created_ms != rhs.created_ms or lhs.message_len != rhs.message_len) return false;
        if (!std.mem.eql(u8, lhs.messageText(), rhs.messageText())) return false;
    }
    return true;
}
