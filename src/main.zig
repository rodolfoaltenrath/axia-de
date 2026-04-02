const std = @import("std");
const Server = @import("core/server.zig").Server;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) @panic("memory leak detected");
    }

    var server = try Server.init(gpa.allocator());
    defer server.deinit();

    server.setupListeners();
    try server.run();
}
