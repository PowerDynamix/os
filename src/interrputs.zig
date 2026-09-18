//! Single-CPU x86_64 exception setup for the UEFI kernel.
//!
//! After ExitBootServices, initialize the framebuffer console, call init_gdt(),
//! then init_idt(). The GDT supplies code/data selectors and the TSS; the IDT
//! routes breakpoints, double faults and page faults to fatal handlers. apic.init() installs
//! returning hardware gates; device drivers register callbacks before STI.
//!
//! Double faults use a dedicated IST stack so delivery can survive a broken
//! kernel stack. Exception callbacks are noreturn. Hardware IRQ callbacks return
//! through a separate stub that restores the interrupted context with IRETQ.

const std = @import("std");
const cs = @import("console.zig");

// -----------------------------------------------------------------------------
// Hardware layouts
// -----------------------------------------------------------------------------

// Segment descriptors occupy 8 bytes; a 64-bit TSS uses two adjacent slots.
const GDTEntry = packed struct {
    limit_low: u16,
    base_low: u16,
    base_mid: u8,
    access: u8,
    granularity: u8,
    base_high: u8,
};

const GDTR = packed struct {
    limit: u16,
    base: u64,
};

// Hardware-defined 64-bit TSS layout (Intel SDM Vol. 3).
// align(1) prevents padding before the unaligned 64-bit fields.
// Only IST1 is used; privilege-level stacks are unused by this ring-0 kernel.
const TSS = extern struct {
    reserved0: u32 = 0,
    rsp: [3]u64 align(1) = @splat(0),
    reserved1: u64 align(1) = 0,
    ist: [7]u64 align(1) = @splat(0),
    reserved2: u64 align(1) = 0,
    reserved3: u16 = 0,
    // Put the I/O bitmap beyond the TSS limit: no bitmap is present.
    iomap_base: u16 = @sizeOf(TSS),
};

comptime {
    std.debug.assert(@sizeOf(TSS) == 104);
    std.debug.assert(@offsetOf(TSS, "ist") == 36);
    std.debug.assert(@offsetOf(TSS, "iomap_base") == 102);
}

pub const IDTEntry = extern struct {
    isr_low: u16, // Lower 16 bits of ISR address
    kernel_cs: u16, // GDT segment selector
    ist: u8, // Interrupt Stack Table index
    attributes: u8, // Type and attributes
    isr_mid: u16, // Bits 16–31 of ISR address
    isr_high: u32, // Bits 32–63 of ISR address
    reserved: u32, // Reserved, set to zero
};

comptime {
    std.debug.assert(@sizeOf(IDTEntry) == 16);
}

// LIDT reads exactly 10 bytes: a 2-byte limit immediately followed by the base.
const IDTR = extern struct {
    limit: u16,
    base: u64 align(1),
};

comptime {
    std.debug.assert(@offsetOf(IDTR, "base") == 2);
    std.debug.assert(@sizeOf(IDTR) == 10);
}

// CPU-saved long-mode frame. Exception error codes are passed separately.
pub const InterruptFrame = extern struct {
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

// -----------------------------------------------------------------------------
// Fatal handler callbacks
// -----------------------------------------------------------------------------

/// Fatal exception policy. Tests supply callbacks that report through QEMU.
/// Callbacks must never return because the stubs do not restore registers.
pub const ExceptionHandlers = struct {
    breakpoint: *const fn (*const InterruptFrame) noreturn = default_breakpoint_handler,
    double_fault: *const fn (*const InterruptFrame, u64) noreturn = default_double_fault_handler,
    page_fault: *const fn (*const InterruptFrame, u64, usize) noreturn = default_page_fault_handler,
};

// -----------------------------------------------------------------------------
// Descriptor tables and emergency stack storage
// -----------------------------------------------------------------------------

// Selectors: 0x00 = null, 0x08 = code, 0x10 = data, 0x18 = TSS (two slots).
var gdt: [5]GDTEntry align(8) = .{
    std.mem.zeroes(GDTEntry),
    .{
        .limit_low = 0xFFFF,
        .base_low = 0,
        .base_mid = 0,
        .access = 0x9A,
        .granularity = 0xAF,
        .base_high = 0,
    },
    .{
        .limit_low = 0xFFFF,
        .base_low = 0,
        .base_mid = 0,
        .access = 0x92,
        .granularity = 0xCF,
        .base_high = 0,
    },
    std.mem.zeroes(GDTEntry), // 16-byte TSS descriptor
    std.mem.zeroes(GDTEntry),
};

var gdtr: GDTR = undefined;

// Static storage keeps the TSS and its downward-growing stack alive permanently.
pub const double_fault_stack_size = 32 * 1024;
var double_fault_stack: [double_fault_stack_size]u8 align(16) = undefined;
var tss: TSS align(16) = .{};

const IDT_MAX_DESCRIPTORS = 256;
var idt: [IDT_MAX_DESCRIPTORS]IDTEntry align(16) = [_]IDTEntry{std.mem.zeroes(IDTEntry)} ** IDT_MAX_DESCRIPTORS;
var idt_r: IDTR = undefined;

var handlers: ExceptionHandlers = .{};

// -----------------------------------------------------------------------------
// Initialization: GDT / TSS first, then IDT
// -----------------------------------------------------------------------------

/// Replace the firmware GDT and load the task register for IST-based delivery.
/// Call after ExitBootServices and before installing the kernel IDT.
pub fn init_gdt() void {
    // Keep firmware IRQs masked while replacing its descriptor tables.
    asm volatile ("cli");
    tss = .{};
    // IDT IST index 1 selects tss.ist[0]. The initial RSP is the stack end.
    tss.ist[0] = @intFromPtr(&double_fault_stack) + double_fault_stack.len;
    const tss_address = @intFromPtr(&tss);
    // Rebuild as available on every load; LTR marks the descriptor busy.
    gdt[3] = .{
        .limit_low = @sizeOf(TSS) - 1,
        .base_low = @truncate(tss_address),
        .base_mid = @truncate(tss_address >> 16),
        .access = 0x89, // Present, available 64-bit TSS.
        .granularity = 0,
        .base_high = @truncate(tss_address >> 24),
    };
    // Upper half holds base bits 32..63, followed by reserved zero bits.
    gdt[4] = @bitCast(@as(u64, tss_address >> 32));
    gdtr.limit = @sizeOf(@TypeOf(gdt)) - 1;
    gdtr.base = @intFromPtr(&gdt);

    asm volatile ("lgdt (%[gdtr])"
        :
        : [gdtr] "r" (&gdtr),
        : .{ .memory = true });

    // LGDT does not refresh cached segment descriptors; reload them explicitly.
    asm volatile (
        \\ movw $0x10, %ax
        \\ movw %ax, %ds
        \\ movw %ax, %es
        \\ movw %ax, %ss
        \\ xorw %ax, %ax
        \\ movw %ax, %fs
        \\ movw %ax, %gs
        ::: .{ .rax = true, .memory = true });

    // A far return reloads CS and continues at the local label.
    asm volatile (
        \\ pushq $0x08
        \\ leaq 1f(%rip), %rax
        \\ pushq %rax
        \\ lretq
        \\ 1:
        ::: .{ .rax = true, .memory = true });
    // Make the TSS (and thus IST1) available to the processor.
    asm volatile ("ltr %[selector]"
        :
        : [selector] "r" (@as(u16, 0x18)),
        : .{ .memory = true });
}

/// Call after init_gdt(), with a framebuffer console ready for fatal diagnostics.
pub fn init_idt() void {
    init_idt_with_handlers(.{});
}

/// Install fatal exception callbacks (also used by the QEMU integration tests).
/// Callbacks must not return. Hardware IRQs remain disabled.
pub fn init_idt_with_handlers(exception_handlers: ExceptionHandlers) void {
    asm volatile ("cli");
    hardware_ready = false;
    handlers = exception_handlers;
    // Leave unsupported vectors absent, including all hardware IRQ vectors.
    @memset(&idt, std.mem.zeroes(IDTEntry));
    idt_r.base = @intFromPtr(&idt);
    idt_r.limit = @sizeOf(@TypeOf(idt)) - 1;

    // 0x8E: present, ring-0, 64-bit interrupt gate (clears IF on entry).
    // Breakpoints keep the current stack; double faults switch to IST1.
    idt_set_descriptor(3, isr_stub_3, 0x8E, 0);
    idt_set_descriptor(8, isr_stub_8, 0x8E, 1);
    idt_set_descriptor(14, isr_stub_14, 0x8E, 0);

    asm volatile ("lidt (%[idtr])"
        :
        : [idtr] "r" (&idt_r),
        : .{ .memory = true });

    // INT3 works with IF clear. Enable IRQs only after installing their handlers.
}

// Split the handler address into the three fields required by an IDT gate.
fn idt_set_descriptor(
    vector: u8,
    isr: *const fn () callconv(.naked) void,
    flags: u8,
    ist: u3,
) void {
    const address = @intFromPtr(isr);
    const descriptor = &idt[vector];

    descriptor.isr_low = @truncate(address);
    descriptor.kernel_cs = 0x08;
    descriptor.ist = ist;
    descriptor.attributes = flags;
    descriptor.isr_mid = @truncate(address >> 16);
    descriptor.isr_high = @truncate(address >> 32);
    descriptor.reserved = 0;
}

// -----------------------------------------------------------------------------
// CPU entry stubs and Zig dispatch
// -----------------------------------------------------------------------------

pub export fn isr_stub_3() callconv(.naked) void {
    // No error code is pushed for #BP: RSP already points at InterruptFrame.
    // Save the frame pointer before aligning the call stack. CLD establishes
    // the ABI's forward string-operation direction.
    // UEFI uses Microsoft x64: RCX = argument 1, 32-byte caller shadow space,
    // and a 16-byte-aligned RSP immediately before CALL.
    asm volatile (
        \\ cld
        \\ movq %rsp, %rcx
        \\ andq $-16, %rsp
        \\ subq $32, %rsp
        \\ callq breakpoint_handler
    );
}

pub export fn isr_stub_8() callconv(.naked) void {
    // On entry, IST1 is active: [RSP] = error code (always zero for #DF),
    // [RSP + 8] = InterruptFrame. RCX passes the frame; RDX passes the code.
    // Use the same alignment and shadow-space rules as the breakpoint stub.
    asm volatile (
        \\ cld
        \\ movq (%rsp), %rdx
        \\ leaq 8(%rsp), %rcx
        \\ andq $-16, %rsp
        \\ subq $32, %rsp
        \\ callq double_fault_handler
    );
}

// Exported C-ABI bridges are called by name from the assembly stubs above.
pub export fn isr_stub_14() callconv(.naked) void {
    // Capture CR2 before Zig runs; error code and frame match #DF's layout.
    asm volatile (
        \\ cld
        \\ movq %cr2, %r8
        \\ movq (%rsp), %rdx
        \\ leaq 8(%rsp), %rcx
        \\ andq $-16, %rsp
        \\ subq $32, %rsp
        \\ callq page_fault_handler
    );
}

export fn page_fault_handler(frame: *const InterruptFrame, error_code: u64, address: usize) callconv(.c) noreturn {
    handlers.page_fault(frame, error_code, address);
}

export fn breakpoint_handler(frame: *const InterruptFrame) callconv(.c) noreturn {
    handlers.breakpoint(frame);
}

export fn double_fault_handler(frame: *const InterruptFrame, error_code: u64) callconv(.c) noreturn {
    handlers.double_fault(frame, error_code);
}

// -----------------------------------------------------------------------------
// Default console diagnostics
// -----------------------------------------------------------------------------

fn default_double_fault_handler(frame: *const InterruptFrame, error_code: u64) noreturn {
    cs.k_console.print("DOUBLE FAULT!\n", .{});
    cs.k_console.print("Error code: 0x{X}\nRIP: 0x{X}\nRSP: 0x{X}\n", .{ error_code, frame.rip, frame.rsp });
    cs.k_console.panic("Unrecoverable double fault", .{});
}

fn default_page_fault_handler(frame: *const InterruptFrame, error_code: u64, address: usize) noreturn {
    cs.k_console.print("PAGE FAULT! Address: 0x{X}\nError: 0x{X}, RIP: 0x{X}\n", .{ address, error_code, frame.rip });
    cs.k_console.panic("Unrecoverable page fault", .{});
}

fn default_breakpoint_handler(frame: *const InterruptFrame) noreturn {
    cs.k_console.print("BREAKPOINT!\n", .{});
    cs.k_console.print("RIP: 0x{X}\n", .{frame.rip});
    cs.k_console.print("CS: 0x{X}\n", .{frame.cs});
    cs.k_console.print("RFLAGS: 0x{X}\n", .{frame.rflags});

    cs.k_console.panic("INTERRUPT ERROR", .{});
}

// -----------------------------------------------------------------------------
// Returning hardware interrupts (vectors 32..255)
// -----------------------------------------------------------------------------

pub const spurious_vector: u8 = 0xff;
pub const IrqHandler = *const fn () void;
var irq_handlers: [256]?IrqHandler = @splat(null);
var irq_eoi: IrqHandler = undefined;
var hardware_ready = false;

/// Install every external vector before enabling the APIC. Unassigned vectors
/// are safely acknowledged. The APIC spurious vector must never receive an EOI.
/// Initialization and registration run on the boot CPU with IF clear.
pub fn init_hardware(eoi: IrqHandler) void {
    disable();
    irq_eoi = eoi;
    irq_handlers = @splat(null);
    inline for (32..256) |vector| {
        idt_set_descriptor(vector, HardwareStub(vector).entry, 0x8e, 0);
    }
    hardware_ready = true;
}

pub fn register_irq(vector: u8, handler: IrqHandler) void {
    std.debug.assert(hardware_ready and vector >= 32 and vector != spurious_vector);
    std.debug.assert(!enabled());
    irq_handlers[vector] = handler;
}

pub inline fn disable() void {
    asm volatile ("cli" ::: .{ .memory = true });
}
pub inline fn enable() void {
    asm volatile ("sti" ::: .{ .memory = true });
}
pub inline fn enabled() bool {
    const flags = asm volatile ("pushfq; popq %[flags]"
        : [flags] "=r" (-> u64),
        :
        : .{ .memory = true });
    return flags & 0x200 != 0;
}

/// Caller checks its work queue with IF clear, then sleeps atomically with STI.
/// The STI interrupt shadow prevents a wakeup between enabling IRQs and HLT.
pub inline fn wait_for_interrupt() void {
    asm volatile ("sti; hlt" ::: .{ .memory = true });
}

fn HardwareStub(comptime vector: u8) type {
    return struct {
        fn entry() callconv(.naked) void {
            asm volatile (std.fmt.comptimePrint("pushq ${d}\njmp hardware_irq_entry", .{vector}));
        }
    };
}

/// Preserve all GPRs and x87/SSE state, including registers normally volatile
/// under the function ABI. The kernel's baseline x86_64 target does not use AVX.
/// R12 tracks the saved stack across a Microsoft x64 ABI call (32-byte shadow
/// space). FXSAVE64 needs 16-byte alignment. IRETQ restores RIP, RFLAGS and RSP.
export fn hardware_irq_entry() callconv(.naked) void {
    asm volatile (
        \\ pushq %rax
        \\ pushq %rcx
        \\ pushq %rdx
        \\ pushq %rbx
        \\ pushq %rbp
        \\ pushq %rsi
        \\ pushq %rdi
        \\ pushq %r8
        \\ pushq %r9
        \\ pushq %r10
        \\ pushq %r11
        \\ pushq %r12
        \\ pushq %r13
        \\ pushq %r14
        \\ pushq %r15
        \\ movq %rsp, %r12
        \\ andq $-16, %rsp
        \\ subq $560, %rsp
        \\ fxsave64 32(%rsp)
        \\ fninit
        \\ movl $0x1f80, 544(%rsp)
        \\ ldmxcsr 544(%rsp)
        \\ cld
        \\ movq 120(%r12), %rcx
        \\ callq hardware_irq_dispatch
        \\ fxrstor64 32(%rsp)
        \\ movq %r12, %rsp
        \\ popq %r15
        \\ popq %r14
        \\ popq %r13
        \\ popq %r12
        \\ popq %r11
        \\ popq %r10
        \\ popq %r9
        \\ popq %r8
        \\ popq %rdi
        \\ popq %rsi
        \\ popq %rbp
        \\ popq %rbx
        \\ popq %rdx
        \\ popq %rcx
        \\ popq %rax
        \\ addq $8, %rsp
        \\ iretq
    );
}

export fn hardware_irq_dispatch(vector: u64) callconv(.c) void {
    if (vector == spurious_vector) return;
    if (irq_handlers[@intCast(vector)]) |handler| handler();
    irq_eoi();
}
