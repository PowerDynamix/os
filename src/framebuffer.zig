const std = @import("std");
const uefi = std.os.uefi;

pub fn get_gop() !*uefi.protocol.GraphicsOutput {
    const boot_services = uefi.system_table.boot_services.?;

    return try boot_services.locateProtocol(
        uefi.protocol.GraphicsOutput,
        null,
    ) orelse return error.GraphicsOutputNotFound;
}

pub const Framebuffer = struct {
    base: [*]u32,
    width: u32,
    height: u32,
    stride: u32,

    pub fn putPixel(self: *Framebuffer, x: u32, y: u32, color: u32) void {
        if (x >= self.width or y >= self.height) return;

        self.base[y * self.stride + x] = color;
    }

    pub fn clear(self: *Framebuffer, color: u32) void {
        var y: u32 = 0;

        while (y < self.height) : (y += 1) {
            var x: u32 = 0;

            while (x < self.width) : (x += 1) {
                self.putPixel(x, y, color);
            }
        }
    }
};

pub fn fetch_framebuffer() !Framebuffer {
    const gop: ?*uefi.protocol.GraphicsOutput = try get_gop();
    const mode = gop.?.mode;

    return .{
        .base = @ptrFromInt(mode.frame_buffer_base),
        .width = mode.info.horizontal_resolution,
        .height = mode.info.vertical_resolution,
        .stride = mode.info.pixels_per_scan_line,
    };
}
