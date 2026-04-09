const std = @import("std");
const notification = @import("notification_model");

pub fn push(allocator: std.mem.Allocator, socket_path: []const u8, level: notification.Level, message: []const u8) !void {
    const address = try std.net.Address.initUnix(socket_path);
    const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
    defer std.posix.close(fd);

    try std.posix.connect(fd, &address.any, address.getOsSockLen());
    const payload = try std.fmt.allocPrint(allocator, "notification push {s} {s}\n", .{ notification.levelName(level), message });
    defer allocator.free(payload);
    _ = try std.posix.write(fd, payload);
}
