const std = @import("std");

pub const DeviceState = struct {
    id: u32 = 0,
    available: bool = false,
    volume: f64 = 0,
    muted: bool = false,
    description: [160]u8 = [_]u8{0} ** 160,
    description_len: usize = 0,

    pub fn descriptionText(self: *const DeviceState) []const u8 {
        return self.description[0..self.description_len];
    }

    pub fn percent(self: *const DeviceState) u8 {
        const clamped = std.math.clamp(self.volume, 0.0, 1.5);
        return @intFromFloat(@round(clamped * 100.0));
    }
};

pub const DeviceOption = struct {
    id: u32 = 0,
    current: bool = false,
    label: [160]u8 = [_]u8{0} ** 160,
    label_len: usize = 0,

    pub fn labelText(self: *const DeviceOption) []const u8 {
        return self.label[0..self.label_len];
    }
};

pub const DeviceList = struct {
    items: [8]DeviceOption = [_]DeviceOption{.{}} ** 8,
    count: usize = 0,
};

pub const State = struct {
    available: bool = false,
    sink: DeviceState = .{},
    source: DeviceState = .{},
    sinks: DeviceList = .{},
    sources: DeviceList = .{},
};

pub fn refresh(allocator: std.mem.Allocator, state: *State) bool {
    const next_sink = queryDevice(allocator, "@DEFAULT_AUDIO_SINK@") catch DeviceState{};
    const next_source = queryDevice(allocator, "@DEFAULT_AUDIO_SOURCE@") catch DeviceState{};
    const status_output = runCommand(allocator, &.{ "wpctl", "status" }) catch null;
    defer if (status_output) |output| allocator.free(output);
    const next = State{
        .available = next_sink.available or next_source.available,
        .sink = next_sink,
        .source = next_source,
        .sinks = if (status_output) |output| parseDeviceList(output, "Sinks:", next_sink.id) else .{},
        .sources = if (status_output) |output| parseDeviceList(output, "Sources:", next_source.id) else .{},
    };
    const changed = !stateEqual(state.*, next);
    state.* = next;
    return changed;
}

pub fn setSinkVolume(allocator: std.mem.Allocator, volume: f64) !void {
    try setVolume(allocator, "@DEFAULT_AUDIO_SINK@", volume);
}

pub fn setSourceVolume(allocator: std.mem.Allocator, volume: f64) !void {
    try setVolume(allocator, "@DEFAULT_AUDIO_SOURCE@", volume);
}

pub fn toggleSinkMute(allocator: std.mem.Allocator) !void {
    try toggleMute(allocator, "@DEFAULT_AUDIO_SINK@");
}

pub fn toggleSourceMute(allocator: std.mem.Allocator) !void {
    try toggleMute(allocator, "@DEFAULT_AUDIO_SOURCE@");
}

pub fn setDefaultSink(allocator: std.mem.Allocator, id: u32) !void {
    try setDefault(allocator, id);
}

pub fn setDefaultSource(allocator: std.mem.Allocator, id: u32) !void {
    try setDefault(allocator, id);
}

fn queryDevice(allocator: std.mem.Allocator, target: []const u8) !DeviceState {
    const volume_output = try runCommand(allocator, &.{ "wpctl", "get-volume", target });
    defer allocator.free(volume_output);

    const inspect_output = try runCommand(allocator, &.{ "wpctl", "inspect", target });
    defer allocator.free(inspect_output);

    var state = parseVolume(volume_output);
    state.available = true;
    state.id = parseId(inspect_output);
    state.description_len = parseDescription(&state.description, inspect_output);
    return state;
}

fn parseVolume(output: []const u8) DeviceState {
    var state = DeviceState{};
    const trimmed = std.mem.trim(u8, output, " \r\n\t");
    if (trimmed.len == 0) return state;

    var parts = std.mem.tokenizeAny(u8, trimmed, " \t");
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "Volume:")) continue;
        if (std.mem.eql(u8, part, "[MUTED]")) {
            state.muted = true;
            continue;
        }
        state.volume = std.fmt.parseFloat(f64, part) catch state.volume;
    }
    return state;
}

fn parseDescription(buffer: []u8, output: []const u8) usize {
    var fallback: []const u8 = "Dispositivo de audio";
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (std.mem.indexOf(u8, trimmed, "node.description = \"")) |index| {
            const value = trimmed[index + "node.description = \"".len ..];
            if (std.mem.indexOfScalar(u8, value, '"')) |end| {
                return copyText(buffer, value[0..end]);
            }
        }
        if (std.mem.indexOf(u8, trimmed, "device.profile.description = \"")) |index| {
            const value = trimmed[index + "device.profile.description = \"".len ..];
            if (std.mem.indexOfScalar(u8, value, '"')) |end| {
                fallback = value[0..end];
            }
        }
    }
    return copyText(buffer, fallback);
}

fn parseDeviceList(output: []const u8, section_name: []const u8, current_id: u32) DeviceList {
    var list = DeviceList{};
    var in_audio = false;
    var in_section = false;

    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t│├─└");
        if (trimmed.len == 0) continue;

        if (std.mem.eql(u8, trimmed, "Audio")) {
            in_audio = true;
            in_section = false;
            continue;
        }
        if (!in_audio) continue;
        if (std.mem.eql(u8, trimmed, "Video")) break;

        if (std.mem.eql(u8, trimmed, section_name)) {
            in_section = true;
            continue;
        }
        if (!in_section) continue;
        if (std.mem.endsWith(u8, trimmed, ":")) break;
        if (trimmed[0] == '├' or trimmed[0] == '└') break;

        if (list.count >= list.items.len) break;
        if (parseDeviceOption(trimmed, current_id)) |item| {
            list.items[list.count] = item;
            list.count += 1;
        }
    }
    return list;
}

fn parseDeviceOption(line: []const u8, current_id: u32) ?DeviceOption {
    var text = std.mem.trim(u8, line, " ");
    var current = false;
    if (text.len > 0 and text[0] == '*') {
        current = true;
        text = std.mem.trimLeft(u8, text[1..], " ");
    }

    const dot_index = std.mem.indexOfScalar(u8, text, '.') orelse return null;
    const id_text = std.mem.trim(u8, text[0..dot_index], " ");
    const id = std.fmt.parseInt(u32, id_text, 10) catch return null;
    var rest = std.mem.trimLeft(u8, text[dot_index + 1 ..], " ");
    if (rest.len == 0) return null;

    var end = rest.len;
    if (std.mem.indexOf(u8, rest, "[vol:")) |index| end = index;
    rest = std.mem.trimRight(u8, rest[0..end], " ");

    var item = DeviceOption{
        .id = id,
        .current = current or id == current_id,
    };
    item.label_len = copyText(&item.label, rest);
    return item;
}

fn parseId(output: []const u8) u32 {
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    const first_line = lines.next() orelse return 0;
    const trimmed = std.mem.trim(u8, first_line, " \r\t");
    if (!std.mem.startsWith(u8, trimmed, "id ")) return 0;
    const comma = std.mem.indexOfScalar(u8, trimmed, ',') orelse return 0;
    return std.fmt.parseInt(u32, trimmed[3..comma], 10) catch 0;
}

fn setVolume(allocator: std.mem.Allocator, target: []const u8, volume: f64) !void {
    const value = try std.fmt.allocPrint(allocator, "{d:.2}", .{std.math.clamp(volume, 0.0, 1.5)});
    defer allocator.free(value);
    try runCommandNoOutput(allocator, &.{ "wpctl", "set-volume", target, value });
}

fn toggleMute(allocator: std.mem.Allocator, target: []const u8) !void {
    try runCommandNoOutput(allocator, &.{ "wpctl", "set-mute", target, "toggle" });
}

fn setDefault(allocator: std.mem.Allocator, id: u32) !void {
    const value = try std.fmt.allocPrint(allocator, "{d}", .{id});
    defer allocator.free(value);
    try runCommandNoOutput(allocator, &.{ "wpctl", "set-default", value });
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
    return a.available == b.available and
        deviceEqual(a.sink, b.sink) and
        deviceEqual(a.source, b.source) and
        listEqual(a.sinks, b.sinks) and
        listEqual(a.sources, b.sources);
}

fn deviceEqual(a: DeviceState, b: DeviceState) bool {
    return a.id == b.id and
        a.available == b.available and
        a.muted == b.muted and
        std.math.approxEqAbs(f64, a.volume, b.volume, 0.0001) and
        std.mem.eql(u8, a.description[0..a.description_len], b.description[0..b.description_len]);
}

fn listEqual(a: DeviceList, b: DeviceList) bool {
    if (a.count != b.count) return false;
    for (a.items[0..a.count], b.items[0..b.count]) |lhs, rhs| {
        if (lhs.id != rhs.id or lhs.current != rhs.current) return false;
        if (!std.mem.eql(u8, lhs.label[0..lhs.label_len], rhs.label[0..rhs.label_len])) return false;
    }
    return true;
}

fn copyText(dest: []u8, src: []const u8) usize {
    const len = @min(dest.len, src.len);
    @memcpy(dest[0..len], src[0..len]);
    return len;
}
