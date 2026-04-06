const std = @import("std");
const c = @import("wl.zig").c;

pub const DateTime = struct {
    tm: c.struct_tm,

    pub fn now() DateTime {
        var raw: c.time_t = undefined;
        _ = c.time(&raw);

        var local_tm: c.struct_tm = undefined;
        _ = c.localtime_r(&raw, &local_tm);
        return .{ .tm = local_tm };
    }

    pub fn year(self: *const DateTime) i32 {
        return self.tm.tm_year + 1900;
    }

    pub fn month(self: *const DateTime) u8 {
        return @intCast(self.tm.tm_mon + 1);
    }

    pub fn day(self: *const DateTime) u8 {
        return @intCast(self.tm.tm_mday);
    }

    pub fn minuteStamp(self: *const DateTime) i64 {
        return @as(i64, self.year()) * 100000 + @as(i64, self.month()) * 1000 + @as(i64, self.day()) * 10 + self.tm.tm_hour * 60 + self.tm.tm_min;
    }
};

pub const MonthCursor = struct {
    year: i32,
    month: u8,

    pub fn initNow() MonthCursor {
        const now = DateTime.now();
        return .{
            .year = now.year(),
            .month = now.month(),
        };
    }

    pub fn previous(self: *MonthCursor) void {
        if (self.month == 1) {
            self.month = 12;
            self.year -= 1;
        } else {
            self.month -= 1;
        }
    }

    pub fn next(self: *MonthCursor) void {
        if (self.month == 12) {
            self.month = 1;
            self.year += 1;
        } else {
            self.month += 1;
        }
    }
};

pub const DayCell = struct {
    day: u8,
    in_current_month: bool,
    is_today: bool,
};

pub const MonthGrid = struct {
    cells: [42]DayCell,
};

pub fn buildMonthGrid(cursor: MonthCursor, today: DateTime) MonthGrid {
    const first_weekday = weekdayOf(cursor.year, cursor.month, 1);
    const days_in_month = daysInMonth(cursor.year, cursor.month);

    var prev_cursor = cursor;
    prev_cursor.previous();
    const prev_days = daysInMonth(prev_cursor.year, prev_cursor.month);

    var cells: [42]DayCell = undefined;
    for (&cells, 0..) |*cell, index| {
        if (index < first_weekday) {
            const day = prev_days - @as(u8, @intCast(first_weekday - index - 1));
            cell.* = .{
                .day = day,
                .in_current_month = false,
                .is_today = false,
            };
            continue;
        }

        const current_index = index - first_weekday;
        if (current_index < days_in_month) {
            const day: u8 = @intCast(current_index + 1);
            cell.* = .{
                .day = day,
                .in_current_month = true,
                .is_today = cursor.year == today.year() and cursor.month == today.month() and day == today.day(),
            };
            continue;
        }

        const next_day: u8 = @intCast(current_index - days_in_month + 1);
        cell.* = .{
            .day = next_day,
            .in_current_month = false,
            .is_today = false,
        };
    }

    return .{ .cells = cells };
}

pub fn shortTimestamp(buffer: []u8, now: DateTime) []const u8 {
    return formatTimestamp(buffer, now, true, false);
}

pub fn formatTimestamp(buffer: []u8, now: DateTime, show_date: bool, show_seconds: bool) []const u8 {
    if (show_date and show_seconds) {
        return std.fmt.bufPrint(buffer, "{d} de {s}., {d:0>2}:{d:0>2}:{d:0>2}", .{
            now.day(),
            monthShort(now.month()),
            @as(u8, @intCast(now.tm.tm_hour)),
            @as(u8, @intCast(now.tm.tm_min)),
            @as(u8, @intCast(now.tm.tm_sec)),
        }) catch "Axia";
    }
    if (show_date) {
        return std.fmt.bufPrint(buffer, "{d} de {s}., {d:0>2}:{d:0>2}", .{
            now.day(),
            monthShort(now.month()),
            @as(u8, @intCast(now.tm.tm_hour)),
            @as(u8, @intCast(now.tm.tm_min)),
        }) catch "Axia";
    }
    if (show_seconds) {
        return std.fmt.bufPrint(buffer, "{d:0>2}:{d:0>2}:{d:0>2}", .{
            @as(u8, @intCast(now.tm.tm_hour)),
            @as(u8, @intCast(now.tm.tm_min)),
            @as(u8, @intCast(now.tm.tm_sec)),
        }) catch "Axia";
    }
    return std.fmt.bufPrint(buffer, "{d:0>2}:{d:0>2}", .{
        @as(u8, @intCast(now.tm.tm_hour)),
        @as(u8, @intCast(now.tm.tm_min)),
    }) catch "Axia";
}

pub fn longDate(buffer: []u8, cursor: MonthCursor, selected_day: u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{d} de {s} de {d}", .{
        selected_day,
        monthLong(cursor.month),
        cursor.year,
    }) catch "Data";
}

pub fn weekdayLong(day_index: usize) []const u8 {
    return switch (day_index) {
        0 => "domingo",
        1 => "segunda-feira",
        2 => "terca-feira",
        3 => "quarta-feira",
        4 => "quinta-feira",
        5 => "sexta-feira",
        6 => "sabado",
        else => "dia",
    };
}

pub fn weekdayShort(index: usize) []const u8 {
    return switch (index) {
        0 => "dom.",
        1 => "seg.",
        2 => "ter.",
        3 => "qua.",
        4 => "qui.",
        5 => "sex.",
        6 => "sab.",
        else => "",
    };
}

pub fn monthShort(month: u8) []const u8 {
    return switch (month) {
        1 => "jan",
        2 => "fev",
        3 => "mar",
        4 => "abr",
        5 => "mai",
        6 => "jun",
        7 => "jul",
        8 => "ago",
        9 => "set",
        10 => "out",
        11 => "nov",
        12 => "dez",
        else => "mes",
    };
}

pub fn monthLong(month: u8) []const u8 {
    return switch (month) {
        1 => "janeiro",
        2 => "fevereiro",
        3 => "marco",
        4 => "abril",
        5 => "maio",
        6 => "junho",
        7 => "julho",
        8 => "agosto",
        9 => "setembro",
        10 => "outubro",
        11 => "novembro",
        12 => "dezembro",
        else => "mes",
    };
}

pub fn weekdayOf(year: i32, month: u8, day: u8) usize {
    var t = std.mem.zeroes(c.struct_tm);
    t.tm_year = year - 1900;
    t.tm_mon = month - 1;
    t.tm_mday = day;
    _ = c.mktime(&t);
    return @intCast(t.tm_wday);
}

pub fn daysInMonth(year: i32, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 30,
    };
}

fn isLeapYear(year: i32) bool {
    if (@mod(year, 400) == 0) return true;
    if (@mod(year, 100) == 0) return false;
    return @mod(year, 4) == 0;
}
