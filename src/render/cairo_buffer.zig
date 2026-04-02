const std = @import("std");
const c = @import("../wl.zig").c;

pub const CairoBuffer = struct {
    allocator: std.mem.Allocator,
    base: c.struct_wlr_buffer = undefined,
    pixels: []u8,
    stride: usize,
    width: u32,
    height: u32,
    format: u32 = c.DRM_FORMAT_ARGB8888,
    surface: *c.cairo_surface_t,
    cr: *c.cairo_t,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !*CairoBuffer {
        const stride = width * 4;
        const size: usize = @intCast(stride * height);
        const pixels = try allocator.alloc(u8, size);
        @memset(pixels, 0);
        errdefer allocator.free(pixels);

        const surface = c.cairo_image_surface_create_for_data(
            pixels.ptr,
            c.CAIRO_FORMAT_ARGB32,
            @intCast(width),
            @intCast(height),
            @intCast(stride),
        ) orelse return error.CairoSurfaceCreateFailed;
        if (c.cairo_surface_status(surface) != c.CAIRO_STATUS_SUCCESS) {
            c.cairo_surface_destroy(surface);
            return error.CairoSurfaceCreateFailed;
        }
        errdefer c.cairo_surface_destroy(surface);

        const cr = c.cairo_create(surface) orelse return error.CairoContextCreateFailed;
        if (c.cairo_status(cr) != c.CAIRO_STATUS_SUCCESS) {
            c.cairo_destroy(cr);
            return error.CairoContextCreateFailed;
        }
        errdefer c.cairo_destroy(cr);

        const buffer = try allocator.create(CairoBuffer);
        buffer.* = .{
            .allocator = allocator,
            .pixels = pixels,
            .stride = stride,
            .width = width,
            .height = height,
            .surface = surface,
            .cr = cr,
        };
        c.wlr_buffer_init(&buffer.base, &cairo_buffer_impl, @intCast(width), @intCast(height));
        return buffer;
    }

    pub fn deinit(self: *CairoBuffer) void {
        c.wlr_buffer_drop(&self.base);
    }

    pub fn wlrBuffer(self: *CairoBuffer) *c.struct_wlr_buffer {
        return &self.base;
    }

    fn destroy(buffer: [*c]c.struct_wlr_buffer) callconv(.c) void {
        const cairo_buffer: *CairoBuffer = @ptrCast(@alignCast(@as(*allowzero CairoBuffer, @fieldParentPtr("base", buffer))));
        c.cairo_destroy(cairo_buffer.cr);
        c.cairo_surface_destroy(cairo_buffer.surface);
        cairo_buffer.allocator.free(cairo_buffer.pixels);
        cairo_buffer.allocator.destroy(cairo_buffer);
    }

    fn beginDataPtrAccess(
        buffer: [*c]c.struct_wlr_buffer,
        _: u32,
        data_out: [*c]?*anyopaque,
        format_out: [*c]u32,
        stride_out: [*c]usize,
    ) callconv(.c) bool {
        const cairo_buffer: *CairoBuffer = @ptrCast(@alignCast(@as(*allowzero CairoBuffer, @fieldParentPtr("base", buffer))));
        if (data_out != null) data_out[0] = cairo_buffer.pixels.ptr;
        if (format_out != null) format_out[0] = cairo_buffer.format;
        if (stride_out != null) stride_out[0] = cairo_buffer.stride;
        return true;
    }

    fn endDataPtrAccess(_: [*c]c.struct_wlr_buffer) callconv(.c) void {}
};

const cairo_buffer_impl = c.struct_wlr_buffer_impl{
    .destroy = CairoBuffer.destroy,
    .get_dmabuf = null,
    .get_shm = null,
    .begin_data_ptr_access = CairoBuffer.beginDataPtrAccess,
    .end_data_ptr_access = CairoBuffer.endDataPtrAccess,
};
