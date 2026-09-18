//! Boot-CPU xAPIC and I/O APIC support. MMIO must remain identity-mapped and
//! uncacheable as configured by UEFI. x2APIC is rejected; application processors are not started.
const acpi = @import("acpi.zig");
const irq = @import("interrputs.zig");
const io = @import("io.zig");
const std = @import("std");

pub const keyboard_vector: u8 = 0x31;
pub const timer_vector: u8 = 0x40;
const error_vector: u8 = 0xfe;
const masked: u32 = 1 << 16;
var lapic: usize = 0;
var topology: acpi.Topology = undefined;
var pin_counts: [8]u32 = @splat(0);
var destination: u8 = 0;
pub var errors: u32 = 0;

fn rdmsr(index: u32) u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [index] "{ecx}" (index),
    );
    return @as(u64, high) << 32 | low;
}
fn wrmsr(index: u32, value: u64) void {
    asm volatile ("wrmsr"
        :
        : [index] "{ecx}" (index),
          [low] "{eax}" (@as(u32, @truncate(value))),
          [high] "{edx}" (@as(u32, @truncate(value >> 32))),
        : .{ .memory = true });
}
fn read(offset: usize) u32 {
    const ptr: *volatile u32 = @ptrFromInt(lapic + offset);
    return ptr.*;
}
fn write(offset: usize, value: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(lapic + offset);
    ptr.* = value;
    _ = read(0x20); // Flush posted MMIO writes.
}
fn ioRead(index: usize, reg: u32) u32 {
    const select: *volatile u32 = @ptrFromInt(topology.io_apics[index].address);
    const window: *volatile u32 = @ptrFromInt(topology.io_apics[index].address + 0x10);
    select.* = reg;
    return window.*;
}
fn ioWrite(index: usize, reg: u32, value: u32) void {
    const select: *volatile u32 = @ptrFromInt(topology.io_apics[index].address);
    const window: *volatile u32 = @ptrFromInt(topology.io_apics[index].address + 0x10);
    select.* = reg;
    window.* = value;
}
fn eoi() void {
    write(0xb0, 0);
}
fn apicError() void {
    write(0x280, 0);
    errors |= read(0x280);
}

/// Call after GDT/IDT setup. All device routes remain masked and IF stays clear.
pub fn init(config: acpi.Topology) !void {
    irq.disable();
    var features: u32 = undefined;
    asm volatile ("cpuid"
        : [features] "={edx}" (features),
        : [leaf] "{eax}" (@as(u32, 1)),
        : .{ .eax = true, .ebx = true, .ecx = true });
    if (features & (1 << 9) == 0) return error.NoLocalApic;
    const base = rdmsr(0x1b);
    if (base & (1 << 10) != 0) return error.X2ApicUnsupported;
    if (config.lapic_address != base & 0x0000_000f_ffff_f000) return error.LapicAddressMismatch;
    topology = config;
    lapic = @intCast(config.lapic_address);
    irq.init_hardware(eoi);
    irq.register_irq(error_vector, apicError);

    // Stop legacy PIC delivery before accepting external APIC vectors.
    if (config.legacy_pic) {
        io.outb(0x21, 0xff);
        io.outb(0xa1, 0xff);
    }
    wrmsr(0x1b, base | (1 << 11));
    destination = @truncate(read(0x20) >> 24);
    write(0xf0, irq.spurious_vector); // Software-disable during configuration.
    write(0x320, masked); // Timer
    write(0x350, masked); // LINT0 (firmware ExtINT/PIC path)
    write(0x360, masked); // LINT1
    const max_lvt = (read(0x30) >> 16) & 0xff;
    if (max_lvt >= 4) write(0x340, masked); // Performance counter
    if (max_lvt >= 5) write(0x330, masked); // Thermal sensor
    if (max_lvt >= 6) write(0x2f0, masked); // Corrected machine check
    write(0x370, masked | error_vector);
    write(0x280, 0);
    _ = read(0x280);
    for (0..topology.io_apic_count) |index| {
        pin_counts[index] = ((ioRead(index, 1) >> 16) & 0xff) + 1;
        if (pin_counts[index] > 120) return error.UnsupportedIoApic;
        for (0..pin_counts[index]) |pin| {
            const reg: u32 = 0x10 + @as(u32, @intCast(pin)) * 2;
            ioWrite(index, reg, masked);
            ioWrite(index, reg + 1, @as(u32, destination) << 24);
        }
    }
    write(0x80, 0); // Task priority: accept every external vector priority.
    write(0xf0, 0x100 | @as(u32, irq.spurious_vector));
    write(0x370, error_vector);
}

/// Install the callback before unmasking its physical-destination fixed route.
/// MADT overrides supply GSI, polarity and trigger mode for ISA devices.
pub fn route_isa(isa_irq: u4, vector: u8, handler: irq.IrqHandler) !void {
    std.debug.assert(!irq.enabled());
    if (vector < 32 or vector >= error_vector) return error.InvalidVector;
    const route = topology.isa[isa_irq];
    for (0..topology.io_apic_count) |index| {
        const base = topology.io_apics[index].gsi_base;
        if (route.gsi < base or route.gsi - base >= pin_counts[index]) continue;
        const reg = 0x10 + (route.gsi - base) * 2;
        var low: u32 = vector;
        if (route.active_low) low |= 1 << 13;
        if (route.level) low |= 1 << 15;
        ioWrite(index, reg, low | masked);
        ioWrite(index, reg + 1, @as(u32, destination) << 24);
        irq.register_irq(vector, handler);
        ioWrite(index, reg, low);
        return;
    }
    return error.NoIoApicRoute;
}

/// Uncalibrated one-shot timer, useful for interrupt-delivery tests.
pub fn start_timer(count: u32, handler: irq.IrqHandler) void {
    std.debug.assert(!irq.enabled());
    irq.register_irq(timer_vector, handler);
    write(0x3e0, 0x3); // Divide APIC bus clock by 16.
    write(0x320, timer_vector);
    write(0x380, count);
}
pub fn in_service(vector: u8) bool {
    return read(0x100 + @as(usize, vector / 32) * 0x10) & (@as(u32, 1) << @as(u5, @truncate(vector))) != 0;
}
