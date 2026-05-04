const c = @import("../wl.zig").c;

pub const ProtocolGlobals = struct {
    compositor: [*c]c.struct_wlr_compositor,
    subcompositor: [*c]c.struct_wlr_subcompositor,
    data_device_manager: [*c]c.struct_wlr_data_device_manager,
    layer_shell: [*c]c.struct_wlr_layer_shell_v1,

    pub fn init(
        display: *c.struct_wl_display,
        renderer: [*c]c.struct_wlr_renderer,
    ) !ProtocolGlobals {
        const compositor = c.wlr_compositor_create(display, 6, renderer);
        if (compositor == null) return error.CompositorCreateFailed;

        const subcompositor = c.wlr_subcompositor_create(display);
        if (subcompositor == null) return error.SubcompositorCreateFailed;

        const data_device_manager = c.wlr_data_device_manager_create(display);
        if (data_device_manager == null) return error.DataDeviceManagerCreateFailed;

        const layer_shell = c.wlr_layer_shell_v1_create(display, 4);
        if (layer_shell == null) return error.LayerShellCreateFailed;

        return .{
            .compositor = compositor,
            .subcompositor = subcompositor,
            .data_device_manager = data_device_manager,
            .layer_shell = layer_shell,
        };
    }
};
