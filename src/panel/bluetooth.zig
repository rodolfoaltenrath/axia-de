const std = @import("std");

pub const DeviceState = struct {
    address: [18]u8 = [_]u8{0} ** 18,
    address_len: usize = 0,
    name: [160]u8 = [_]u8{0} ** 160,
    name_len: usize = 0,
    connected: bool = false,
    paired: bool = false,
    trusted: bool = false,

    pub fn addressText(self: *const DeviceState) []const u8 {
        return self.address[0..self.address_len];
    }

    pub fn nameText(self: *const DeviceState) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const DeviceList = struct {
    items: [10]DeviceState = [_]DeviceState{.{}} ** 10,
    count: usize = 0,
};

pub const State = struct {
    available: bool = false,
    powered: bool = false,
    discovering: bool = false,
    soft_blocked: bool = false,
    hard_blocked: bool = false,
    controller_name: [96]u8 = [_]u8{0} ** 96,
    controller_name_len: usize = 0,
    devices: DeviceList = .{},

    pub fn controllerName(self: *const State) []const u8 {
        return self.controller_name[0..self.controller_name_len];
    }
};

pub fn refresh(allocator: std.mem.Allocator, state: *State) bool {
    const next = loadState(allocator) catch State{};
    const changed = !stateEqual(state.*, next);
    state.* = next;
    return changed;
}

pub fn setPowered(allocator: std.mem.Allocator, enabled: bool) !void {
    if (enabled) {
        _ = runCommandNoOutput(allocator, &.{ "rfkill", "unblock", "bluetooth" }) catch {};
        try runCommandNoOutput(allocator, &.{ "bluetoothctl", "power", "on" });
    } else {
        try runCommandNoOutput(allocator, &.{ "bluetoothctl", "power", "off" });
    }
}

pub fn connectDevice(allocator: std.mem.Allocator, address: []const u8) !void {
    try runCommandNoOutput(allocator, &.{ "bluetoothctl", "connect", address });
}

pub fn disconnectDevice(allocator: std.mem.Allocator, address: []const u8) !void {
    try runCommandNoOutput(allocator, &.{ "bluetoothctl", "disconnect", address });
}

fn loadState(allocator: std.mem.Allocator) !State {
    const show_output = runCommand(allocator, &.{ "bluetoothctl", "show" }) catch return State{};
    defer allocator.free(show_output);

    var state = parseShow(show_output);
    if (!state.available) return state;

    const rfkill_output = runCommand(allocator, &.{ "rfkill", "list", "bluetooth" }) catch null;
    defer if (rfkill_output) |output| allocator.free(output);
    if (rfkill_output) |output| parseRfkill(output, &state);

    const devices_output = runCommand(allocator, &.{ "bluetoothctl", "devices" }) catch null;
    defer if (devices_output) |output| allocator.free(output);
    if (devices_output) |output| parseDevices(allocator, output, &state);

    return state;
}

fn parseShow(output: []const u8) State {
    var state = State{};
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    const first_line = lines.next() orelse return state;
    const trimmed_first = std.mem.trim(u8, first_line, " \r\t");
    if (!std.mem.startsWith(u8, trimmed_first, "Controller ")) return state;
    state.available = true;

    if (trimmed_first.len > "Controller ".len) {
        const rest = trimmed_first["Controller ".len..];
        if (std.mem.indexOfScalar(u8, rest, ' ')) |space| {
            state.controller_name_len = copyText(&state.controller_name, rest[space + 1 ..]);
        }
    }

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (std.mem.startsWith(u8, trimmed, "Powered: ")) {
            state.powered = std.mem.eql(u8, trimmed["Powered: ".len..], "yes");
        } else if (std.mem.startsWith(u8, trimmed, "Discovering: ")) {
            state.discovering = std.mem.eql(u8, trimmed["Discovering: ".len..], "yes");
        } else if (std.mem.startsWith(u8, trimmed, "Alias: ")) {
            state.controller_name_len = copyText(&state.controller_name, trimmed["Alias: ".len..]);
        }
    }
    return state;
}

fn parseRfkill(output: []const u8, state: *State) void {
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (std.mem.startsWith(u8, trimmed, "Soft blocked: ")) {
            state.soft_blocked = std.mem.eql(u8, trimmed["Soft blocked: ".len..], "yes");
        } else if (std.mem.startsWith(u8, trimmed, "Hard blocked: ")) {
            state.hard_blocked = std.mem.eql(u8, trimmed["Hard blocked: ".len..], "yes");
        }
    }
}

fn parseDevices(allocator: std.mem.Allocator, output: []const u8, state: *State) void {
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (state.devices.count >= state.devices.items.len) break;
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (!std.mem.startsWith(u8, trimmed, "Device ")) continue;

        const rest = trimmed["Device ".len..];
        if (rest.len < 18) continue;
        const space = std.mem.indexOfScalar(u8, rest, ' ') orelse continue;
        const address = rest[0..space];
        const name = std.mem.trimLeft(u8, rest[space + 1 ..], " ");

        var device = DeviceState{};
        device.address_len = copyText(&device.address, address);
        device.name_len = copyText(&device.name, name);

        const info_output = runCommand(allocator, &.{ "bluetoothctl", "info", device.addressText() }) catch null;
        defer if (info_output) |value| allocator.free(value);
        if (info_output) |value| parseDeviceInfo(value, &device);

        state.devices.items[state.devices.count] = device;
        state.devices.count += 1;
    }
}

fn parseDeviceInfo(output: []const u8, device: *DeviceState) void {
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (std.mem.startsWith(u8, trimmed, "Connected: ")) {
            device.connected = std.mem.eql(u8, trimmed["Connected: ".len..], "yes");
        } else if (std.mem.startsWith(u8, trimmed, "Paired: ")) {
            device.paired = std.mem.eql(u8, trimmed["Paired: ".len..], "yes");
        } else if (std.mem.startsWith(u8, trimmed, "Trusted: ")) {
            device.trusted = std.mem.eql(u8, trimmed["Trusted: ".len..], "yes");
        } else if (std.mem.startsWith(u8, trimmed, "Name: ")) {
            device.name_len = copyText(&device.name, trimmed["Name: ".len..]);
        }
    }
}

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 64 * 1024,
    });
    errdefer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
    return result.stdout;
}

fn runCommandNoOutput(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 8 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

fn stateEqual(a: State, b: State) bool {
    if (a.available != b.available or a.powered != b.powered or a.discovering != b.discovering or a.soft_blocked != b.soft_blocked or a.hard_blocked != b.hard_blocked) return false;
    if (!std.mem.eql(u8, a.controller_name[0..a.controller_name_len], b.controller_name[0..b.controller_name_len])) return false;
    if (a.devices.count != b.devices.count) return false;
    for (a.devices.items[0..a.devices.count], b.devices.items[0..b.devices.count]) |lhs, rhs| {
        if (!deviceEqual(lhs, rhs)) return false;
    }
    return true;
}

fn deviceEqual(a: DeviceState, b: DeviceState) bool {
    return a.connected == b.connected and
        a.paired == b.paired and
        a.trusted == b.trusted and
        std.mem.eql(u8, a.address[0..a.address_len], b.address[0..b.address_len]) and
        std.mem.eql(u8, a.name[0..a.name_len], b.name[0..b.name_len]);
}

fn copyText(dest: []u8, src: []const u8) usize {
    const len = @min(dest.len, src.len);
    @memcpy(dest[0..len], src[0..len]);
    return len;
}
