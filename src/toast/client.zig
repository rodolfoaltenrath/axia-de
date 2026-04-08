const std = @import("std");
const model = @import("toast_model");

pub fn show(allocator: std.mem.Allocator, socket_path: []const u8, level: model.Level, message: []const u8) !void {
    const command = try std.fmt.allocPrint(allocator, "toast show {s} {s}\n", .{ model.levelName(level), message });
    defer allocator.free(command);

    const response = try request(allocator, socket_path, command);
    defer allocator.free(response);

    if (!std.mem.startsWith(u8, std.mem.trim(u8, response, " \r\n\t"), "ok")) {
        return error.InvalidResponse;
    }
}

fn request(allocator: std.mem.Allocator, socket_path: []const u8, payload: []const u8) ![]u8 {
    const address = try std.net.Address.initUnix(socket_path);
    const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
    defer std.posix.close(fd);

    try std.posix.connect(fd, &address.any, address.getOsSockLen());
    _ = try std.posix.write(fd, payload);

    var buffer: [256]u8 = undefined;
    const len = try std.posix.read(fd, &buffer);
    return allocator.dupe(u8, buffer[0..len]);
}
