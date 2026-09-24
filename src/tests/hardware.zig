const std = @import("std");
const uefi = std.os.uefi;
const kernel = @import("os_kernel");
const irq = kernel.interrupts;
const apic = kernel.apic;
const keyboard = kernel.keyboard;
const io = kernel.io;
const serial = @import("serial.zig");
const runner = @import("test_runner.zig");

fn check(ok: bool, message: []const u8) void {
    if (!ok) {
        serial.writeString(message);
        runner.exitQemu(.Failed);
    }
}
fn failed(err: anyerror) noreturn {
    serial.writeString(@errorName(err));
    runner.exitQemu(.Failed);
}
fn fault(_: *const irq.InterruptFrame) noreturn {
    serial.writeString("Unexpected breakpoint");
    runner.exitQemu(.Failed);
}
fn doubleFault(_: *const irq.InterruptFrame, _: u64) noreturn {
    serial.writeString("Unexpected double fault");
    runner.exitQemu(.Failed);
}
var ticks: u32 = 0;
fn tick() void {
    check(apic.in_service(apic.timer_vector), "Timer not in service\n");
    asm volatile ("int $0xff" ::: .{ .memory = true });
    check(apic.in_service(apic.timer_vector), "Spurious interrupt sent an EOI\n");
    _ = @atomicRmw(u32, &ticks, .Add, 1, .monotonic);
}
fn decoderTests() void {
    var d: keyboard.Decoder = .{};
    check(d.feed(0x1e) == 'a', "Plain key\n");
    check(d.feed(0x9e) == null, "Release generated text\n");
    _ = d.feed(0x2a);
    check(d.feed(0x1e) == 'A' and d.feed(0x02) == '!', "Shift\n");
    _ = d.feed(0x36);
    _ = d.feed(0xaa);
    check(d.feed(0x1e) == 'A', "Independent shift keys\n");
    _ = d.feed(0xb6);
    _ = d.feed(0x3a);
    _ = d.feed(0x3a);
    check(d.feed(0x1e) == 'A', "Caps repeat toggled twice\n");
    _ = d.feed(0xba);
    _ = d.feed(0x2a);
    check(d.feed(0x1e) == 'a' and d.feed(0x02) == '!', "Caps/shift\n");
    _ = d.feed(0xaa);
    _ = d.feed(0xe0);
    _ = d.feed(0x2a);
    check(!d.left_shift, "Print Screen changed shift\n");
    for ([_]u8{ 0xe1, 0x1d, 0x45, 0xe1, 0x9d, 0xc5 }) |b| check(d.feed(b) == null, "Pause generated text\n");
    check(d.feed(0x30) == 'B', "Pause poisoned decoder\n");
    check(d.feed(0x1c) == '\n' and d.feed(0x0e) == 8, "Enter/backspace\n");
    const scans = [_]u8{ 0x4b, 0x4d, 0x48, 0x50, 0x47, 0x4f, 0x53 };
    const keys = [_]u8{ keyboard.Key.left, keyboard.Key.right, keyboard.Key.up, keyboard.Key.down, keyboard.Key.home, keyboard.Key.end, keyboard.Key.delete };
    for (scans, keys) |scan, key| {
        check(d.feed(0xe0) == null and d.feed(scan) == key, "Navigation make\n");
        check(d.feed(0xe0) == null and d.feed(scan | 0x80) == null, "Navigation break\n");
    }
    serial.writeString("Decoder checks passed\n");
}
fn clobberRegisters() void {
    const flags = asm volatile ("pushfq; popq %[flags]"
        : [flags] "=r" (-> u64),
        :
        : .{ .memory = true });
    check(flags & 0x400 == 0, "IRQ entered Zig with DF set\n");
    asm volatile (
        \\ xorq %rax, %rax
        \\ xorq %r10, %r10
        \\ xorq %r11, %r11
        \\ pxor %xmm0, %xmm0
        ::: .{ .rax = true, .r10 = true, .r11 = true, .xmm0 = true });
}
fn registerTest() void {
    irq.register_irq(0x50, clobberRegisters);
    const restored = asm volatile (
        \\ movq $0x1234, %rax
        \\ movq $0x5678, %r10
        \\ movq $0x9876, %r11
        \\ movq %rax, %xmm0
        \\ std
        \\ int $0x50
        \\ pushfq
        \\ popq %rdx
        \\ cld
        \\ testq $0x400, %rdx
        \\ jz 1f
        \\ cmpq $0x1234, %rax
        \\ jne 1f
        \\ cmpq $0x5678, %r10
        \\ jne 1f
        \\ cmpq $0x9876, %r11
        \\ jne 1f
        \\ movq %xmm0, %rcx
        \\ cmpq $0x1234, %rcx
        \\ jne 1f
        \\ movl $1, %eax
        \\ jmp 2f
        \\ 1: xorl %eax, %eax
        \\ 2:
        : [result] "={eax}" (-> u32),
        :
        : .{ .rcx = true, .rdx = true, .r10 = true, .r11 = true, .xmm0 = true, .memory = true });
    check(restored == 1, "IRQ did not preserve GPR/SSE/RFLAGS\n");
    serial.writeString("Returning IRQ preserves GPR/SSE/RFLAGS\n");
}

fn madtChecksum(bytes: []u8) void {
    bytes[9] = 0;
    var sum: u8 = 0;
    for (bytes) |byte| sum +%= byte;
    bytes[9] = 0 -% sum;
}
fn acpiTests() void {
    var bytes: [78]u8 = @splat(0);
    @memcpy(bytes[0..4], "APIC");
    std.mem.writeInt(u32, bytes[4..8], bytes.len, .little);
    std.mem.writeInt(u32, bytes[36..40], 0xfee00000, .little);
    bytes[40] = 1;
    // I/O APIC with GSI base 0.
    bytes[44] = 1;
    bytes[45] = 12;
    std.mem.writeInt(u32, bytes[48..52], 0xfec00000, .little);
    // Override IRQ1 -> GSI9, active-low and level-triggered.
    bytes[56] = 2;
    bytes[57] = 10;
    bytes[59] = 1;
    bytes[60] = 9;
    bytes[64] = 15;
    // 64-bit local APIC address override.
    bytes[66] = 5;
    bytes[67] = 12;
    std.mem.writeInt(u64, bytes[70..78], 0xfee01000, .little);
    madtChecksum(&bytes);
    const parsed = kernel.acpi.parseMadt(&bytes) catch |err| failed(err);
    check(parsed.lapic_address == 0xfee01000 and parsed.io_apic_count == 1, "MADT addresses\n");
    check(parsed.isa[1].gsi == 9 and parsed.isa[1].active_low and parsed.isa[1].level, "MADT override\n");
    check(parsed.isa[3].gsi == 3 and !parsed.isa[3].level, "MADT ISA defaults\n");
    bytes[9] +%= 1;
    if (kernel.acpi.parseMadt(&bytes)) |_| {
        check(false, "MADT checksum accepted\n");
    } else |_| {}
    bytes[57] = 0;
    madtChecksum(&bytes);
    if (kernel.acpi.parseMadt(&bytes)) |_| {
        check(false, "MADT zero-length record accepted\n");
    } else |_| {}
    bytes[57] = 30;
    madtChecksum(&bytes);
    if (kernel.acpi.parseMadt(&bytes)) |_| {
        check(false, "MADT truncated record accepted\n");
    } else |_| {}
    serial.writeString("MADT parsing/overrides and malformed-table checks passed\n");
}

fn inject(byte: u8) void {
    irq.disable();
    const before = @atomicLoad(u32, &keyboard.interrupt_count, .monotonic);
    // i8042 command D2 produces a real IRQ1 through the I/O APIC. It does not
    // call the decoder directly, so this tests routing, entry, queueing and EOI.
    var ready = false;
    for (0..100_000) |_| {
        if (io.inb(0x64) & 2 == 0) {
            ready = true;
            break;
        }
    }
    check(ready, "Controller busy\n");
    io.outb(0x64, 0xd2);
    ready = false;
    for (0..100_000) |_| {
        if (io.inb(0x64) & 2 == 0) {
            ready = true;
            break;
        }
    }
    check(ready, "Controller busy after D2\n");
    io.outb(0x60, byte);
    while (@atomicLoad(u32, &keyboard.interrupt_count, .monotonic) == before) {
        irq.wait_for_interrupt();
        irq.disable();
    }
    check(!apic.in_service(apic.keyboard_vector), "Keyboard EOI missing\n");
}

pub fn main() uefi.Status {
    serial.initSerial();
    decoderTests();
    acpiTests();
    const topology = kernel.acpi.discover() catch |err| failed(err);
    const bs = uefi.system_table.boot_services.?;
    var buffer: [32 * 1024]u8 align(@alignOf(uefi.tables.MemoryDescriptor)) = undefined;
    const map = bs.getMemoryMap(&buffer) catch |err| failed(err);
    bs.exitBootServices(uefi.handle, map.info.key) catch |err| failed(err);
    irq.init_gdt();
    irq.init_idt_with_handlers(.{ .breakpoint = fault, .double_fault = doubleFault });
    kernel.memory.init(map) catch |err| failed(err);
    apic.init(topology) catch |err| failed(err);
    check(!irq.enabled(), "APIC init enabled IRQs too early\n");
    registerTest();
    for (1..3) |expected| {
        apic.start_timer(100_000, tick);
        while (@atomicLoad(u32, &ticks, .monotonic) < expected) {
            irq.wait_for_interrupt();
            irq.disable();
        }
        check(!apic.in_service(apic.timer_vector), "Timer EOI missing\n");
    }
    // Spurious delivery must return without changing APIC in-service state.
    asm volatile ("int $0xff" ::: .{ .memory = true });
    serial.writeString("APIC timer delivered twice and returned with EOI\n");
    keyboard.init() catch |err| failed(err);
    inject(0x1e);
    check(keyboard.pop() == 'a', "IRQ1 did not enqueue a\n");
    inject(0x9e);
    check(keyboard.pop() == null, "Release enqueued text\n");
    inject(0x2a);
    inject(0x30);
    check(keyboard.pop() == 'B', "Shifted IRQ input\n");
    inject(0xaa);
    inject(0x1c);
    check(keyboard.pop() == '\n', "Enter IRQ input\n");
    for (0..140) |_| inject(0x1e);
    check(@atomicLoad(u32, &keyboard.dropped, .monotonic) == 13, "Queue overflow count\n");
    for (0..127) |_| check(keyboard.pop() == 'a', "Queue FIFO/overflow\n");
    check(keyboard.pop() == null, "Queue not empty\n");
    inject(0x30);
    check(keyboard.pop() == 'b', "Queue wrap recovery\n");
    check(apic.errors == 0, "APIC error status\n");
    serial.writeString("IRQ1 routing, decoding, queue wrap/overflow and EOI passed\n");
    runner.exitQemu(.Success);
}
