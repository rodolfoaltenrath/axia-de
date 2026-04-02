const c = @import("../wl.zig").c;

pub fn drawSolid(
    render_pass: ?*c.struct_wlr_render_pass,
    width: i32,
    height: i32,
) void {
    var rect = c.struct_wlr_render_rect_options{};
    rect.box.x = 0;
    rect.box.y = 0;
    rect.box.width = width;
    rect.box.height = height;
    rect.color.r = 0.04;
    rect.color.g = 0.05;
    rect.color.b = 0.06;
    rect.color.a = 1.0;
    rect.blend_mode = c.WLR_RENDER_BLEND_MODE_NONE;

    c.wlr_render_pass_add_rect(render_pass, &rect);
}
