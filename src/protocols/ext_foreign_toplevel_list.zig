const std = @import("std");
const c = @import("../wl.zig").c;
const View = @import("../shell/view.zig").View;

const log = std.log.scoped(.axia_ext_foreign_toplevel_list);

const Entry = struct {
    owner: *Manager,
    view: *View,
    handle: [*c]c.struct_wlr_ext_foreign_toplevel_handle_v1,
    destroying: bool = false,
    destroy: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),

    fn detach(self: *Entry) void {
        c.wl_list_remove(&self.destroy.link);
    }

    fn handleDestroy(listener: [*c]c.struct_wl_listener, _: ?*anyopaque) callconv(.c) void {
        const entry: *Entry = @ptrCast(@as(*allowzero Entry, @fieldParentPtr("destroy", listener)));
        if (entry.destroying) return;
        entry.owner.releaseEntry(entry);
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    list: [*c]c.struct_wlr_ext_foreign_toplevel_list_v1,
    entries: std.ArrayListUnmanaged(*Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator, display: *c.struct_wl_display) !Manager {
        const list = c.wlr_ext_foreign_toplevel_list_v1_create(display, 1);
        if (list == null) return error.ExtForeignToplevelListCreateFailed;

        return .{
            .allocator = allocator,
            .list = list,
        };
    }

    pub fn registerView(self: *Manager, view: *View) !void {
        if (!view.isForeignToplevelCandidate()) return;
        if (self.findEntry(view) != null) {
            self.syncView(view);
            return;
        }

        const initial_state = c.struct_wlr_ext_foreign_toplevel_handle_v1_state{
            .title = viewTitle(view).ptr,
            .app_id = viewAppId(view).ptr,
        };
        const handle = c.wlr_ext_foreign_toplevel_handle_v1_create(self.list, &initial_state);
        if (handle == null) return error.ExtForeignToplevelHandleCreateFailed;

        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);

        entry.* = .{
            .owner = self,
            .view = view,
            .handle = handle,
        };
        entry.destroy.notify = Entry.handleDestroy;
        c.wl_signal_add(&handle.*.events.destroy, &entry.destroy);

        try self.entries.append(self.allocator, entry);
        self.syncEntry(entry);
    }

    pub fn syncView(self: *Manager, view: *View) void {
        if (!view.isForeignToplevelCandidate()) return;
        const entry = self.findEntry(view) orelse {
            self.registerView(view) catch |err| {
                log.err("failed to register ext-foreign-toplevel entry: {}", .{err});
            };
            return;
        };
        self.syncEntry(entry);
    }

    pub fn unregisterView(self: *Manager, view: *View) void {
        if (self.findEntry(view)) |entry| {
            self.destroyEntry(entry);
        }
    }

    pub fn deinit(self: *Manager) void {
        while (self.entries.items.len > 0) {
            const entry = self.entries.items[self.entries.items.len - 1];
            self.destroyEntry(entry);
        }
        self.entries.deinit(self.allocator);
    }

    fn findEntry(self: *Manager, view: *View) ?*Entry {
        for (self.entries.items) |entry| {
            if (entry.view == view) return entry;
        }
        return null;
    }

    fn syncEntry(self: *Manager, entry: *Entry) void {
        _ = self;
        const state = c.struct_wlr_ext_foreign_toplevel_handle_v1_state{
            .title = viewTitle(entry.view).ptr,
            .app_id = viewAppId(entry.view).ptr,
        };
        c.wlr_ext_foreign_toplevel_handle_v1_update_state(entry.handle, &state);
    }

    fn releaseEntry(self: *Manager, target: *Entry) void {
        for (self.entries.items, 0..) |entry, index| {
            if (entry == target) {
                entry.detach();
                _ = self.entries.swapRemove(index);
                self.allocator.destroy(entry);
                return;
            }
        }
    }

    fn destroyEntry(self: *Manager, entry: *Entry) void {
        entry.destroying = true;
        entry.detach();
        for (self.entries.items, 0..) |current, index| {
            if (current == entry) {
                _ = self.entries.swapRemove(index);
                break;
            }
        }
        c.wlr_ext_foreign_toplevel_handle_v1_destroy(entry.handle);
        self.allocator.destroy(entry);
    }
};

fn viewTitle(view: *View) [:0]const u8 {
    const title: [*:0]const u8 = if (view.toplevel.*.title) |raw_title|
        @ptrCast(raw_title)
    else
        "untitled";
    return std.mem.span(title);
}

fn viewAppId(view: *View) [:0]const u8 {
    const app_id: [*:0]const u8 = if (view.toplevel.*.app_id) |raw_app_id|
        @ptrCast(raw_app_id)
    else
        "unknown";
    return std.mem.span(app_id);
}
