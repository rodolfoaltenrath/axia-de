const std = @import("std");
const c = @import("../wl.zig").c;

const log = std.log.scoped(.axia_idle_inhibit);

const Entry = struct {
    owner: *Manager,
    inhibitor: [*c]c.struct_wlr_idle_inhibitor_v1,
    surface: [*c]c.struct_wlr_surface,
    destroy: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    surface_destroy: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    surface_commit: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),

    fn detach(self: *Entry) void {
        c.wl_list_remove(&self.surface_commit.link);
        c.wl_list_remove(&self.surface_destroy.link);
        c.wl_list_remove(&self.destroy.link);
    }

    fn handleDestroy(listener: [*c]c.struct_wl_listener, _: ?*anyopaque) callconv(.c) void {
        const entry: *Entry = @ptrCast(@as(*allowzero Entry, @fieldParentPtr("destroy", listener)));
        entry.owner.unregisterEntry(entry);
    }

    fn handleSurfaceDestroy(listener: [*c]c.struct_wl_listener, _: ?*anyopaque) callconv(.c) void {
        const entry: *Entry = @ptrCast(@as(*allowzero Entry, @fieldParentPtr("surface_destroy", listener)));
        entry.owner.unregisterEntry(entry);
    }

    fn handleSurfaceCommit(listener: [*c]c.struct_wl_listener, _: ?*anyopaque) callconv(.c) void {
        const entry: *Entry = @ptrCast(@as(*allowzero Entry, @fieldParentPtr("surface_commit", listener)));
        entry.owner.refreshInhibition();
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    manager: [*c]c.struct_wlr_idle_inhibit_manager_v1,
    idle_notifier: [*c]c.struct_wlr_idle_notifier_v1,
    entries: std.ArrayListUnmanaged(*Entry) = .empty,
    new_inhibitor: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    listeners_ready: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        display: *c.struct_wl_display,
        idle_notifier: [*c]c.struct_wlr_idle_notifier_v1,
    ) !Manager {
        const manager = c.wlr_idle_inhibit_v1_create(display);
        if (manager == null) return error.IdleInhibitCreateFailed;

        return .{
            .allocator = allocator,
            .manager = manager,
            .idle_notifier = idle_notifier,
        };
    }

    pub fn setupListeners(self: *Manager) void {
        self.new_inhibitor.notify = handleNewInhibitor;
        c.wl_signal_add(&self.manager.*.events.new_inhibitor, &self.new_inhibitor);
        self.listeners_ready = true;
    }

    pub fn deinit(self: *Manager) void {
        if (self.listeners_ready) {
            c.wl_list_remove(&self.new_inhibitor.link);
        }

        while (self.entries.items.len > 0) {
            const entry = self.entries.items[self.entries.items.len - 1];
            self.unregisterEntry(entry);
        }
    }

    fn registerInhibitor(self: *Manager, inhibitor: [*c]c.struct_wlr_idle_inhibitor_v1) !void {
        const surface = inhibitor.*.surface orelse return;

        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);

        entry.* = .{
            .owner = self,
            .inhibitor = inhibitor,
            .surface = surface,
        };
        entry.destroy.notify = Entry.handleDestroy;
        entry.surface_destroy.notify = Entry.handleSurfaceDestroy;
        entry.surface_commit.notify = Entry.handleSurfaceCommit;

        c.wl_signal_add(&inhibitor.*.events.destroy, &entry.destroy);
        c.wl_signal_add(&surface.*.events.destroy, &entry.surface_destroy);
        c.wl_signal_add(&surface.*.events.commit, &entry.surface_commit);

        try self.entries.append(self.allocator, entry);
        self.refreshInhibition();
    }

    fn unregisterEntry(self: *Manager, target: *Entry) void {
        for (self.entries.items, 0..) |entry, index| {
            if (entry == target) {
                entry.detach();
                _ = self.entries.swapRemove(index);
                self.allocator.destroy(entry);
                self.refreshInhibition();
                return;
            }
        }
    }

    fn refreshInhibition(self: *Manager) void {
        var inhibited = false;
        for (self.entries.items) |entry| {
            if (entry.surface.*.mapped) {
                inhibited = true;
                break;
            }
        }
        c.wlr_idle_notifier_v1_set_inhibited(self.idle_notifier, inhibited);
    }

    fn handleNewInhibitor(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const manager: *Manager = @ptrCast(@as(*allowzero Manager, @fieldParentPtr("new_inhibitor", listener)));
        const raw_inhibitor = data orelse return;
        const inhibitor: [*c]c.struct_wlr_idle_inhibitor_v1 = @ptrCast(@alignCast(raw_inhibitor));

        manager.registerInhibitor(inhibitor) catch |err| {
            log.err("failed to register idle inhibitor: {}", .{err});
        };
    }
};
