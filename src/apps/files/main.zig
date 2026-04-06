const std = @import("std");
const App = @import("app.zig").App;
const Mode = @import("app.zig").Mode;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) @panic("memory leak detected");
    }

    var args = std.process.args();
    _ = args.next();

    var mode: Mode = .browser;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "pick-wallpaper")) {
            mode = .wallpaper_picker;
        }
    }

    const app = try App.create(gpa.allocator(), mode);
    defer app.destroy();
    try app.run();
}
