const std = @import("std");

pub const WorkspaceState = struct {
    current: usize = 0,
    count: usize = 4,
};

pub fn getWorkspaceState(allocator: std.mem.Allocator, socket_path: []const u8) !WorkspaceState {
    const response = try request(allocator, socket_path, "workspace get\n");
    defer allocator.free(response);
    return parseWorkspaceState(response);
}

pub fn activateWorkspace(allocator: std.mem.Allocator, socket_path: []const u8, index: usize) !WorkspaceState {
    var command: [64]u8 = undefined;
    const request_payload = try std.fmt.bufPrint(&command, "workspace activate {}\n", .{index});
    const response = try request(allocator, socket_path, request_payload);
    defer allocator.free(response);
    return parseWorkspaceState(response);
}

fn request(allocator: std.mem.Allocator, socket_path: []const u8, payload: []const u8) ![]u8 {
    const address = try std.net.Address.initUnix(socket_path);
    const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
    defer std.posix.close(fd);

    try std.posix.connect(fd, &address.any, address.getOsSockLen());
    _ = try std.posix.write(fd, payload);

    var buffer: [128]u8 = undefined;
    const len = try std.posix.read(fd, &buffer);
    return allocator.dupe(u8, buffer[0..len]);
}

fn parseWorkspaceState(response: []const u8) !WorkspaceState {
    var tokens = std.mem.tokenizeAny(u8, std.mem.trim(u8, response, " \r\n\t"), " ");
    const status = tokens.next() orelse return error.InvalidResponse;
    if (!std.mem.eql(u8, status, "ok")) return error.InvalidResponse;

    const current = tokens.next() orelse return error.InvalidResponse;
    const count = tokens.next() orelse return error.InvalidResponse;

    return .{
        .current = try std.fmt.parseUnsigned(usize, current, 10),
        .count = try std.fmt.parseUnsigned(usize, count, 10),
    };
}
