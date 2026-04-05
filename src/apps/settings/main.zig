const std = @import("std");
const settings_model = @import("settings_model");
const App = @import("app.zig").App;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) @panic("memory leak detected");
    }

    const page = parsePageArg();
    const app = try App.create(gpa.allocator(), page);
    defer app.destroy();
    try app.run();
}

fn parsePageArg() settings_model.Page {
    var args = std.process.args();
    _ = args.next();
    const raw = args.next() orelse return .wallpapers;

    if (std.mem.eql(u8, raw, "wallpapers") or std.mem.eql(u8, raw, "wallpaper")) return .wallpapers;
    if (std.mem.eql(u8, raw, "appearance") or std.mem.eql(u8, raw, "aparencia")) return .appearance;
    if (std.mem.eql(u8, raw, "panel")) return .panel;
    if (std.mem.eql(u8, raw, "displays") or std.mem.eql(u8, raw, "monitors")) return .displays;
    if (std.mem.eql(u8, raw, "workspaces")) return .workspaces;
    if (std.mem.eql(u8, raw, "network") or std.mem.eql(u8, raw, "rede")) return .network;
    if (std.mem.eql(u8, raw, "bluetooth")) return .bluetooth;
    if (std.mem.eql(u8, raw, "printers") or std.mem.eql(u8, raw, "impressoras")) return .printers;
    if (std.mem.eql(u8, raw, "about")) return .about;
    return .wallpapers;
}
