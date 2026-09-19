const std = @import("std");
const framebuffer = @import("framebuffer.zig");
const fnt = @import("font.zig");

/// Halt the CPU indefinitely.
///
/// This is used when execution cannot safely continue, and after
/// `ExitBootServices` has been called.
fn halt() noreturn {
    while (true) {
        asm volatile ("cli");
        asm volatile ("hlt");
    }
}

pub const Console = struct {
    fb: *framebuffer.Framebuffer,
    font: fnt.Font,

    cursor_x: u32 = 0,
    cursor_y: u32 = 0,

    fg_color: u32 = 0xFFFFFFFF,
    bg_color: u32 = 0x00000000,

    pub fn init(
        fb: *framebuffer.Framebuffer,
        font: fnt.Font,
    ) Console {
        return .{
            .fb = fb,
            .font = font,
        };
    }

    pub fn print(
        self: *Console,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        var buffer: [512]u8 = undefined;

        const string = std.fmt.bufPrint(
            &buffer,
            fmt,
            args,
        ) catch {
            self.putString("[format error]");
            return;
        };

        self.putString(string);
    }

    pub fn println(
        self: *Console,
        string: []const u8,
    ) void {
        self.putString(string);
        self.putChar('\n');
    }

    pub fn putChar(self: *Console, c: u8) void {
        // 1. Handle special non-printable control characters
        switch (c) {
            '\x08' => {
                // Erase one cell on this line without overwriting previous output.
                if (self.cursor_x >= self.font.width) {
                    self.cursor_x -= self.font.width;
                    self.putChar(' ');
                    self.cursor_x -= self.font.width;
                }
                return;
            },
            '\n' => {
                self.newline();
                return;
            },
            '\r' => {
                self.cursor_x = 0;
                return;
            },
            '\t' => {
                // Advance to the next multiple-of-4 character tab stop
                const tab_width = self.font.width * 4;
                self.cursor_x = ((self.cursor_x + tab_width) / tab_width) * tab_width;

                // Wrap to next line if tab moves past right-edge boundary
                if (self.cursor_x + self.font.width > self.fb.width) {
                    self.newline();
                }
                return;
            },
            else => {},
        }

        // 2. Perform automated text-wrap check before drawing
        if (self.cursor_x + self.font.width > self.fb.width) {
            self.newline();
        }

        // 3. Extract target font bitmap row configurations
        const bytes_per_row = (self.font.width + 7) / 8;
        const glyph_offset = @as(usize, c) * self.font.char_size;
        const glyph = self.font.glyphs[glyph_offset .. glyph_offset + self.font.char_size];

        // 4. Render the localized pixel grid directly into the linear framebuffer
        var cy: u32 = 0;
        while (cy < self.font.height) : (cy += 1) {
            var cx: u32 = 0;
            while (cx < self.font.width) : (cx += 1) {
                const byte_index = (cy * bytes_per_row) + (cx / 8);
                const bit_index = @as(u3, @intCast(7 - (cx % 8)));

                const pixel_is_set = ((glyph[byte_index] >> bit_index) & 1) == 1;
                const color = if (pixel_is_set) self.fg_color else self.bg_color;

                self.fb.putPixel(self.cursor_x + cx, self.cursor_y + cy, color);
            }
        }

        // 5. Advance cursor step forward by the character width
        self.cursor_x += self.font.width;
    }

    pub fn putString(self: *Console, string: []const u8) void {
        for (string) |c| {
            self.putChar(c);
        }
    }

    pub fn clear(self: *Console) void {
        self.fb.clear(self.bg_color);
        self.cursor_x = 0;
        self.cursor_y = 0;
    }

    /// Erase the current text row without affecting output above it.
    pub fn clearLine(self: *Console) void {
        const end = @min(self.fb.height, self.cursor_y + self.font.height);
        var y = self.cursor_y;
        while (y < end) : (y += 1) {
            const offset: usize = @as(usize, y) * self.fb.stride;
            @memset(self.fb.base[offset .. offset + self.fb.width], self.bg_color);
        }
        self.cursor_x = 0;
    }

    /// Internal line-break engine that triggers standard full-frame scrolling operations
    fn newline(self: *Console) void {
        self.cursor_x = 0;

        if (self.cursor_y + (self.font.height * 2) > self.fb.height) {
            self.scroll();
        } else {
            self.cursor_y += self.font.height;
        }
    }

    /// Shifts rows upward by one character height and blanks out the trailing line bottom space
    fn scroll(self: *Console) void {
        const shift_src_offset = self.font.height * self.fb.stride;
        const total_shifted_pixels = (self.fb.height - self.font.height) * self.fb.stride;

        // Blit data contents upwards across the primary linear base index
        std.mem.copyForwards(u32, self.fb.base[0..total_shifted_pixels], self.fb.base[shift_src_offset .. shift_src_offset + total_shifted_pixels]);

        // Wipe trailing remaining blank buffer pixels below the new content boundary
        const clear_start = total_shifted_pixels;
        const clear_count = self.font.height * self.fb.stride;
        @memset(self.fb.base[clear_start .. clear_start + clear_count], self.bg_color);

        // Keep y cursor clamped right at the top boundary of the last renderable row block
        self.cursor_y = self.fb.height - self.font.height;
    }

    pub fn panic(self: *Console, comptime fmt: []const u8, args: anytype) noreturn {
        self.print("\n\nKERNEL PANIC!\n", .{});
        self.print("-----------------------------\n", .{});

        var buffer: [512]u8 = undefined;

        const message = std.fmt.bufPrint(
            &buffer,
            fmt,
            args,
        ) catch {
            self.putString("[format error]");
            halt();
            return;
        };

        self.putString(message);

        self.print("\nSystem halted.\n", .{});

        halt();
    }
};

pub var k_console: Console = undefined;
