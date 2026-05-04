const std = @import("std");
const c = @import("../wl.zig").c;

const log = std.log.scoped(.axia_pointer_constraints);

const Entry = struct {
    owner: *Manager,
    constraint: [*c]c.struct_wlr_pointer_constraint_v1,
    destroy: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    set_region: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),

    fn detach(self: *Entry) void {
        c.wl_list_remove(&self.set_region.link);
        c.wl_list_remove(&self.destroy.link);
    }

    fn handleDestroy(listener: [*c]c.struct_wl_listener, _: ?*anyopaque) callconv(.c) void {
        const entry: *Entry = @ptrCast(@as(*allowzero Entry, @fieldParentPtr("destroy", listener)));
        entry.owner.unregisterEntry(entry);
    }

    fn handleSetRegion(listener: [*c]c.struct_wl_listener, _: ?*anyopaque) callconv(.c) void {
        const entry: *Entry = @ptrCast(@as(*allowzero Entry, @fieldParentPtr("set_region", listener)));
        if (entry.owner.active_constraint) |active_constraint| {
            if (active_constraint != entry.constraint) return;
            var lx = entry.owner.cursor.*.x;
            var ly = entry.owner.cursor.*.y;
            entry.owner.enforceActiveConstraint(&lx, &ly);
        }
    }
};

pub const MotionDisposition = enum {
    normal,
    locked,
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    seat: [*c]c.struct_wlr_seat,
    cursor: [*c]c.struct_wlr_cursor,
    manager: [*c]c.struct_wlr_pointer_constraints_v1,
    entries: std.ArrayListUnmanaged(*Entry) = .empty,
    active_constraint: ?[*c]c.struct_wlr_pointer_constraint_v1 = null,
    new_constraint: c.struct_wl_listener = std.mem.zeroes(c.struct_wl_listener),
    listeners_ready: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        display: *c.struct_wl_display,
        seat: [*c]c.struct_wlr_seat,
        cursor: [*c]c.struct_wlr_cursor,
    ) !Manager {
        const manager = c.wlr_pointer_constraints_v1_create(display);
        if (manager == null) return error.PointerConstraintsCreateFailed;

        return .{
            .allocator = allocator,
            .seat = seat,
            .cursor = cursor,
            .manager = manager,
        };
    }

    pub fn setupListeners(self: *Manager) void {
        self.new_constraint.notify = handleNewConstraint;
        c.wl_signal_add(&self.manager.*.events.new_constraint, &self.new_constraint);
        self.listeners_ready = true;
    }

    pub fn applyMotion(
        self: *Manager,
        old_x: f64,
        old_y: f64,
        lx: *f64,
        ly: *f64,
    ) MotionDisposition {
        const constraint = self.active_constraint orelse return .normal;
        switch (constraint.*.type) {
            c.WLR_POINTER_CONSTRAINT_V1_LOCKED => {
                c.wlr_cursor_warp_closest(self.cursor, null, old_x, old_y);
                lx.* = old_x;
                ly.* = old_y;
                return .locked;
            },
            c.WLR_POINTER_CONSTRAINT_V1_CONFINED => {
                self.enforceActiveConstraint(lx, ly);
                return .normal;
            },
            else => return .normal,
        }
    }

    pub fn syncFocus(self: *Manager, focused_surface: ?[*c]c.struct_wlr_surface, lx: f64, ly: f64) void {
        const next_constraint = if (focused_surface) |surface|
            c.wlr_pointer_constraints_v1_constraint_for_surface(self.manager, surface, self.seat)
        else
            null;

        if (self.active_constraint) |active_constraint| {
            if (next_constraint != active_constraint) {
                self.deactivateActiveConstraint(lx, ly);
            }
        }

        if (next_constraint == null) return;
        if (self.active_constraint) |active_constraint| {
            if (active_constraint == next_constraint) {
                var current_lx = lx;
                var current_ly = ly;
                self.enforceActiveConstraint(&current_lx, &current_ly);
                return;
            }
        }

        if (self.canActivate(next_constraint.?, lx, ly)) {
            self.active_constraint = next_constraint.?;
            c.wlr_pointer_constraint_v1_send_activated(next_constraint.?);
            var current_lx = lx;
            var current_ly = ly;
            self.enforceActiveConstraint(&current_lx, &current_ly);
        }
    }

    pub fn deinit(self: *Manager) void {
        if (self.listeners_ready) {
            c.wl_list_remove(&self.new_constraint.link);
        }

        while (self.entries.items.len > 0) {
            const entry = self.entries.items[self.entries.items.len - 1];
            self.unregisterEntry(entry);
        }
    }

    fn registerConstraint(self: *Manager, constraint: [*c]c.struct_wlr_pointer_constraint_v1) !void {
        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);

        entry.* = .{
            .owner = self,
            .constraint = constraint,
        };
        entry.destroy.notify = Entry.handleDestroy;
        entry.set_region.notify = Entry.handleSetRegion;

        c.wl_signal_add(&constraint.*.events.destroy, &entry.destroy);
        c.wl_signal_add(&constraint.*.events.set_region, &entry.set_region);

        try self.entries.append(self.allocator, entry);
    }

    fn unregisterEntry(self: *Manager, target: *Entry) void {
        if (self.active_constraint) |active_constraint| {
            if (active_constraint == target.constraint) {
                self.active_constraint = null;
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

    fn deactivateActiveConstraint(self: *Manager, lx: f64, ly: f64) void {
        const constraint = self.active_constraint orelse return;
        self.active_constraint = null;

        if (constraint.*.type == c.WLR_POINTER_CONSTRAINT_V1_LOCKED and constraint.*.current.cursor_hint.enabled) {
            const origin = self.surfaceOrigin(constraint, lx, ly);
            c.wlr_cursor_warp_closest(
                self.cursor,
                null,
                origin.x + constraint.*.current.cursor_hint.x,
                origin.y + constraint.*.current.cursor_hint.y,
            );
        }

        c.wlr_pointer_constraint_v1_send_deactivated(constraint);
    }

    fn canActivate(self: *Manager, constraint: [*c]c.struct_wlr_pointer_constraint_v1, lx: f64, ly: f64) bool {
        if (constraint.*.type == c.WLR_POINTER_CONSTRAINT_V1_CONFINED) return true;
        var region = self.constraintRegion(constraint, lx, ly);
        defer c.pixman_region32_fini(&region);
        return c.pixman_region32_contains_point(
            &region,
            @intFromFloat(@floor(lx)),
            @intFromFloat(@floor(ly)),
            null,
        ) != 0;
    }

    fn enforceActiveConstraint(self: *Manager, lx: *f64, ly: *f64) void {
        const constraint = self.active_constraint orelse return;
        if (constraint.*.type != c.WLR_POINTER_CONSTRAINT_V1_CONFINED) return;

        var region = self.constraintRegion(constraint, lx.*, ly.*);
        defer c.pixman_region32_fini(&region);

        if (c.pixman_region32_contains_point(
            &region,
            @intFromFloat(@floor(lx.*)),
            @intFromFloat(@floor(ly.*)),
            null,
        ) != 0) return;

        const extents = c.pixman_region32_extents(&region);
        if (extents == null) return;

        const min_x = @as(f64, @floatFromInt(extents.*.x1));
        const min_y = @as(f64, @floatFromInt(extents.*.y1));
        const max_x = @as(f64, @floatFromInt(@max(extents.*.x2 - 1, extents.*.x1)));
        const max_y = @as(f64, @floatFromInt(@max(extents.*.y2 - 1, extents.*.y1)));

        const target_x = std.math.clamp(lx.*, min_x, max_x);
        const target_y = std.math.clamp(ly.*, min_y, max_y);
        c.wlr_cursor_warp_closest(self.cursor, null, target_x, target_y);
        lx.* = self.cursor.*.x;
        ly.* = self.cursor.*.y;
    }

    fn constraintRegion(self: *Manager, constraint: [*c]c.struct_wlr_pointer_constraint_v1, lx: f64, ly: f64) c.pixman_region32_t {
        var region = std.mem.zeroes(c.pixman_region32_t);
        if (c.pixman_region32_not_empty(&constraint.*.region) != 0) {
            c.pixman_region32_init(&region);
            _ = c.pixman_region32_copy(&region, &constraint.*.region);
        } else {
            const width = @max(constraint.*.surface.*.current.width, 1);
            const height = @max(constraint.*.surface.*.current.height, 1);
            c.pixman_region32_init_rect(&region, 0, 0, @intCast(width), @intCast(height));
        }

        const origin = self.surfaceOrigin(constraint, lx, ly);
        c.pixman_region32_translate(&region, @intFromFloat(@floor(origin.x)), @intFromFloat(@floor(origin.y)));
        return region;
    }

    fn surfaceOrigin(self: *Manager, constraint: [*c]c.struct_wlr_pointer_constraint_v1, lx: f64, ly: f64) struct { x: f64, y: f64 } {
        _ = constraint;
        return .{
            .x = lx - self.seat.*.pointer_state.sx,
            .y = ly - self.seat.*.pointer_state.sy,
        };
    }

    fn handleNewConstraint(listener: [*c]c.struct_wl_listener, data: ?*anyopaque) callconv(.c) void {
        const manager: *Manager = @ptrCast(@as(*allowzero Manager, @fieldParentPtr("new_constraint", listener)));
        const raw_constraint = data orelse return;
        const constraint: [*c]c.struct_wlr_pointer_constraint_v1 = @ptrCast(@alignCast(raw_constraint));

        manager.registerConstraint(constraint) catch |err| {
            log.err("failed to register pointer constraint: {}", .{err});
        };
    }
};
