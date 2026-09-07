const std = @import("std");
const uefi = std.os.uefi;
const serial = @import("serial.zig");

const test_runner = @import("test_runner.zig");

pub fn main() uefi.Status {
    serial.initSerial();

    serial.writeChar('A');
    serial.writeChar('B');
    serial.writeChar('C');
    serial.writeChar('\r');
    serial.writeChar('\n');

    serial.writeString("Hello world!\n");

    test_runner.exitQemu(test_runner.QemuExitCode.Success);

    while (true) {
        asm volatile ("hlt");
    }
}
