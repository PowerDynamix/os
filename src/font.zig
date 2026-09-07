const std = @import("std");
const uefi = std.os.uefi;

const PSF2_MAGIC: [4]u8 = .{ 0x72, 0xb5, 0x4a, 0x86 };

pub const FontError = error{
    InvalidMagic,
    HeaderTooSmall,
    BufferOverflow,
};

const Psf2Header = extern struct {
    magic: [4]u8,
    version: u32,
    header_size: u32,
    flags: u32,
    length: u32, // Total number of glyphs
    char_size: u32, // Byte size of each individual glyph
    height: u32, // Height of glyph in pixels
    width: u32, // Width of glyph in pixels
};

pub const Font = struct {
    width: u32,
    height: u32,
    char_size: u32,
    header_size: u32,
    glyphs: []const u8,
};

pub fn loadFont(raw_bytes: []const u8) FontError!Font {
    // 1. Ensure memory context contains at least enough bytes for structural parsing
    if (raw_bytes.len < @sizeOf(Psf2Header)) {
        return FontError.HeaderTooSmall;
    }

    // 2. Explicitly cast to an unaligned pointer (align(1)) to prevent alignment panics
    const header = @as(*align(1) const Psf2Header, @ptrCast(raw_bytes.ptr));

    // 3. Confirm that the resource signature exactly matches the PSF2 magic array
    if (!std.mem.eql(u8, &header.magic, &PSF2_MAGIC)) {
        return FontError.InvalidMagic;
    }

    // 4. Calculate total byte dimensions needed to process the full character map
    const total_glyphs_size = header.length * header.char_size;
    const required_file_size = header.header_size + total_glyphs_size;

    // 5. Bounds-check memory array to guarantee buffer overflows don't occur downstream
    if (raw_bytes.len < required_file_size) {
        return FontError.BufferOverflow;
    }

    // 6. Slice out and return just the active glyph data array for rendering loops
    return Font{
        .width = header.width,
        .height = header.height,
        .char_size = header.char_size,
        .header_size = header.header_size,
        .glyphs = raw_bytes[header.header_size..required_file_size],
    };
}
