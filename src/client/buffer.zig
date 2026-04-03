const std = @import("std");
const c = @import("client_wl").c;

pub const ShmBuffer = struct {
    shm: *c.struct_wl_shm,
    width: u32,
    height: u32,
    stride: usize,
    size: usize,
    fd: std.posix.fd_t,
    memory: []align(std.heap.pageSize()) u8,
    pool: *c.struct_wl_shm_pool,
    buffer: *c.struct_wl_buffer,
    surface: *c.cairo_surface_t,
    cr: *c.cairo_t,

    pub fn init(shm: *c.struct_wl_shm, width: u32, height: u32, name: []const u8) !ShmBuffer {
        const stride = width * 4;
        const size: usize = @intCast(stride * height);

        const fd = try std.posix.memfd_create(name, 0);
        errdefer std.posix.close(fd);

        try std.posix.ftruncate(fd, @intCast(size));

        const memory = try std.posix.mmap(
            null,
            size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        errdefer std.posix.munmap(memory);

        const pool = c.wl_shm_create_pool(shm, fd, @intCast(size)) orelse return error.ShmPoolCreateFailed;
        errdefer c.wl_shm_pool_destroy(pool);

        const buffer = c.wl_shm_pool_create_buffer(
            pool,
            0,
            @intCast(width),
            @intCast(height),
            @intCast(stride),
            c.WL_SHM_FORMAT_ARGB8888,
        ) orelse return error.ShmBufferCreateFailed;
        errdefer c.wl_buffer_destroy(buffer);

        const surface = c.cairo_image_surface_create_for_data(
            memory.ptr,
            c.CAIRO_FORMAT_ARGB32,
            @intCast(width),
            @intCast(height),
            @intCast(stride),
        ) orelse return error.CairoSurfaceCreateFailed;
        if (c.cairo_surface_status(surface) != c.CAIRO_STATUS_SUCCESS) return error.CairoSurfaceCreateFailed;
        errdefer c.cairo_surface_destroy(surface);

        const cr = c.cairo_create(surface) orelse return error.CairoContextCreateFailed;
        if (c.cairo_status(cr) != c.CAIRO_STATUS_SUCCESS) return error.CairoContextCreateFailed;
        errdefer c.cairo_destroy(cr);

        return .{
            .shm = shm,
            .width = width,
            .height = height,
            .stride = stride,
            .size = size,
            .fd = fd,
            .memory = memory,
            .pool = pool,
            .buffer = buffer,
            .surface = surface,
            .cr = cr,
        };
    }

    pub fn deinit(self: *ShmBuffer) void {
        c.cairo_destroy(self.cr);
        c.cairo_surface_destroy(self.surface);
        c.wl_buffer_destroy(self.buffer);
        c.wl_shm_pool_destroy(self.pool);
        std.posix.munmap(self.memory);
        std.posix.close(self.fd);
    }
};
