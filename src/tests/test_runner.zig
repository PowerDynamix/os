const std = @import("std");
const builtin = @import("builtin");

const serial = @import("serial.zig");

const TestCase = struct {
    name: []const u8,
    run: *const fn () anyerror!void,
};

pub const QemuExitCode = enum(u32) {
    Success = 0x10,
    Failed = 0x11,
};

pub fn exitQemu(code: QemuExitCode) noreturn {
    // Example: Port 0xf4 is the QEMU isa-debug-exit device
    // Writing code to it shuts down QEMU with a specific exit status
    const port = @as(u16, 0xf4);

    const code_byte = @as(u8, @intCast(@intFromEnum(code)));

    switch (code) {
        QemuExitCode.Success => {
            serial.writeString("\n[OK]\n");
        },
        QemuExitCode.Failed => {
            serial.writeString("\n[FAILED]\n");
        },
    }

    asm volatile ("outb %[code], %[port]"
        :
        : [code] "{al}" (code_byte),
          [port] "{dx}" (port),
    );
    while (true) {}
}
