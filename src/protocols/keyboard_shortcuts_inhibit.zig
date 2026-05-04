const std = @import("std");
const c = @import("../wl.zig").c;

const log = std.log.scoped(.axia_shortcuts_inhibit);

const Entry = struct {
    owner: *Manager,
    inhibitor: [*c]c.struct_wlr_keyboard_shortcuts_inhibitor_v1,
    destroy: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),

    fn detach(self: *Entry) void {
        c.wl_list_remove(&self.destroy.link);
    }

    fn handleDestroy(listener: [*c]c.struct_wl_listener, _: ?*anyopaque) callconv(.c) void {
        const entry: *Entry = @ptrCast(@as(*allowzero Entry, @fieldParentPtr("destroy", listener)));
        entry.owner.unregisterEntry(entry);
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    seat: [*c]c.struct_wlr_seat,
    manager: [*c]c.struct_wlr_keyboard_shortcuts_inhibit_manager_v1,
    entries: std.ArrayListUnmanaged(*Entry) = .empty,
    active_inhibitor: ?[*c]c.struct_wlr_keyboard_shortcuts_inhibitor_v1 = null,
    new_inhibitor: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    listeners_ready: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        display: *c.struct_wl_display,
        seat: [*c]c.struct_wlr_seat,
    ) !Manager {
        const manager = c.wlr_keyboard_shortcuts_inhibit_v1_create(display);
        if (manager == null) return error.KeyboardShortcutsInhibitCreateFailed;

        return .{
            .allocator = allocator,
            .seat = seat,
            .manager = manager,
        };
    }

    pub fn setupListeners(self: *Manager) void {
        self.new_inhibitor.notify = handleNewInhibitor;
        c.wl_signal_add(&self.manager.*.events.new_inhibitor, &self.new_inhibitor);
        self.listeners_ready = true;
    }

    pub fn syncFocus(self: *Manager, focused_surface: ?[*c]c.struct_wlr_surface) void {
        const next_inhibitor = if (focused_surface) |surface|
            self.findInhibitor(surface)
        else
            null;

        if (self.active_inhibitor) |active_inhibitor| {
            if (next_inhibitor == null or next_inhibitor.? != active_inhibitor) {
                c.wlr_keyboard_shortcuts_inhibitor_v1_deactivate(active_inhibitor);
                self.active_inhibitor = null;
            }
        }

        if (next_inhibitor) |inhibitor| {
            if (self.active_inhibitor == null) {
                c.wlr_keyboard_shortcuts_inhibitor_v1_activate(inhibitor);
                self.active_inhibitor = inhibitor;
            }
        }
    }

    pub fn shortcutsInhibited(self: *const Manager) bool {
        return self.active_inhibitor != null;
    }

    pub fn deinit(self: *Manager) void {
        if (self.active_inhibitor) |inhibitor| {
            c.wlr_keyboard_shortcuts_inhibitor_v1_deactivate(inhibitor);
            self.active_inhibitor = null;
        }

        if (self.listeners_ready) {
            c.wl_list_remove(&self.new_inhibitor.link);
        }

        while (self.entries.items.len > 0) {
            const entry = self.entries.items[self.entries.items.len - 1];
            self.unregisterEntry(entry);
        }
    }

    fn registerInhibitor(self: *Manager, inhibitor: [*c]c.struct_wlr_keyboard_shortcuts_inhibitor_v1) !void {
        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);

        entry.* = .{
            .owner = self,
            .inhibitor = inhibitor,
        };
        entry.destroy.notify = Entry.handleDestroy;
        c.wl_signal_add(&inhibitor.*.events.destroy, &entry.destroy);

        try self.entries.append(self.allocator, entry);
    }

    fn unregisterEntry(self: *Manager, target: *Entry) void {
        if (self.active_inhibitor) |active_inhibitor| {
            if (active_inhibitor == target.inhibitor) {
                self.active_inhibitor = null;
            }
        }

        for (self.entries.items, 0..) |entry, index| {
            if (entry == target) {
                entry.detach();
                _ = self.entries.swapRemove(index);
                self.allocator.destroy(entry);
                return;
            }
        }
    }

    fn findInhibitor(self: *const Manager, surface: [*c]c.struct_wlr_surface) ?[*c]c.struct_wlr_keyboard_shortcuts_inhibitor_v1 {
        for (self.entries.items) |entry| {
            if (entry.inhibitor.*.seat != self.seat) continue;
            if (entry.inhibitor.*.surface == surface) return entry.inhibitor;
        }
        return null;
    }

    fn handleNewInhibitor(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const manager: *Manager = @ptrCast(@as(*allowzero Manager, @fieldParentPtr("new_inhibitor", listener)));
        const raw_inhibitor = data orelse return;
        const inhibitor: [*c]c.struct_wlr_keyboard_shortcuts_inhibitor_v1 = @ptrCast(@alignCast(raw_inhibitor));

        manager.registerInhibitor(inhibitor) catch |err| {
            log.err("failed to register shortcuts inhibitor: {}", .{err});
        };
    }
};
