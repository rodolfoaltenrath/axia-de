const std = @import("std");

pub const NetworkItem = struct {
    active: bool = false,
    ssid: [96]u8 = [_]u8{0} ** 96,
    ssid_len: usize = 0,
    signal: u8 = 0,
    secure: bool = false,

    pub fn ssidText(self: *const NetworkItem) []const u8 {
        return self.ssid[0..self.ssid_len];
    }
};

pub const NetworkList = struct {
    items: [12]NetworkItem = [_]NetworkItem{.{}} ** 12,
    count: usize = 0,
};

pub const State = struct {
    available: bool = false,
    wifi_supported: bool = false,
    wifi_enabled: bool = false,
    wifi_connected: bool = false,
    ethernet_available: bool = false,
    ethernet_connected: bool = false,
    wifi_device: [32]u8 = [_]u8{0} ** 32,
    wifi_device_len: usize = 0,
    active_connection: [96]u8 = [_]u8{0} ** 96,
    active_connection_len: usize = 0,
    ethernet_connection: [96]u8 = [_]u8{0} ** 96,
    ethernet_connection_len: usize = 0,
    networks: NetworkList = .{},

    pub fn activeConnection(self: *const State) []const u8 {
        return self.active_connection[0..self.active_connection_len];
    }

    pub fn ethernetConnection(self: *const State) []const u8 {
        return self.ethernet_connection[0..self.ethernet_connection_len];
    }

    pub fn wifiDevice(self: *const State) []const u8 {
        return self.wifi_device[0..self.wifi_device_len];
    }
};

pub fn refresh(allocator: std.mem.Allocator, state: *State) bool {
    const next = loadState(allocator) catch State{};
    const changed = !stateEqual(state.*, next);
    state.* = next;
    return changed;
}

pub fn setWifiEnabled(allocator: std.mem.Allocator, enabled: bool) !void {
    try runCommandNoOutput(allocator, &.{ "nmcli", "radio", "wifi", if (enabled) "on" else "off" });
}

pub fn connectWifi(allocator: std.mem.Allocator, device: []const u8, ssid: []const u8) !void {
    if (device.len == 0 or ssid.len == 0) return error.InvalidDevice;
    try runCommandNoOutput(allocator, &.{ "nmcli", "device", "wifi", "connect", ssid, "ifname", device });
}

fn loadState(allocator: std.mem.Allocator) !State {
    const general_output = runCommand(allocator, &.{ "nmcli", "-t", "-f", "STATE,CONNECTIVITY,WIFI-HW,WIFI", "general", "status" }) catch return State{};
    defer allocator.free(general_output);

    const device_output = runCommand(allocator, &.{ "nmcli", "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "device", "status" }) catch return State{};
    defer allocator.free(device_output);

    var state = parseGeneral(general_output);
    parseDevices(device_output, &state);

    if (state.wifi_device_len > 0 and state.wifi_enabled) {
        const wifi_output = runCommand(allocator, &.{ "nmcli", "-t", "-f", "ACTIVE,SSID,SIGNAL,SECURITY", "device", "wifi", "list", "ifname", state.wifiDevice(), "--rescan", "no" }) catch null;
        defer if (wifi_output) |output| allocator.free(output);
        if (wifi_output) |output| {
            state.networks = parseWifiList(output);
        }
    }

    return state;
}

fn parseGeneral(output: []const u8) State {
    var state = State{};
    const trimmed = std.mem.trim(u8, output, " \r\n\t");
    if (trimmed.len == 0) return state;

    var parts = std.mem.splitScalar(u8, trimmed, ':');
    _ = parts.next();
    _ = parts.next();
    const wifi_hw = parts.next() orelse "";
    const wifi = parts.next() orelse "";

    state.available = true;
    state.wifi_supported = !std.mem.eql(u8, wifi_hw, "missing");
    state.wifi_enabled = std.mem.eql(u8, wifi, "enabled");
    return state;
}

fn parseDevices(output: []const u8, state: *State) void {
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;

        var parts = std.mem.splitScalar(u8, trimmed, ':');
        const device = parts.next() orelse continue;
        const dev_type = parts.next() orelse continue;
        const dev_state = parts.next() orelse "";
        const connection = parts.next() orelse "";

        if (std.mem.eql(u8, dev_type, "wifi") and !std.mem.startsWith(u8, device, "p2p-")) {
            state.wifi_device_len = copyText(&state.wifi_device, device);
            state.wifi_connected = std.mem.eql(u8, dev_state, "connected");
            if (state.wifi_connected) {
                state.active_connection_len = copyText(&state.active_connection, connection);
            }
        } else if (std.mem.eql(u8, dev_type, "ethernet")) {
            state.ethernet_available = true;
            state.ethernet_connected = std.mem.eql(u8, dev_state, "connected");
            if (state.ethernet_connected) {
                state.ethernet_connection_len = copyText(&state.ethernet_connection, connection);
            }
        }
    }
}

fn parseWifiList(output: []const u8) NetworkList {
    var list = NetworkList{};
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (list.count >= list.items.len) break;
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;

        var parts = std.mem.splitScalar(u8, trimmed, ':');
        const active = parts.next() orelse "no";
        const ssid = parts.next() orelse "";
        const signal_text = parts.next() orelse "0";
        const security = parts.next() orelse "";

        if (ssid.len == 0) continue;

        var item = NetworkItem{};
        item.active = std.mem.eql(u8, active, "yes");
        item.ssid_len = copyText(&item.ssid, ssid);
        item.signal = std.fmt.parseInt(u8, signal_text, 10) catch 0;
        item.secure = security.len > 0 and !std.mem.eql(u8, security, "--");
        list.items[list.count] = item;
        list.count += 1;
    }
    return list;
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
    if (a.available != b.available or
        a.wifi_supported != b.wifi_supported or
        a.wifi_enabled != b.wifi_enabled or
        a.wifi_connected != b.wifi_connected or
        a.ethernet_available != b.ethernet_available or
        a.ethernet_connected != b.ethernet_connected)
    {
        return false;
    }
    if (!std.mem.eql(u8, a.wifi_device[0..a.wifi_device_len], b.wifi_device[0..b.wifi_device_len])) return false;
    if (!std.mem.eql(u8, a.active_connection[0..a.active_connection_len], b.active_connection[0..b.active_connection_len])) return false;
    if (!std.mem.eql(u8, a.ethernet_connection[0..a.ethernet_connection_len], b.ethernet_connection[0..b.ethernet_connection_len])) return false;
    if (a.networks.count != b.networks.count) return false;
    for (a.networks.items[0..a.networks.count], b.networks.items[0..b.networks.count]) |lhs, rhs| {
        if (lhs.active != rhs.active or lhs.signal != rhs.signal or lhs.secure != rhs.secure) return false;
        if (!std.mem.eql(u8, lhs.ssid[0..lhs.ssid_len], rhs.ssid[0..rhs.ssid_len])) return false;
    }
    return true;
}

fn copyText(dest: []u8, src: []const u8) usize {
    const len = @min(dest.len, src.len);
    @memcpy(dest[0..len], src[0..len]);
    return len;
}
