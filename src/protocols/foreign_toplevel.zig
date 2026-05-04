const std = @import("std");
const c = @import("../wl.zig").c;
const View = @import("../shell/view.zig").View;

pub const ActivateViewCallback = *const fn (?*anyopaque, *View) void;
pub const CloseViewCallback = *const fn (?*anyopaque, *View) void;
pub const SetViewMinimizedCallback = *const fn (?*anyopaque, *View, bool) void;
pub const SetViewMaximizedCallback = *const fn (?*anyopaque, *View, bool) void;
pub const SetViewFullscreenCallback = *const fn (?*anyopaque, *View, bool) void;

const log = std.log.scoped(.axia_foreign_toplevel);

const Entry = struct {
    owner: *Manager,
    view: *View,
    handle: [*c]c.struct_wlr_foreign_toplevel_handle_v1,
    destroying: bool = false,
    current_output: ?[*c]c.struct_wlr_output = null,
    request_maximize: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    request_minimize: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    request_activate: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    request_fullscreen: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    request_close: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    destroy: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),

    fn detach(self: *Entry) void {
        c.wl_list_remove(&self.request_maximize.link);
        c.wl_list_remove(&self.request_minimize.link);
        c.wl_list_remove(&self.request_activate.link);
        c.wl_list_remove(&self.request_fullscreen.link);
        c.wl_list_remove(&self.request_close.link);
        c.wl_list_remove(&self.destroy.link);
    }

    fn handleRequestMaximize(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const entry: *Entry = @ptrCast(@as(*allowzero Entry, @fieldParentPtr("request_maximize", listener)));
        const raw_event = data orelse return;
        const event: *c.struct_wlr_foreign_toplevel_handle_v1_maximized_event = @ptrCast(@alignCast(raw_event));
        if (entry.owner.set_view_maximized_cb) |callback| {
            callback(entry.owner.ctx, entry.view, event.maximized);
        }
    }

    fn handleRequestMinimize(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const entry: *Entry = @ptrCast(@as(*allowzero Entry, @fieldParentPtr("request_minimize", listener)));
        const raw_event = data orelse return;
        const event: *c.struct_wlr_foreign_toplevel_handle_v1_minimized_event = @ptrCast(@alignCast(raw_event));
        if (entry.owner.set_view_minimized_cb) |callback| {
            callback(entry.owner.ctx, entry.view, event.minimized);
        }
    }

    fn handleRequestActivate(listener: [*c]c.struct_wl_listener, _: ?*anyopaque) callconv(.c) void {
        const entry: *Entry = @ptrCast(@as(*allowzero Entry, @fieldParentPtr("request_activate", listener)));
        if (entry.owner.activate_view_cb) |callback| {
            callback(entry.owner.ctx, entry.view);
        }
    }

    fn handleRequestFullscreen(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const entry: *Entry = @ptrCast(@as(*allowzero Entry, @fieldParentPtr("request_fullscreen", listener)));
        const raw_event = data orelse return;
        const event: *c.struct_wlr_foreign_toplevel_handle_v1_fullscreen_event = @ptrCast(@alignCast(raw_event));
        if (entry.owner.set_view_fullscreen_cb) |callback| {
            callback(entry.owner.ctx, entry.view, event.fullscreen);
        }
    }

    fn handleRequestClose(listener: [*c]c.struct_wl_listener, _: ?*anyopaque) callconv(.c) void {
        const entry: *Entry = @ptrCast(@as(*allowzero Entry, @fieldParentPtr("request_close", listener)));
        if (entry.owner.close_view_cb) |callback| {
            callback(entry.owner.ctx, entry.view);
        }
    }

    fn handleDestroy(listener: [*c]c.struct_wl_listener, _: ?*anyopaque) callconv(.c) void {
        const entry: *Entry = @ptrCast(@as(*allowzero Entry, @fieldParentPtr("destroy", listener)));
        if (entry.destroying) return;
        entry.owner.releaseEntry(entry);
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    manager: [*c]c.struct_wlr_foreign_toplevel_manager_v1,
    entries: std.ArrayListUnmanaged(*Entry) = .empty,
    ctx: ?*anyopaque = null,
    activate_view_cb: ?ActivateViewCallback = null,
    close_view_cb: ?CloseViewCallback = null,
    set_view_minimized_cb: ?SetViewMinimizedCallback = null,
    set_view_maximized_cb: ?SetViewMaximizedCallback = null,
    set_view_fullscreen_cb: ?SetViewFullscreenCallback = null,

    pub fn init(allocator: std.mem.Allocator, display: *c.struct_wl_display) !Manager {
        const manager = c.wlr_foreign_toplevel_manager_v1_create(display);
        if (manager == null) return error.ForeignToplevelManagerCreateFailed;

        return .{
            .allocator = allocator,
            .manager = manager,
        };
    }

    pub fn setActionCallbacks(
        self: *Manager,
        ctx: ?*anyopaque,
        activate_view_cb: ActivateViewCallback,
        close_view_cb: CloseViewCallback,
        set_view_minimized_cb: SetViewMinimizedCallback,
        set_view_maximized_cb: SetViewMaximizedCallback,
        set_view_fullscreen_cb: SetViewFullscreenCallback,
    ) void {
        self.ctx = ctx;
        self.activate_view_cb = activate_view_cb;
        self.close_view_cb = close_view_cb;
        self.set_view_minimized_cb = set_view_minimized_cb;
        self.set_view_maximized_cb = set_view_maximized_cb;
        self.set_view_fullscreen_cb = set_view_fullscreen_cb;
    }

    pub fn registerView(
        self: *Manager,
        view: *View,
        focused: bool,
        output: ?[*c]c.struct_wlr_output,
    ) !void {
        if (!view.isForeignToplevelCandidate()) return;
        if (self.findEntry(view) != null) {
            self.syncView(view, focused, output);
            return;
        }

        const handle = c.wlr_foreign_toplevel_handle_v1_create(self.manager);
        if (handle == null) return error.ForeignToplevelHandleCreateFailed;

        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);

        entry.* = .{
            .owner = self,
            .view = view,
            .handle = handle,
        };

        entry.request_maximize.notify = Entry.handleRequestMaximize;
        entry.request_minimize.notify = Entry.handleRequestMinimize;
        entry.request_activate.notify = Entry.handleRequestActivate;
        entry.request_fullscreen.notify = Entry.handleRequestFullscreen;
        entry.request_close.notify = Entry.handleRequestClose;
        entry.destroy.notify = Entry.handleDestroy;

        c.wl_signal_add(&handle.*.events.request_maximize, &entry.request_maximize);
        c.wl_signal_add(&handle.*.events.request_minimize, &entry.request_minimize);
        c.wl_signal_add(&handle.*.events.request_activate, &entry.request_activate);
        c.wl_signal_add(&handle.*.events.request_fullscreen, &entry.request_fullscreen);
        c.wl_signal_add(&handle.*.events.request_close, &entry.request_close);
        c.wl_signal_add(&handle.*.events.destroy, &entry.destroy);

        try self.entries.append(self.allocator, entry);
        self.syncEntry(entry, focused, output);
    }

    pub fn unregisterView(self: *Manager, view: *View) void {
        if (self.findEntry(view)) |entry| {
            self.destroyEntry(entry);
        }
    }

    pub fn syncView(
        self: *Manager,
        view: *View,
        focused: bool,
        output: ?[*c]c.struct_wlr_output,
    ) void {
        if (!view.isForeignToplevelCandidate()) return;
        const entry = self.findEntry(view) orelse {
            self.registerView(view, focused, output) catch |err| {
                log.err("failed to register foreign toplevel handle: {}", .{err});
            };
            return;
        };
        self.syncEntry(entry, focused, output);
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

        c.wlr_foreign_toplevel_handle_v1_destroy(entry.handle);
        self.allocator.destroy(entry);
    }

    fn syncEntry(self: *Manager, entry: *Entry, focused: bool, output: ?[*c]c.struct_wlr_output) void {
        _ = self;
        c.wlr_foreign_toplevel_handle_v1_set_title(entry.handle, viewTitle(entry.view).ptr);
        c.wlr_foreign_toplevel_handle_v1_set_app_id(entry.handle, viewAppId(entry.view).ptr);
        c.wlr_foreign_toplevel_handle_v1_set_activated(entry.handle, focused and entry.view.mappedState() and !entry.view.isMinimized());
        c.wlr_foreign_toplevel_handle_v1_set_minimized(entry.handle, entry.view.isMinimized());
        c.wlr_foreign_toplevel_handle_v1_set_maximized(entry.handle, entry.view.isMaximized());
        c.wlr_foreign_toplevel_handle_v1_set_fullscreen(entry.handle, entry.view.isFullscreen());

        if (entry.current_output != output) {
            if (entry.current_output) |previous| {
                c.wlr_foreign_toplevel_handle_v1_output_leave(entry.handle, previous);
            }
            entry.current_output = output;
            if (output) |next_output| {
                c.wlr_foreign_toplevel_handle_v1_output_enter(entry.handle, next_output);
            }
        }
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
