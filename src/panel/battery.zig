const std = @import("std");

pub const State = struct {
    available: bool = false,
    charging: bool = false,
    percentage: u8 = 0,
    time_label: [64]u8 = [_]u8{0} ** 64,
    time_label_len: usize = 0,
    status_label: [48]u8 = [_]u8{0} ** 48,
    status_label_len: usize = 0,

    pub fn timeText(self: *const State) []const u8 {
        return self.time_label[0..self.time_label_len];
    }

    pub fn statusText(self: *const State) []const u8 {
        return self.status_label[0..self.status_label_len];
    }
};

pub fn refresh(allocator: std.mem.Allocator, state: *State) bool {
    const next = loadState(allocator) catch State{};
    const changed = !stateEqual(state.*, next);
    state.* = next;
    return changed;
}

fn loadState(allocator: std.mem.Allocator) !State {
    const output = try runCommand(allocator, &.{ "upower", "-i", "/org/freedesktop/UPower/devices/DisplayDevice" });
    defer allocator.free(output);

    var state = State{};
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    var has_battery_section = false;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (std.mem.eql(u8, trimmed, "battery")) {
            has_battery_section = true;
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "present: ")) {
            state.available = std.mem.eql(u8, trimmed["present: ".len..], "yes");
        } else if (std.mem.startsWith(u8, trimmed, "state: ")) {
            const value = trimmed["state: ".len..];
            state.charging = std.mem.eql(u8, value, "charging") or std.mem.eql(u8, value, "fully-charged");
            state.status_label_len = copyText(&state.status_label, value);
        } else if (std.mem.startsWith(u8, trimmed, "percentage: ")) {
            const value = trimmed["percentage: ".len..];
            const percent_text = std.mem.trimRight(u8, value, "%");
            state.percentage = std.fmt.parseInt(u8, percent_text, 10) catch 0;
        } else if (std.mem.startsWith(u8, trimmed, "time to empty: ")) {
            state.time_label_len = copyText(&state.time_label, trimmed["time to empty: ".len..]);
        } else if (std.mem.startsWith(u8, trimmed, "time to full: ")) {
            state.time_label_len = copyText(&state.time_label, trimmed["time to full: ".len..]);
        }
    }

    state.available = state.available and has_battery_section;
    return state;
}

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 32 * 1024,
    });
    errdefer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
    return result.stdout;
}

fn stateEqual(a: State, b: State) bool {
    return a.available == b.available and
        a.charging == b.charging and
        a.percentage == b.percentage and
        std.mem.eql(u8, a.time_label[0..a.time_label_len], b.time_label[0..b.time_label_len]) and
        std.mem.eql(u8, a.status_label[0..a.status_label_len], b.status_label[0..b.status_label_len]);
}

fn copyText(dest: []u8, src: []const u8) usize {
    const len = @min(dest.len, src.len);
    @memcpy(dest[0..len], src[0..len]);
    return len;
}
