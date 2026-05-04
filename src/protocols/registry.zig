const std = @import("std");
const c = @import("../wl.zig").c;
const ContentType = @import("content_type.zig");
const CoreProtocols = @import("core.zig").CoreProtocols;
const CursorShape = @import("cursor_shape.zig");
const ExtForeignToplevelList = @import("ext_foreign_toplevel_list.zig");
const Output = @import("../core/output.zig").Output;
const OutputPowerManagement = @import("output_power_management.zig");
const View = @import("../shell/view.zig").View;
const ForeignToplevel = @import("foreign_toplevel.zig");
const ExtWorkspace = @import("ext_workspace.zig");
const IdleInhibit = @import("idle_inhibit.zig");
const IdleNotify = @import("idle_notify.zig");
const KeyboardShortcutsInhibit = @import("keyboard_shortcuts_inhibit.zig");
const OutputManagement = @import("output_management.zig");
const PointerConstraints = @import("pointer_constraints.zig");
const RelativePointer = @import("relative_pointer.zig");
const Screencopy = @import("screencopy.zig");
const Selection = @import("selection.zig");
const SessionLock = @import("session_lock.zig");
const TearingControl = @import("tearing_control.zig");
const XdgActivation = @import("xdg_activation.zig");

fn safeModeEnabled() bool {
    const value = std.process.getEnvVarOwned(std.heap.page_allocator, "AXIA_SAFE_PROTOCOLS") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return true,
        else => return true,
    };
    defer std.heap.page_allocator.free(value);

    return std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes") or
        std.ascii.eqlIgnoreCase(value, "on");
}

pub const ProtocolRegistry = struct {
    allocator: std.mem.Allocator,
    display: *c.struct_wl_display,
    backend: [*c]c.struct_wlr_backend,
    renderer: [*c]c.struct_wlr_renderer,
    output_layout: [*c]c.struct_wlr_output_layout,
    seat: [*c]c.struct_wlr_seat,
    cursor: [*c]c.struct_wlr_cursor,
    xcursor_manager: [*c]c.struct_wlr_xcursor_manager,
    lock_root: [*c]c.struct_wlr_scene_tree,

    core: CoreProtocols,
    shm: [*c]c.struct_wlr_shm,
    linux_dmabuf: [*c]c.struct_wlr_linux_dmabuf_v1,
    viewporter: [*c]c.struct_wlr_viewporter,
    xdg_output: [*c]c.struct_wlr_xdg_output_manager_v1,
    fractional_scale: [*c]c.struct_wlr_fractional_scale_manager_v1,
    cursor_shape: CursorShape.Manager,
    presentation: [*c]c.struct_wlr_presentation,
    xdg_activation: XdgActivation.Manager,
    foreign_toplevel: ForeignToplevel.Manager,
    ext_foreign_toplevel_list: ExtForeignToplevelList.Manager,
    output_management: OutputManagement.Manager,
    output_power_management: OutputPowerManagement.Manager,
    pointer_constraints: PointerConstraints.Manager,
    relative_pointer: RelativePointer.Manager,
    screencopy: Screencopy.Manager,
    session_lock: SessionLock.Manager,
    idle_notify: IdleNotify.Manager,
    idle_inhibit: IdleInhibit.Manager,
    keyboard_shortcuts_inhibit: KeyboardShortcutsInhibit.Manager,
    ext_workspace: *ExtWorkspace.Manager,
    selection: Selection.Manager,
    content_type: ContentType.Manager,
    tearing_control: TearingControl.Manager,

    pub fn init(
        allocator: std.mem.Allocator,
        display: *c.struct_wl_display,
        backend: [*c]c.struct_wlr_backend,
        renderer: [*c]c.struct_wlr_renderer,
        output_layout: [*c]c.struct_wlr_output_layout,
        seat: [*c]c.struct_wlr_seat,
        cursor: [*c]c.struct_wlr_cursor,
        xcursor_manager: [*c]c.struct_wlr_xcursor_manager,
        lock_root: [*c]c.struct_wlr_scene_tree,
    ) !ProtocolRegistry {
        const safe_mode = safeModeEnabled();
        const core = try CoreProtocols.init(display, renderer);

        const shm = c.wlr_shm_create_with_renderer(display, 1, renderer);
        if (shm == null) return error.ShmCreateFailed;

        const linux_dmabuf = c.wlr_linux_dmabuf_v1_create_with_renderer(display, 5, renderer);
        if (linux_dmabuf == null) return error.LinuxDmabufCreateFailed;

        const viewporter = c.wlr_viewporter_create(display);
        if (viewporter == null) return error.ViewporterCreateFailed;

        const xdg_output = if (!safe_mode)
            (c.wlr_xdg_output_manager_v1_create(display, output_layout) orelse return error.XdgOutputManagerCreateFailed)
        else
            null;

        const fractional_scale = if (!safe_mode)
            (c.wlr_fractional_scale_manager_v1_create(display, 1) orelse return error.FractionalScaleManagerCreateFailed)
        else
            null;

        var cursor_shape = try CursorShape.Manager.init(display, seat, cursor, xcursor_manager);
        errdefer cursor_shape.deinit();

        const presentation = if (!safe_mode)
            (c.wlr_presentation_create(display, backend) orelse return error.PresentationCreateFailed)
        else
            null;

        var xdg_activation = try XdgActivation.Manager.init(display);
        errdefer xdg_activation.deinit();

        var foreign_toplevel = try ForeignToplevel.Manager.init(allocator, display);
        errdefer foreign_toplevel.deinit();

        var ext_foreign_toplevel_list = try ExtForeignToplevelList.Manager.init(allocator, display);
        errdefer ext_foreign_toplevel_list.deinit();

        var output_management = try OutputManagement.Manager.init(display, backend, output_layout);
        errdefer output_management.deinit();

        var output_power_management = try OutputPowerManagement.Manager.init(display);
        errdefer output_power_management.deinit();

        var pointer_constraints = try PointerConstraints.Manager.init(allocator, display, seat, cursor);
        errdefer pointer_constraints.deinit();

        var relative_pointer = try RelativePointer.Manager.init(display, seat);
        errdefer relative_pointer.deinit();

        var screencopy = try Screencopy.Manager.init(display);
        errdefer screencopy.deinit();

        var idle_notify = try IdleNotify.Manager.init(display);
        errdefer idle_notify.deinit();

        var idle_inhibit = try IdleInhibit.Manager.init(allocator, display, idle_notify.notifier);
        errdefer idle_inhibit.deinit();

        var keyboard_shortcuts_inhibit = try KeyboardShortcutsInhibit.Manager.init(allocator, display, seat);
        errdefer keyboard_shortcuts_inhibit.deinit();

        var session_lock = try SessionLock.Manager.init(allocator, display, output_layout, seat, lock_root);
        errdefer session_lock.deinit();

        const ext_workspace = try ExtWorkspace.Manager.create(allocator, display, 4);
        errdefer ext_workspace.destroy();

        var selection = try Selection.Manager.init(display, seat);
        errdefer selection.deinit();

        var content_type = try ContentType.Manager.init(display);
        errdefer content_type.deinit();

        var tearing_control = try TearingControl.Manager.init(display);
        errdefer tearing_control.deinit();

        // Temporarily keep cursor-shape advertised but avoid handling its
        // requests until the shell-v2 startup path is fully stabilized.
        output_power_management.setupListeners();
        idle_inhibit.setupListeners();
        keyboard_shortcuts_inhibit.setupListeners();
        session_lock.setupListeners();
        selection.setupListeners();
        pointer_constraints.setupListeners();

        return .{
            .allocator = allocator,
            .display = display,
            .backend = backend,
            .renderer = renderer,
            .output_layout = output_layout,
            .seat = seat,
            .cursor = cursor,
            .xcursor_manager = xcursor_manager,
            .lock_root = lock_root,
            .core = core,
            .shm = shm,
            .linux_dmabuf = linux_dmabuf,
            .viewporter = viewporter,
            .xdg_output = xdg_output,
            .fractional_scale = fractional_scale,
            .cursor_shape = cursor_shape,
            .presentation = presentation,
            .xdg_activation = xdg_activation,
            .foreign_toplevel = foreign_toplevel,
            .ext_foreign_toplevel_list = ext_foreign_toplevel_list,
            .output_management = output_management,
            .output_power_management = output_power_management,
            .pointer_constraints = pointer_constraints,
            .relative_pointer = relative_pointer,
            .screencopy = screencopy,
            .session_lock = session_lock,
            .idle_notify = idle_notify,
            .idle_inhibit = idle_inhibit,
            .keyboard_shortcuts_inhibit = keyboard_shortcuts_inhibit,
            .ext_workspace = ext_workspace,
            .selection = selection,
            .content_type = content_type,
            .tearing_control = tearing_control,
        };
    }

    pub fn setXdgActivationCallback(
        self: *ProtocolRegistry,
        ctx: ?*anyopaque,
        callback: XdgActivation.FocusSurfaceCallback,
    ) void {
        self.xdg_activation.setFocusCallback(ctx, callback);
    }

    pub fn setOutputLayoutAppliedCallback(
        self: *ProtocolRegistry,
        ctx: ?*anyopaque,
        callback: OutputManagement.LayoutAppliedCallback,
    ) void {
        self.output_management.setLayoutAppliedCallback(ctx, callback);
    }

    pub fn setOutputPowerAppliedCallback(
        self: *ProtocolRegistry,
        ctx: ?*anyopaque,
        callback: OutputPowerManagement.ModeAppliedCallback,
    ) void {
        self.output_power_management.setModeAppliedCallback(ctx, callback);
    }

    pub fn publishOutputConfiguration(self: *ProtocolRegistry, outputs: []const *Output) !void {
        try self.output_management.publishCurrentConfiguration(outputs);
    }

    pub fn setForeignToplevelActionCallbacks(
        self: *ProtocolRegistry,
        ctx: ?*anyopaque,
        activate_view_cb: ForeignToplevel.ActivateViewCallback,
        close_view_cb: ForeignToplevel.CloseViewCallback,
        set_view_minimized_cb: ForeignToplevel.SetViewMinimizedCallback,
        set_view_maximized_cb: ForeignToplevel.SetViewMaximizedCallback,
        set_view_fullscreen_cb: ForeignToplevel.SetViewFullscreenCallback,
    ) void {
        self.foreign_toplevel.setActionCallbacks(
            ctx,
            activate_view_cb,
            close_view_cb,
            set_view_minimized_cb,
            set_view_maximized_cb,
            set_view_fullscreen_cb,
        );
    }

    pub fn registerForeignToplevelView(
        self: *ProtocolRegistry,
        view: *View,
        focused: bool,
        output: ?[*c]c.struct_wlr_output,
    ) void {
        self.foreign_toplevel.registerView(view, focused, output) catch {};
        self.ext_foreign_toplevel_list.registerView(view) catch {};
    }

    pub fn syncForeignToplevelView(
        self: *ProtocolRegistry,
        view: *View,
        focused: bool,
        output: ?[*c]c.struct_wlr_output,
    ) void {
        self.foreign_toplevel.syncView(view, focused, output);
        self.ext_foreign_toplevel_list.syncView(view);
    }

    pub fn unregisterForeignToplevelView(self: *ProtocolRegistry, view: *View) void {
        self.foreign_toplevel.unregisterView(view);
        self.ext_foreign_toplevel_list.unregisterView(view);
    }

    pub fn sessionLockActive(self: *const ProtocolRegistry) bool {
        return self.session_lock.isLocked();
    }

    pub fn handleSessionLockPointerMotion(self: *ProtocolRegistry, time_msec: u32, lx: f64, ly: f64) bool {
        return self.session_lock.handlePointerMotion(time_msec, lx, ly);
    }

    pub fn handleSessionLockPointerButton(
        self: *ProtocolRegistry,
        time_msec: u32,
        button: u32,
        state: c.enum_wl_pointer_button_state,
        lx: f64,
        ly: f64,
    ) bool {
        return self.session_lock.handlePointerButton(time_msec, button, state, lx, ly);
    }

    pub fn notifyInputActivity(self: *ProtocolRegistry) void {
        self.idle_notify.notifyActivity(self.seat);
    }

    pub fn reconfigureSessionLockSurfaces(self: *ProtocolRegistry) void {
        self.session_lock.reconfigureSurfaces();
    }

    pub fn resetCursorToDefault(self: *ProtocolRegistry) void {
        self.cursor_shape.resetToDefault();
    }

    pub fn sendRelativePointerMotion(
        self: *ProtocolRegistry,
        time_msec: u32,
        dx: f64,
        dy: f64,
        dx_unaccel: f64,
        dy_unaccel: f64,
    ) void {
        self.relative_pointer.sendRelativeMotion(time_msec, dx, dy, dx_unaccel, dy_unaccel);
    }

    pub fn applyPointerConstraintMotion(
        self: *ProtocolRegistry,
        old_x: f64,
        old_y: f64,
        lx: *f64,
        ly: *f64,
    ) PointerConstraints.MotionDisposition {
        return self.pointer_constraints.applyMotion(old_x, old_y, lx, ly);
    }

    pub fn syncPointerConstraintFocus(
        self: *ProtocolRegistry,
        focused_surface: ?[*c]c.struct_wlr_surface,
        lx: f64,
        ly: f64,
    ) void {
        self.pointer_constraints.syncFocus(focused_surface, lx, ly);
    }

    pub fn syncKeyboardShortcutsInhibitFocus(
        self: *ProtocolRegistry,
        focused_surface: ?[*c]c.struct_wlr_surface,
    ) void {
        self.keyboard_shortcuts_inhibit.syncFocus(focused_surface);
    }

    pub fn keyboardShortcutsInhibited(self: *const ProtocolRegistry) bool {
        return self.keyboard_shortcuts_inhibit.shortcutsInhibited();
    }

    pub fn surfaceContentType(
        self: *const ProtocolRegistry,
        surface: [*c]c.struct_wlr_surface,
    ) @TypeOf(c.wlr_surface_get_content_type_v1(self.content_type.manager, surface)) {
        return self.content_type.surfaceContentType(surface);
    }

    pub fn surfaceTearingHint(
        self: *const ProtocolRegistry,
        surface: [*c]c.struct_wlr_surface,
    ) @TypeOf(c.wlr_tearing_control_manager_v1_surface_hint_from_surface(self.tearing_control.manager, surface)) {
        return self.tearing_control.surfaceHint(surface);
    }

    pub fn setWorkspaceActivateCallback(
        self: *ProtocolRegistry,
        ctx: ?*anyopaque,
        callback: ExtWorkspace.ActivateWorkspaceCallback,
    ) void {
        self.ext_workspace.setActivateCallback(ctx, callback);
    }

    pub fn publishWorkspaceState(self: *ProtocolRegistry, active_workspace: usize, workspace_count: usize) void {
        self.ext_workspace.publishState(active_workspace, workspace_count);
    }

    pub fn deinit(self: *ProtocolRegistry) void {
        self.selection.deinit();
        self.ext_workspace.destroy();
        self.keyboard_shortcuts_inhibit.deinit();
        self.idle_inhibit.deinit();
        self.idle_notify.deinit();
        self.session_lock.deinit();
        self.screencopy.deinit();
        self.relative_pointer.deinit();
        self.pointer_constraints.deinit();
        self.output_power_management.deinit();
        self.output_management.deinit();
        self.ext_foreign_toplevel_list.deinit();
        self.foreign_toplevel.deinit();
        self.xdg_activation.deinit();
        self.cursor_shape.deinit();
        self.tearing_control.deinit();
        self.content_type.deinit();
        _ = self.allocator;
        _ = self.display;
        _ = self.backend;
        _ = self.renderer;
        _ = self.output_layout;
        _ = self.seat;
        _ = self.cursor;
        _ = self.xcursor_manager;
        _ = self.lock_root;
        _ = self.shm;
        _ = self.linux_dmabuf;
        _ = self.viewporter;
        _ = self.xdg_output;
        _ = self.fractional_scale;
        _ = self.cursor_shape;
        _ = self.presentation;
        _ = self.xdg_activation;
        _ = self.foreign_toplevel;
        _ = self.ext_foreign_toplevel_list;
        _ = self.output_management;
        _ = self.output_power_management;
        _ = self.pointer_constraints;
        _ = self.relative_pointer;
        _ = self.screencopy;
        _ = self.session_lock;
        _ = self.idle_notify;
        _ = self.idle_inhibit;
        _ = self.keyboard_shortcuts_inhibit;
        _ = self.ext_workspace;
        _ = self.selection;
        _ = self.content_type;
        _ = self.tearing_control;
        // Most wlroots globals are owned by the display and are cleaned up when
        // the compositor tears down the wl_display. Keep explicit teardown here
        // only for future protocol modules that require it.
    }
};
