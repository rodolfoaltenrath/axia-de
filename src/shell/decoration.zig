const std = @import("std");
const c = @import("../wl.zig").c;

pub const DecorationManager = struct {
    allocator: std.mem.Allocator,
    manager: [*c]c.struct_wlr_xdg_decoration_manager_v1,
    decorations: std.ArrayListUnmanaged(*Decoration) = .empty,
    new_toplevel_decoration: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    listeners_ready: bool = false,

    pub fn init(allocator: std.mem.Allocator, display: *c.struct_wl_display) !DecorationManager {
        const manager = c.wlr_xdg_decoration_manager_v1_create(display);
        if (manager == null) return error.XdgDecorationManagerCreateFailed;

        return .{
            .allocator = allocator,
            .manager = manager,
        };
    }

    pub fn setupListeners(self: *DecorationManager) void {
        self.new_toplevel_decoration.notify = handleNewToplevelDecoration;
        c.wl_signal_add(&self.manager.*.events.new_toplevel_decoration, &self.new_toplevel_decoration);
        self.listeners_ready = true;
    }

    pub fn deinit(self: *DecorationManager) void {
        if (self.listeners_ready) {
            c.wl_list_remove(&self.new_toplevel_decoration.link);
        }

        for (self.decorations.items) |decoration| {
            decoration.detach();
            self.allocator.destroy(decoration);
        }
        self.decorations.deinit(self.allocator);
    }

    fn registerDecoration(self: *DecorationManager, decoration_ptr: [*c]c.struct_wlr_xdg_toplevel_decoration_v1) !void {
        const decoration = try self.allocator.create(Decoration);
        errdefer self.allocator.destroy(decoration);

        decoration.* = .{
            .owner = self,
            .decoration = decoration_ptr,
        };

        decoration.request_mode.notify = Decoration.handleRequestMode;
        decoration.commit.notify = Decoration.handleCommit;
        decoration.destroy.notify = Decoration.handleDestroy;

        c.wl_signal_add(&decoration_ptr.*.events.request_mode, &decoration.request_mode);
        c.wl_signal_add(&decoration_ptr.*.toplevel.*.base.*.surface.*.events.commit, &decoration.commit);
        c.wl_signal_add(&decoration_ptr.*.events.destroy, &decoration.destroy);

        try self.decorations.append(self.allocator, decoration);
        decoration.applyPreferredMode();
    }

    fn unregisterDecoration(self: *DecorationManager, target: *Decoration) void {
        for (self.decorations.items, 0..) |decoration, index| {
            if (decoration == target) {
                _ = self.decorations.swapRemove(index);
                return;
            }
        }
    }

    fn handleNewToplevelDecoration(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const manager: *DecorationManager = @ptrCast(@as(*allowzero DecorationManager, @fieldParentPtr("new_toplevel_decoration", listener)));
        const raw = data orelse return;
        const decoration: [*c]c.struct_wlr_xdg_toplevel_decoration_v1 = @ptrCast(@alignCast(raw));
        manager.registerDecoration(decoration) catch {};
    }
};

const Decoration = struct {
    owner: *DecorationManager,
    decoration: [*c]c.struct_wlr_xdg_toplevel_decoration_v1,
    request_mode: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    commit: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    destroy: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    applied_mode: ?u32 = null,

    fn detach(self: *Decoration) void {
        c.wl_list_remove(&self.request_mode.link);
        c.wl_list_remove(&self.commit.link);
        c.wl_list_remove(&self.destroy.link);
    }

    fn handleRequestMode(listener: [*c]c.struct_wl_listener, _: ?*anyopaque) callconv(.c) void {
        const decoration: *Decoration = @ptrCast(@as(*allowzero Decoration, @fieldParentPtr("request_mode", listener)));
        decoration.applyPreferredMode();
    }

    fn handleCommit(listener: [*c]c.struct_wl_listener, _: ?*anyopaque) callconv(.c) void {
        const decoration: *Decoration = @ptrCast(@as(*allowzero Decoration, @fieldParentPtr("commit", listener)));
        decoration.applyPreferredMode();
    }

    fn handleDestroy(listener: [*c]c.struct_wl_listener, _: ?*anyopaque) callconv(.c) void {
        const decoration: *Decoration = @ptrCast(@as(*allowzero Decoration, @fieldParentPtr("destroy", listener)));
        decoration.detach();
        decoration.owner.unregisterDecoration(decoration);
        decoration.owner.allocator.destroy(decoration);
    }

    fn applyPreferredMode(self: *Decoration) void {
        if (!self.decoration.*.toplevel.*.base.*.initialized) return;

        const toplevel = self.decoration.*.toplevel;
        const app_id = if (toplevel.*.app_id != null) std.mem.span(toplevel.*.app_id) else "";
        const preferred_mode: u32 = if (app_id.len > 0 and std.mem.startsWith(u8, app_id, "axia-"))
            c.WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE
        else
            c.WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE;

        if (self.applied_mode != null and self.applied_mode.? == preferred_mode) return;

        _ = c.wlr_xdg_toplevel_decoration_v1_set_mode(self.decoration, preferred_mode);
        self.applied_mode = preferred_mode;
    }
};
