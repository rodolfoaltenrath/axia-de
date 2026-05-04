const std = @import("std");
const c = @import("../wl.zig").c;

const log = std.log.scoped(.axia_session_lock);

const SurfaceEntry = struct {
    owner: *Manager,
    lock_surface: [*c]c.struct_wlr_session_lock_surface_v1,
    scene_tree: [*c]c.struct_wlr_scene_tree,
    destroy: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),

    fn detach(self: *SurfaceEntry) void {
        c.wl_list_remove(&self.destroy.link);
    }

    fn destroyScene(self: *SurfaceEntry) void {
        c.wlr_scene_node_destroy(&self.scene_tree.*.node);
    }

    fn handleDestroy(listener: [*c]c.struct_wl_listener, _: ?*anyopaque) callconv(.c) void {
        const entry: *SurfaceEntry = @ptrCast(@as(*allowzero SurfaceEntry, @fieldParentPtr("destroy", listener)));
        entry.owner.unregisterSurface(entry);
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    output_layout: [*c]c.struct_wlr_output_layout,
    seat: [*c]c.struct_wlr_seat,
    root: [*c]c.struct_wlr_scene_tree,
    manager: [*c]c.struct_wlr_session_lock_manager_v1,
    active_lock: ?[*c]c.struct_wlr_session_lock_v1 = null,
    surfaces: std.ArrayListUnmanaged(*SurfaceEntry) = .empty,
    new_lock: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    lock_new_surface: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    lock_unlock: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    lock_destroy: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    listeners_ready: bool = false,
    lock_listeners_ready: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        display: *c.struct_wl_display,
        output_layout: [*c]c.struct_wlr_output_layout,
        seat: [*c]c.struct_wlr_seat,
        root: [*c]c.struct_wlr_scene_tree,
    ) !Manager {
        const manager = c.wlr_session_lock_manager_v1_create(display);
        if (manager == null) return error.SessionLockManagerCreateFailed;

        return .{
            .allocator = allocator,
            .output_layout = output_layout,
            .seat = seat,
            .root = root,
            .manager = manager,
        };
    }

    pub fn setupListeners(self: *Manager) void {
        self.new_lock.notify = handleNewLock;
        c.wl_signal_add(&self.manager.*.events.new_lock, &self.new_lock);
        self.listeners_ready = true;
    }

    pub fn isLocked(self: *const Manager) bool {
        return self.active_lock != null;
    }

    pub fn handlePointerMotion(self: *Manager, time_msec: u32, lx: f64, ly: f64) bool {
        if (!self.isLocked()) return false;

        if (self.hitTest(lx, ly)) |hit| {
            if (!c.wlr_seat_pointer_surface_has_focus(self.seat, hit.surface)) {
                c.wlr_seat_pointer_notify_enter(self.seat, hit.surface, hit.sx, hit.sy);
            } else {
                c.wlr_seat_pointer_notify_motion(self.seat, time_msec, hit.sx, hit.sy);
            }
        } else {
            c.wlr_seat_pointer_notify_clear_focus(self.seat);
        }
        return true;
    }

    pub fn handlePointerButton(
        self: *Manager,
        time_msec: u32,
        button: u32,
        state: c.enum_wl_pointer_button_state,
        lx: f64,
        ly: f64,
    ) bool {
        if (!self.isLocked()) return false;

        if (self.hitTest(lx, ly)) |hit| {
            if (!c.wlr_seat_pointer_surface_has_focus(self.seat, hit.surface)) {
                c.wlr_seat_pointer_notify_enter(self.seat, hit.surface, hit.sx, hit.sy);
            }
            if (state == c.WL_POINTER_BUTTON_STATE_PRESSED) {
                self.focusSurface(hit.surface);
            }
            _ = c.wlr_seat_pointer_notify_button(self.seat, time_msec, button, state);
        } else {
            c.wlr_seat_pointer_notify_clear_focus(self.seat);
        }
        return true;
    }

    pub fn reconfigureSurfaces(self: *Manager) void {
        for (self.surfaces.items) |entry| {
            self.configureSurface(entry);
        }
    }

    pub fn deinit(self: *Manager) void {
        self.deactivateLock();
        if (self.listeners_ready) {
            c.wl_list_remove(&self.new_lock.link);
        }
    }

    const Hit = struct {
        surface: [*c]c.struct_wlr_surface,
        sx: f64,
        sy: f64,
    };

    fn registerSurface(self: *Manager, lock_surface: [*c]c.struct_wlr_session_lock_surface_v1) !void {
        const scene_tree = c.wlr_scene_subsurface_tree_create(self.root, lock_surface.*.surface) orelse {
            return error.SessionLockSceneCreateFailed;
        };

        const entry = try self.allocator.create(SurfaceEntry);
        errdefer self.allocator.destroy(entry);

        entry.* = .{
            .owner = self,
            .lock_surface = lock_surface,
            .scene_tree = scene_tree,
        };
        entry.destroy.notify = SurfaceEntry.handleDestroy;
        c.wl_signal_add(&lock_surface.*.events.destroy, &entry.destroy);

        try self.surfaces.append(self.allocator, entry);
        self.configureSurface(entry);
        c.wlr_scene_node_raise_to_top(&scene_tree.*.node);
        self.focusSurface(lock_surface.*.surface);
    }

    fn unregisterSurface(self: *Manager, target: *SurfaceEntry) void {
        for (self.surfaces.items, 0..) |entry, index| {
            if (entry == target) {
                entry.detach();
                _ = self.surfaces.swapRemove(index);
                entry.destroyScene();
                self.allocator.destroy(entry);
                return;
            }
        }
    }

    fn configureSurface(self: *Manager, entry: *SurfaceEntry) void {
        const output = entry.lock_surface.*.output orelse return;
        var box = std.mem.zeroes(c.struct_wlr_box);
        c.wlr_output_layout_get_box(self.output_layout, output, &box);
        if (box.width <= 0 or box.height <= 0) return;

        c.wlr_scene_node_set_position(&entry.scene_tree.*.node, box.x, box.y);
        _ = c.wlr_session_lock_surface_v1_configure(
            entry.lock_surface,
            @intCast(box.width),
            @intCast(box.height),
        );
    }

    fn focusSurface(self: *Manager, surface: [*c]c.struct_wlr_surface) void {
        const keyboard = c.wlr_seat_get_keyboard(self.seat);
        if (keyboard != null) {
            const keycodes: [*c]const u32 = if (keyboard.*.num_keycodes > 0)
                @ptrCast(&keyboard.*.keycodes[0])
            else
                null;
            c.wlr_seat_keyboard_notify_enter(
                self.seat,
                surface,
                keycodes,
                keyboard.*.num_keycodes,
                &keyboard.*.modifiers,
            );
        }
    }

    fn hitTest(self: *Manager, lx: f64, ly: f64) ?Hit {
        var sx: f64 = 0;
        var sy: f64 = 0;
        const node = c.wlr_scene_node_at(&self.root.*.node, lx, ly, &sx, &sy) orelse return null;
        if (node.*.type != c.WLR_SCENE_NODE_BUFFER) return null;

        const scene_buffer = c.wlr_scene_buffer_from_node(node);
        const scene_surface = c.wlr_scene_surface_try_from_buffer(scene_buffer) orelse return null;
        _ = c.wlr_session_lock_surface_v1_try_from_wlr_surface(scene_surface.*.surface) orelse return null;

        return .{
            .surface = scene_surface.*.surface,
            .sx = sx,
            .sy = sy,
        };
    }

    fn activateLock(self: *Manager, lock: [*c]c.struct_wlr_session_lock_v1) void {
        self.active_lock = lock;
        self.lock_new_surface.notify = handleLockNewSurface;
        self.lock_unlock.notify = handleLockUnlock;
        self.lock_destroy.notify = handleLockDestroy;

        c.wl_signal_add(&lock.*.events.new_surface, &self.lock_new_surface);
        c.wl_signal_add(&lock.*.events.unlock, &self.lock_unlock);
        c.wl_signal_add(&lock.*.events.destroy, &self.lock_destroy);
        self.lock_listeners_ready = true;

        c.wlr_seat_pointer_notify_clear_focus(self.seat);
        c.wlr_seat_keyboard_notify_clear_focus(self.seat);
        c.wlr_session_lock_v1_send_locked(lock);
        log.info("session locked", .{});
    }

    fn deactivateLock(self: *Manager) void {
        if (self.lock_listeners_ready) {
            c.wl_list_remove(&self.lock_destroy.link);
            c.wl_list_remove(&self.lock_unlock.link);
            c.wl_list_remove(&self.lock_new_surface.link);
            self.lock_listeners_ready = false;
        }

        while (self.surfaces.items.len > 0) {
            const entry = self.surfaces.items[self.surfaces.items.len - 1];
            self.unregisterSurface(entry);
        }

        if (self.active_lock != null) {
            c.wlr_seat_pointer_notify_clear_focus(self.seat);
            c.wlr_seat_keyboard_notify_clear_focus(self.seat);
        }
        self.active_lock = null;
    }

    fn handleNewLock(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const manager: *Manager = @ptrCast(@as(*allowzero Manager, @fieldParentPtr("new_lock", listener)));
        const raw_lock = data orelse return;
        const lock: [*c]c.struct_wlr_session_lock_v1 = @ptrCast(@alignCast(raw_lock));

        if (manager.active_lock != null) {
            c.wlr_session_lock_v1_destroy(lock);
            return;
        }

        manager.activateLock(lock);
    }

    fn handleLockNewSurface(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const manager: *Manager = @ptrCast(@as(*allowzero Manager, @fieldParentPtr("lock_new_surface", listener)));
        const raw_surface = data orelse return;
        const lock_surface: [*c]c.struct_wlr_session_lock_surface_v1 = @ptrCast(@alignCast(raw_surface));

        manager.registerSurface(lock_surface) catch |err| {
            log.err("failed to register session lock surface: {}", .{err});
            c.wlr_session_lock_v1_destroy(manager.active_lock.?);
        };
    }

    fn handleLockUnlock(listener: [*c]c.struct_wl_listener, _: ?*anyopaque) callconv(.c) void {
        const manager: *Manager = @ptrCast(@as(*allowzero Manager, @fieldParentPtr("lock_unlock", listener)));
        manager.deactivateLock();
        log.info("session unlocked", .{});
    }

    fn handleLockDestroy(listener: [*c]c.struct_wl_listener, _: ?*anyopaque) callconv(.c) void {
        const manager: *Manager = @ptrCast(@as(*allowzero Manager, @fieldParentPtr("lock_destroy", listener)));
        manager.deactivateLock();
    }
};
