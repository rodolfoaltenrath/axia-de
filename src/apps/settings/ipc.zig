const std = @import("std");
const settings_model = @import("settings_model");

pub fn setWallpaper(allocator: std.mem.Allocator, socket_path: []const u8, wallpaper_path: []const u8) !void {
    const command = try std.fmt.allocPrint(allocator, "wallpaper set {s}\n", .{wallpaper_path});
    defer allocator.free(command);

    const response = try request(allocator, socket_path, command);
    defer allocator.free(response);

    if (!std.mem.startsWith(u8, std.mem.trim(u8, response, " \r\n\t"), "ok")) {
        return error.InvalidResponse;
    }
}

pub fn getRuntimeState(allocator: std.mem.Allocator, socket_path: []const u8) !settings_model.RuntimeState {
    const response = try request(allocator, socket_path, "runtime get\n");
    defer allocator.free(response);
    return parseRuntimeState(response);
}

pub fn setWorkspaceWrap(allocator: std.mem.Allocator, socket_path: []const u8, enabled: bool) !void {
    const command = try std.fmt.allocPrint(allocator, "workspace wrap {d}\n", .{@intFromBool(enabled)});
    defer allocator.free(command);

    const response = try request(allocator, socket_path, command);
    defer allocator.free(response);

    if (!std.mem.startsWith(u8, std.mem.trim(u8, response, " \r\n\t"), "ok")) {
        return error.InvalidResponse;
    }
}

pub fn activateWorkspace(allocator: std.mem.Allocator, socket_path: []const u8, index: usize) !void {
    const command = try std.fmt.allocPrint(allocator, "workspace activate {d}\n", .{index});
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

    var buffer: [1024]u8 = undefined;
    const len = try std.posix.read(fd, &buffer);
    return allocator.dupe(u8, buffer[0..len]);
}

fn parseRuntimeState(response: []const u8) !settings_model.RuntimeState {
    var state = settings_model.RuntimeState{};
    var lines = std.mem.tokenizeScalar(u8, std.mem.trim(u8, response, " \r\n\t"), '\n');

    const header = lines.next() orelse return error.InvalidResponse;
    {
        var tokens = std.mem.tokenizeAny(u8, header, " ");
        const status = tokens.next() orelse return error.InvalidResponse;
        const runtime = tokens.next() orelse return error.InvalidResponse;
        if (!std.mem.eql(u8, status, "ok") or !std.mem.eql(u8, runtime, "runtime")) return error.InvalidResponse;

        const current = tokens.next() orelse return error.InvalidResponse;
        const count = tokens.next() orelse return error.InvalidResponse;
        const display_count = tokens.next() orelse return error.InvalidResponse;
        const socket_name = tokens.rest();

        state.workspace_current = try std.fmt.parseUnsigned(usize, current, 10);
        state.workspace_count = try std.fmt.parseUnsigned(usize, count, 10);
        state.display_count = @min(try std.fmt.parseUnsigned(usize, display_count, 10), state.displays.len);
        state.socket_name_len = copyText(&state.socket_name, socket_name);
    }

    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "display ")) continue;

        var tokens = std.mem.tokenizeAny(u8, line, " ");
        _ = tokens.next();
        const raw_index = tokens.next() orelse continue;
        const raw_width = tokens.next() orelse continue;
        const raw_height = tokens.next() orelse continue;
        const raw_primary = tokens.next() orelse continue;
        const name = tokens.rest();

        const index = try std.fmt.parseUnsigned(usize, raw_index, 10);
        if (index >= state.displays.len) continue;

        state.displays[index].width = try std.fmt.parseUnsigned(u32, raw_width, 10);
        state.displays[index].height = try std.fmt.parseUnsigned(u32, raw_height, 10);
        state.displays[index].primary = (try std.fmt.parseUnsigned(u8, raw_primary, 10)) != 0;
        state.displays[index].name_len = copyText(&state.displays[index].name, name);
    }

    return state;
}

fn copyText(dest: []u8, src: []const u8) usize {
    const len = @min(dest.len, src.len);
    @memcpy(dest[0..len], src[0..len]);
    return len;
}
