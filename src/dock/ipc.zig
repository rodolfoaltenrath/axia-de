const std = @import("std");

pub const OpenAppInfo = struct {
    id: [64]u8 = [_]u8{0} ** 64,
    id_len: usize = 0,
    title: [96]u8 = [_]u8{0} ** 96,
    title_len: usize = 0,
    focused: bool = false,

    pub fn idText(self: *const OpenAppInfo) []const u8 {
        return self.id[0..self.id_len];
    }
};

pub const OpenAppsState = struct {
    count: usize = 0,
    apps: [16]OpenAppInfo = [_]OpenAppInfo{.{}} ** 16,
};

pub fn getOpenApps(allocator: std.mem.Allocator, socket_path: []const u8) !OpenAppsState {
    const response = try request(allocator, socket_path, "runtime get\n");
    defer allocator.free(response);
    return parseOpenApps(response);
}

pub fn focusApp(allocator: std.mem.Allocator, socket_path: []const u8, app_id: []const u8) !bool {
    const payload = try std.fmt.allocPrint(allocator, "app focus {s}\n", .{app_id});
    defer allocator.free(payload);

    const response = try request(allocator, socket_path, payload);
    defer allocator.free(response);
    return std.mem.startsWith(u8, std.mem.trim(u8, response, " \r\n\t"), "ok");
}

pub fn closeApp(allocator: std.mem.Allocator, socket_path: []const u8, app_id: []const u8) !bool {
    const payload = try std.fmt.allocPrint(allocator, "app close {s}\n", .{app_id});
    defer allocator.free(payload);

    const response = try request(allocator, socket_path, payload);
    defer allocator.free(response);
    return std.mem.startsWith(u8, std.mem.trim(u8, response, " \r\n\t"), "ok");
}

pub fn showPreview(allocator: std.mem.Allocator, socket_path: []const u8, app_id: []const u8, anchor_x: i32) !void {
    const payload = try std.fmt.allocPrint(allocator, "preview show {s} {d}\n", .{ app_id, anchor_x });
    defer allocator.free(payload);

    const response = try request(allocator, socket_path, payload);
    defer allocator.free(response);
    if (!std.mem.startsWith(u8, std.mem.trim(u8, response, " \r\n\t"), "ok")) return error.InvalidResponse;
}

pub fn hidePreview(allocator: std.mem.Allocator, socket_path: []const u8) !void {
    const response = try request(allocator, socket_path, "preview hide\n");
    defer allocator.free(response);
    if (!std.mem.startsWith(u8, std.mem.trim(u8, response, " \r\n\t"), "ok")) return error.InvalidResponse;
}

pub fn toggleAppGrid(allocator: std.mem.Allocator, socket_path: []const u8) !void {
    const response = try request(allocator, socket_path, "app-grid toggle\n");
    defer allocator.free(response);
    if (!std.mem.startsWith(u8, std.mem.trim(u8, response, " \r\n\t"), "ok")) return error.InvalidResponse;
}

pub fn updateGlassRegion(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    surface_height: i32,
) !void {
    const payload = try std.fmt.allocPrint(
        allocator,
        "dock glass {d} {d} {d} {d} {d}\n",
        .{ x, y, width, height, surface_height },
    );
    defer allocator.free(payload);

    const response = try request(allocator, socket_path, payload);
    defer allocator.free(response);
    if (!std.mem.startsWith(u8, std.mem.trim(u8, response, " \r\n\t"), "ok")) return error.InvalidResponse;
}

fn request(allocator: std.mem.Allocator, socket_path: []const u8, payload: []const u8) ![]u8 {
    const address = try std.net.Address.initUnix(socket_path);
    const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0);
    defer std.posix.close(fd);

    try std.posix.connect(fd, &address.any, address.getOsSockLen());
    _ = try std.posix.write(fd, payload);

    var buffer: [4096]u8 = undefined;
    const len = try std.posix.read(fd, &buffer);
    return allocator.dupe(u8, buffer[0..len]);
}

fn parseOpenApps(response: []const u8) !OpenAppsState {
    var state = OpenAppsState{};
    var lines = std.mem.tokenizeScalar(u8, std.mem.trim(u8, response, " \r\n\t"), '\n');

    const header = lines.next() orelse return error.InvalidResponse;
    if (!std.mem.startsWith(u8, header, "ok runtime ")) return error.InvalidResponse;

    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "app ")) continue;
        if (state.count >= state.apps.len) break;

        var tokens = std.mem.tokenizeAny(u8, line, " ");
        _ = tokens.next();
        _ = tokens.next() orelse continue;
        const raw_focused = tokens.next() orelse continue;
        const id = tokens.next() orelse continue;
        if (isHiddenFromDock(id)) continue;
        const title = tokens.rest();

        var app = &state.apps[state.count];
        app.focused = (try std.fmt.parseUnsigned(u8, raw_focused, 10)) != 0;
        app.id_len = copyText(&app.id, id);
        app.title_len = copyText(&app.title, title);
        state.count += 1;
    }

    return state;
}

fn isHiddenFromDock(app_id: []const u8) bool {
    return std.mem.eql(u8, app_id, "axia-launcher");
}

fn copyText(dest: []u8, src: []const u8) usize {
    const len = @min(dest.len, src.len);
    @memcpy(dest[0..len], src[0..len]);
    return len;
}
