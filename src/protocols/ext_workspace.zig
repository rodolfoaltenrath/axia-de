const std = @import("std");
const c = @import("../wl.zig").c;

const log = std.log.scoped(.axia_ext_workspace);

pub const ActivateWorkspaceCallback = *const fn (?*anyopaque, usize) void;

const WorkspaceResource = struct {
    binding: *Binding,
    workspace_index: usize,
    resource: ?*c.struct_wl_resource = null,
};

const Binding = struct {
    owner: *Manager,
    manager_resource: ?*c.struct_wl_resource = null,
    group_resource: ?*c.struct_wl_resource = null,
    workspace_resources: []WorkspaceResource,
    pending_activation: ?usize = null,
    stopping: bool = false,
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    display: *c.struct_wl_display,
    global: ?*c.struct_wl_global = null,
    bindings: std.ArrayListUnmanaged(*Binding) = .empty,
    workspace_count: usize,
    active_workspace: usize = 0,
    activate_ctx: ?*anyopaque = null,
    activate_cb: ?ActivateWorkspaceCallback = null,

    const manager_impl = c.struct_ext_workspace_manager_v1_interface{
        .commit = handleManagerCommit,
        .stop = handleManagerStop,
    };

    const group_impl = c.struct_ext_workspace_group_handle_v1_interface{
        .create_workspace = handleGroupCreateWorkspace,
        .destroy = handleGroupDestroy,
    };

    const workspace_impl = c.struct_ext_workspace_handle_v1_interface{
        .destroy = handleWorkspaceDestroy,
        .activate = handleWorkspaceActivate,
        .deactivate = handleWorkspaceDeactivate,
        .assign = handleWorkspaceAssign,
        .remove = handleWorkspaceRemove,
    };

    pub fn create(allocator: std.mem.Allocator, display: *c.struct_wl_display, workspace_count: usize) !*Manager {
        const manager = try allocator.create(Manager);
        errdefer allocator.destroy(manager);

        manager.* = .{
            .allocator = allocator,
            .display = display,
            .workspace_count = workspace_count,
        };

        const global = c.wl_global_create(
            display,
            &c.ext_workspace_manager_v1_interface,
            1,
            manager,
            bindManager,
        );
        if (global == null) return error.ExtWorkspaceGlobalCreateFailed;
        manager.global = global;
        return manager;
    }

    pub fn setActivateCallback(self: *Manager, ctx: ?*anyopaque, callback: ActivateWorkspaceCallback) void {
        self.activate_ctx = ctx;
        self.activate_cb = callback;
    }

    pub fn publishState(self: *Manager, active_workspace: usize, workspace_count: usize) void {
        self.active_workspace = if (workspace_count == 0) 0 else @min(active_workspace, workspace_count - 1);
        self.workspace_count = workspace_count;

        for (self.bindings.items) |binding| {
            self.sendState(binding);
        }
    }

    pub fn destroy(self: *Manager) void {
        while (self.bindings.items.len > 0) {
            const binding = self.bindings.items[self.bindings.items.len - 1];
            self.destroyBinding(binding);
        }
        _ = self.display;
        _ = self.global;
        self.allocator.destroy(self);
    }

    fn bindManager(client: ?*c.struct_wl_client, data: ?*anyopaque, version: u32, id: u32) callconv(.c) void {
        const raw_manager = data orelse return;
        const manager: *Manager = @ptrCast(@alignCast(raw_manager));
        const wl_client = client orelse return;

        manager.createBinding(wl_client, version, id) catch |err| {
            log.err("failed to bind ext-workspace manager: {}", .{err});
        };
    }

    fn createBinding(self: *Manager, client: *c.struct_wl_client, version: u32, id: u32) !void {
        const manager_resource = c.wl_resource_create(client, &c.ext_workspace_manager_v1_interface, @min(version, 1), id) orelse {
            return error.ExtWorkspaceManagerResourceCreateFailed;
        };

        const binding = try self.allocator.create(Binding);
        errdefer self.allocator.destroy(binding);

        const workspaces = try self.allocator.alloc(WorkspaceResource, self.workspace_count);
        errdefer self.allocator.free(workspaces);

        binding.* = .{
            .owner = self,
            .manager_resource = manager_resource,
            .workspace_resources = workspaces,
        };
        for (binding.workspace_resources, 0..) |*workspace, index| {
            workspace.* = .{
                .binding = binding,
                .workspace_index = index,
            };
        }

        c.wl_resource_set_implementation(
            manager_resource,
            &manager_impl,
            binding,
            handleManagerResourceDestroy,
        );

        const group_resource = c.wl_resource_create(client, &c.ext_workspace_group_handle_v1_interface, 1, 0) orelse {
            c.wl_resource_destroy(manager_resource);
            return error.ExtWorkspaceGroupResourceCreateFailed;
        };
        binding.group_resource = group_resource;
        c.wl_resource_set_implementation(
            group_resource,
            &group_impl,
            binding,
            handleGroupResourceDestroy,
        );

        try self.bindings.append(self.allocator, binding);
        self.sendInitialState(binding, client);
    }

    fn destroyBinding(self: *Manager, binding: *Binding) void {
        for (self.bindings.items, 0..) |entry, index| {
            if (entry == binding) {
                _ = self.bindings.swapRemove(index);
                break;
            }
        }

        if (binding.manager_resource) |resource| {
            binding.manager_resource = null;
            c.wl_resource_set_user_data(resource, null);
            c.wl_resource_destroy(resource);
        }

        if (binding.group_resource) |resource| {
            binding.group_resource = null;
            c.wl_resource_set_user_data(resource, null);
            c.wl_resource_destroy(resource);
        }

        for (binding.workspace_resources) |*workspace| {
            if (workspace.resource) |resource| {
                workspace.resource = null;
                c.wl_resource_set_user_data(resource, null);
                c.wl_resource_destroy(resource);
            }
        }

        self.allocator.free(binding.workspace_resources);
        self.allocator.destroy(binding);
    }

    fn sendInitialState(self: *Manager, binding: *Binding, client: *c.struct_wl_client) void {
        const manager_resource = binding.manager_resource orelse return;
        const group_resource = binding.group_resource orelse return;

        c.ext_workspace_manager_v1_send_workspace_group(manager_resource, group_resource);
        c.ext_workspace_group_handle_v1_send_capabilities(group_resource, 0);

        for (binding.workspace_resources) |*workspace| {
            const resource = c.wl_resource_create(client, &c.ext_workspace_handle_v1_interface, 1, 0) orelse continue;
            workspace.resource = resource;
            c.wl_resource_set_implementation(
                resource,
                &workspace_impl,
                workspace,
                handleWorkspaceResourceDestroy,
            );

            c.ext_workspace_manager_v1_send_workspace(manager_resource, resource);
            c.ext_workspace_group_handle_v1_send_workspace_enter(group_resource, resource);
            self.sendWorkspaceProperties(binding, workspace.workspace_index);
        }

        c.ext_workspace_manager_v1_send_done(manager_resource);
    }

    fn sendState(self: *Manager, binding: *Binding) void {
        const manager_resource = binding.manager_resource orelse return;
        for (binding.workspace_resources, 0..) |workspace, index| {
            if (workspace.resource == null) continue;
            if (index >= self.workspace_count) continue;
            self.sendWorkspaceProperties(binding, index);
        }
        c.ext_workspace_manager_v1_send_done(manager_resource);
    }

    fn sendWorkspaceProperties(self: *Manager, binding: *Binding, workspace_index: usize) void {
        const workspace = if (workspace_index < binding.workspace_resources.len)
            &binding.workspace_resources[workspace_index]
        else
            return;
        const resource = workspace.resource orelse return;

        var id_buf: [32]u8 = undefined;
        const id_text = std.fmt.bufPrintZ(&id_buf, "axia-workspace-{d}", .{workspace_index + 1}) catch return;

        var name_buf: [16]u8 = undefined;
        const name_text = std.fmt.bufPrintZ(&name_buf, "{d}", .{workspace_index + 1}) catch return;

        var coords = std.mem.zeroes(c.struct_wl_array);
        c.wl_array_init(&coords);
        defer c.wl_array_release(&coords);
        if (c.wl_array_add(&coords, @sizeOf(u32))) |slot| {
            const coordinate: *u32 = @ptrCast(@alignCast(slot));
            coordinate.* = @intCast(workspace_index);
        }

        var state: u32 = 0;
        if (workspace_index == self.active_workspace) {
            state |= c.EXT_WORKSPACE_HANDLE_V1_STATE_ACTIVE;
        } else {
            state |= c.EXT_WORKSPACE_HANDLE_V1_STATE_HIDDEN;
        }

        c.ext_workspace_handle_v1_send_id(resource, id_text.ptr);
        c.ext_workspace_handle_v1_send_name(resource, name_text.ptr);
        c.ext_workspace_handle_v1_send_coordinates(resource, &coords);
        c.ext_workspace_handle_v1_send_state(resource, state);
        c.ext_workspace_handle_v1_send_capabilities(resource, c.EXT_WORKSPACE_HANDLE_V1_WORKSPACE_CAPABILITIES_ACTIVATE);
    }

    fn handleManagerCommit(_: ?*c.struct_wl_client, resource: ?*c.struct_wl_resource) callconv(.c) void {
        const wl_resource = resource orelse return;
        const raw_binding = c.wl_resource_get_user_data(wl_resource) orelse return;
        const binding: *Binding = @ptrCast(@alignCast(raw_binding));
        const manager = binding.owner;

        if (binding.pending_activation) |workspace_index| {
            binding.pending_activation = null;
            if (manager.activate_cb) |callback| {
                callback(manager.activate_ctx, workspace_index);
            }
        }
    }

    fn handleManagerStop(_: ?*c.struct_wl_client, resource: ?*c.struct_wl_resource) callconv(.c) void {
        const wl_resource = resource orelse return;
        const raw_binding = c.wl_resource_get_user_data(wl_resource) orelse return;
        const binding: *Binding = @ptrCast(@alignCast(raw_binding));
        binding.stopping = true;
        c.ext_workspace_manager_v1_send_finished(wl_resource);
        c.wl_resource_destroy(wl_resource);
    }

    fn handleGroupCreateWorkspace(_: ?*c.struct_wl_client, _: ?*c.struct_wl_resource, _: [*c]const u8) callconv(.c) void {}

    fn handleGroupDestroy(_: ?*c.struct_wl_client, resource: ?*c.struct_wl_resource) callconv(.c) void {
        const wl_resource = resource orelse return;
        c.wl_resource_destroy(wl_resource);
    }

    fn handleWorkspaceDestroy(_: ?*c.struct_wl_client, resource: ?*c.struct_wl_resource) callconv(.c) void {
        const wl_resource = resource orelse return;
        c.wl_resource_destroy(wl_resource);
    }

    fn handleWorkspaceActivate(_: ?*c.struct_wl_client, resource: ?*c.struct_wl_resource) callconv(.c) void {
        const wl_resource = resource orelse return;
        const raw_workspace = c.wl_resource_get_user_data(wl_resource) orelse return;
        const workspace: *WorkspaceResource = @ptrCast(@alignCast(raw_workspace));
        workspace.binding.pending_activation = workspace.workspace_index;
    }

    fn handleWorkspaceDeactivate(_: ?*c.struct_wl_client, _: ?*c.struct_wl_resource) callconv(.c) void {}

    fn handleWorkspaceAssign(_: ?*c.struct_wl_client, _: ?*c.struct_wl_resource, _: ?*c.struct_wl_resource) callconv(.c) void {}

    fn handleWorkspaceRemove(_: ?*c.struct_wl_client, _: ?*c.struct_wl_resource) callconv(.c) void {}

    fn handleManagerResourceDestroy(resource: ?*c.struct_wl_resource) callconv(.c) void {
        const wl_resource = resource orelse return;
        const raw_binding = c.wl_resource_get_user_data(wl_resource) orelse return;
        const binding: *Binding = @ptrCast(@alignCast(raw_binding));
        binding.manager_resource = null;
        binding.owner.destroyBinding(binding);
    }

    fn handleGroupResourceDestroy(resource: ?*c.struct_wl_resource) callconv(.c) void {
        const wl_resource = resource orelse return;
        const raw_binding = c.wl_resource_get_user_data(wl_resource) orelse return;
        const binding: *Binding = @ptrCast(@alignCast(raw_binding));
        binding.group_resource = if (binding.group_resource == wl_resource) null else binding.group_resource;
    }

    fn handleWorkspaceResourceDestroy(resource: ?*c.struct_wl_resource) callconv(.c) void {
        const wl_resource = resource orelse return;
        const raw_workspace = c.wl_resource_get_user_data(wl_resource) orelse return;
        const workspace: *WorkspaceResource = @ptrCast(@alignCast(raw_workspace));
        workspace.resource = if (workspace.resource == wl_resource) null else workspace.resource;
    }
};
