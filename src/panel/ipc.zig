const std = @import("std");

pub const WorkspaceState = struct {
    current: usize = 0,
    count: usize = 4,
    summaries: [4]WorkspaceSummary = [_]WorkspaceSummary{.{}} ** 4,
};

pub const WorkspaceSummary = struct {
    window_count: usize = 0,
    focused: bool = false,
    preview: [96]u8 = [_]u8{0} ** 96,
    preview_len: usize = 0,

    pub fn previewText(self: *const WorkspaceSummary) []const u8 {
        return self.preview[0..self.preview_len];
    }
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

pub fn moveFocusedToWorkspace(allocator: std.mem.Allocator, socket_path: []const u8, index: usize) !WorkspaceState {
    var command: [64]u8 = undefined;
    const request_payload = try std.fmt.bufPrint(&command, "workspace move-focused {}\n", .{index});
    const response = try request(allocator, socket_path, request_payload);
    defer allocator.free(response);
    return parseWorkspaceState(response);
}

pub fn toggleLauncher(allocator: std.mem.Allocator, socket_path: []const u8) !void {
    const response = try request(allocator, socket_path, "launcher toggle\n");
    defer allocator.free(response);
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
    var state = WorkspaceState{};
    var lines = std.mem.tokenizeScalar(u8, std.mem.trim(u8, response, " \r\n\t"), '\n');

    const header = lines.next() orelse return error.InvalidResponse;
    {
        var tokens = std.mem.tokenizeAny(u8, header, " ");
        const status = tokens.next() orelse return error.InvalidResponse;
        if (!std.mem.eql(u8, status, "ok")) return error.InvalidResponse;

        const current = tokens.next() orelse return error.InvalidResponse;
        const count = tokens.next() orelse return error.InvalidResponse;

        state.current = try std.fmt.parseUnsigned(usize, current, 10);
        state.count = try std.fmt.parseUnsigned(usize, count, 10);
    }

    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "ws ")) continue;
        var tokens = std.mem.tokenizeAny(u8, line, " ");
        _ = tokens.next();
        const raw_index = tokens.next() orelse continue;
        const raw_count = tokens.next() orelse continue;
        const raw_focused = tokens.next() orelse continue;

        const index = try std.fmt.parseUnsigned(usize, raw_index, 10);
        if (index >= state.summaries.len) continue;

        state.summaries[index].window_count = try std.fmt.parseUnsigned(usize, raw_count, 10);
        state.summaries[index].focused = (try std.fmt.parseUnsigned(u8, raw_focused, 10)) != 0;

        var space_count: usize = 0;
        var preview_start: usize = line.len;
        for (line, 0..) |char, pos| {
            if (char == ' ') {
                space_count += 1;
                if (space_count == 4) {
                    preview_start = pos + 1;
                    break;
                }
            }
        }
        const preview = if (preview_start < line.len) line[preview_start..] else "";
        const preview_len = @min(preview.len, state.summaries[index].preview.len);
        @memcpy(state.summaries[index].preview[0..preview_len], preview[0..preview_len]);
        state.summaries[index].preview_len = preview_len;
    }

    return state;
}
