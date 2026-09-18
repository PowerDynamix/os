const std = @import("std");
const uefi = std.os.uefi;
const interrupts = @import("os_kernel").interrupts;
const runner = @import("test_runner.zig");
const serial = @import("serial.zig");
const scenario = @import("test_options").scenario;

const TablePointer = extern struct {
    limit: u16,
    base: u64 align(1),
};

var emergency_top: usize = 0;
export var breakpoint_resume: usize = 0;

fn check(ok: bool, message: []const u8) void {
    if (!ok) {
        serial.writeString(message);
        runner.exitQemu(.Failed);
    }
}

fn unexpected_breakpoint(_: *const interrupts.InterruptFrame) noreturn {
    serial.writeString("Unexpected breakpoint\n");
    runner.exitQemu(.Failed);
}

fn unexpected_double_fault(_: *const interrupts.InterruptFrame, _: u64) noreturn {
    serial.writeString("Unexpected double fault\n");
    runner.exitQemu(.Failed);
}

fn breakpoint(frame: *const interrupts.InterruptFrame) noreturn {
    check(frame.rip == breakpoint_resume, "Incorrect breakpoint RIP\n");
    check(frame.cs == 8 and frame.ss == 16, "Incorrect saved selectors\n");
    check(frame.rflags & 0x200 == 0, "IRQs unexpectedly enabled\n");
    check(frame.rsp > @intFromPtr(frame), "Incorrect saved RSP\n");
    serial.writeString("Breakpoint delivered with correct frame\n");
    runner.exitQemu(.Success);
}

fn double_fault(frame: *const interrupts.InterruptFrame, error_code: u64) noreturn {
    check(error_code == 0, "Incorrect double-fault error code\n");
    check(frame.cs == 8 and frame.rip != 0, "Incorrect double-fault frame\n");
    const current_rsp = asm volatile ("movq %%rsp, %[result]"
        : [result] "=r" (-> usize),
    );
    const bottom = emergency_top - interrupts.double_fault_stack_size;
    check(current_rsp >= bottom and current_rsp < emergency_top, "Handler not on IST stack\n");
    check(@intFromPtr(frame) >= bottom and @intFromPtr(frame) + @sizeOf(interrupts.InterruptFrame) <= emergency_top, "Frame not on IST stack\n");
    if (comptime std.mem.eql(u8, scenario, "bad-stack")) {
        check(frame.rsp == 0, "Broken stack was not preserved in frame\n");
    } else {
        check(frame.rsp != 0, "Original stack missing from frame\n");
    }
    serial.writeString("Real double fault delivered on emergency stack\n");
    runner.exitQemu(.Success);
}

fn verify_tables() void {
    var idtr: TablePointer = undefined;
    var gdtr: TablePointer = undefined;
    asm volatile ("sidt (%[ptr])"
        :
        : [ptr] "r" (&idtr),
        : .{ .memory = true });
    asm volatile ("sgdt (%[ptr])"
        :
        : [ptr] "r" (&gdtr),
        : .{ .memory = true });
    check(idtr.limit == 4095, "Wrong IDT limit\n");
    check(gdtr.limit == 39, "Wrong GDT limit\n");
    const entries: *const [256]interrupts.IDTEntry = @ptrFromInt(idtr.base);
    for (entries, 0..) |entry, vector| {
        if (vector == 3 or vector == 8) {
            check(entry.kernel_cs == 8 and entry.attributes == 0x8e, "Invalid gate attributes\n");
            check(entry.ist == (if (vector == 8) @as(u8, 1) else 0), "Wrong gate IST\n");
            check(entry.reserved == 0, "Nonzero reserved gate bits\n");
            const address = @as(u64, entry.isr_low) | (@as(u64, entry.isr_mid) << 16) | (@as(u64, entry.isr_high) << 32);
            const expected = if (vector == 3) @intFromPtr(&interrupts.isr_stub_3) else @intFromPtr(&interrupts.isr_stub_8);
            check(address == expected, "Wrong ISR address\n");
        } else {
            check(entry.attributes == 0, "Unexpected present gate\n");
        }
    }
    const tr = asm volatile ("str %[result]"
        : [result] "=r" (-> u16),
    );
    check(tr == 0x18, "Task register not loaded\n");
    const gdt: *const [5]u64 = @ptrFromInt(gdtr.base);
    const low = gdt[3];
    check((low >> 40) & 0xff == 0x8b, "TSS descriptor is not busy/present\n");
    check(low & 0xffff == 103, "Wrong TSS limit\n");
    const tss_address = ((low >> 16) & 0xffffff) | ((low >> 32) & 0xff000000) | (gdt[4] << 32);
    const ist: *align(1) const u64 = @ptrFromInt(tss_address + 36);
    emergency_top = ist.*;
    check(emergency_top != 0 and emergency_top % 16 == 0, "Invalid emergency stack\n");
    const flags = asm volatile ("pushfq; popq %[result]"
        : [result] "=r" (-> u64),
        :
        : .{ .memory = true });
    check(flags & 0x200 == 0, "IDT setup enabled IRQs\n");
}

pub fn main() uefi.Status {
    serial.initSerial();
    const bs = uefi.system_table.boot_services.?;
    var buffer: [32 * 1024]u8 align(@alignOf(uefi.tables.MemoryDescriptor)) = undefined;
    const map = bs.getMemoryMap(&buffer) catch runner.exitQemu(.Failed);
    bs.exitBootServices(uefi.handle, map.info.key) catch runner.exitQemu(.Failed);
    interrupts.init_gdt();
    interrupts.init_idt_with_handlers(.{
        .breakpoint = if (std.mem.eql(u8, scenario, "breakpoint")) breakpoint else unexpected_breakpoint,
        .double_fault = if (std.mem.eql(u8, scenario, "double-fault") or std.mem.eql(u8, scenario, "bad-stack")) double_fault else unexpected_double_fault,
    });
    verify_tables();
    if (comptime std.mem.eql(u8, scenario, "layout")) {
        // Reinitialization must also leave a valid table and loaded TSS.
        interrupts.init_gdt();
        interrupts.init_idt();
        verify_tables();
        serial.writeString("IDT/GDT/TSS layout and reload verified\n");
        runner.exitQemu(.Success);
    } else if (comptime std.mem.eql(u8, scenario, "breakpoint")) {
        asm volatile (
            \\ leaq 1f(%rip), %rax
            \\ movq %rax, breakpoint_resume(%rip)
            \\ int3
            \\ 1:
            ::: .{ .rax = true, .memory = true });
    } else if (comptime std.mem.eql(u8, scenario, "bad-stack")) {
        // A push through an unmapped stack causes #PF. Its absent gate faults
        // during delivery, escalating to #DF, which must switch to IST1.
        asm volatile (
            \\ xorq %rsp, %rsp
            \\ pushq %rax
        );
        unreachable;
    } else {
        // Invalid selector causes #GP; its absent gate causes #NP during
        // delivery, escalating to a real #DF (INT 8 would not push an error code).
        asm volatile (
            \\ movw $0xffff, %ax
            \\ movw %ax, %ds
            ::: .{ .rax = true, .memory = true });
    }
    runner.exitQemu(.Failed);
}
