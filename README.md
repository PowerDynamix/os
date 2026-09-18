# Os
This is a UEFI os kernel written in zig for personal study.

**Zig Version**: 0.16.0

## Current Capabilities
- Booting out of UEFI services.
- Basic console printing and panicking
- Breakpoint and double-fault handling with an emergency stack
- ACPI-discovered local APIC and I/O APIC interrupt routing
- PS/2 keyboard input with US layout, Shift, Caps Lock, Enter, Tab, and Backspace
- Physical frame allocation and kernel-owned four-level paging for new mappings
- An 8 MiB heap, plus bump, arena, and fixed-object pool allocation
- Page-fault diagnostics and hardware-tested read-only/non-executable pages
- QEMU integration tests (with serial logger)

## Exception handling tests

Run `zig build test` to execute all eleven QEMU tests. Individual exception tests:

- `zig build test-idt-layout`: loaded IDT/GDT limits, gate addresses and flags, TSS/IST setup, and table reload.
- `zig build test-breakpoint`: actual `int3` delivery and saved register frame.
- `zig build test-double-fault`: a general-protection fault escalates into a double fault.
- `zig build test-double-fault-stack`: a fault with an unusable stack reaches the emergency stack.

The double-fault tests verify the CPU's zero error code, saved frame, and handler stack location. Tests use fatal callbacks to report through serial and QEMU's debug-exit device. The normal kernel handler prints diagnostics and halts. Call `init_gdt()` before `init_idt()`, after leaving UEFI Boot Services and initializing the framebuffer console.

Exception setup installs breakpoint, double-fault, and page-fault gates. APIC initialization then installs returning hardware gates for vectors 32–255. The TSS and 32 KiB emergency stack currently serve a single CPU. QEMU tests require `timeout`, rerun on every invocation, disable reboot, and fail after 30 seconds if no result arrives. Logs are under `build/test-disk-*/serial-log.txt`.


## APIC and keyboard input

Run `zig build run`, focus the QEMU window, and type. The kernel reads ACPI's MADT before leaving Boot Services, masks the legacy PIC and unused I/O APIC routes, initializes the boot CPU's xAPIC, and routes keyboard IRQ1 using any ACPI source override. All hardware gates are installed before interrupts are enabled. Handlers preserve general registers and x87/SSE state, acknowledge real interrupts through the local APIC, and return with `iretq`; the spurious vector does not send EOI.

The PS/2 driver sets scan-code set 2 with controller translation to set 1. Its interrupt callback decodes input into a bounded FIFO; console rendering happens in the main loop. The loop checks input with interrupts disabled and uses `sti; hlt` to sleep without losing wakeups. Overflow drops the newest character and increments `keyboard.dropped`. Extended navigation keys are ignored; this is text input, not a shell or a full terminal. USB keyboards, mouse input, SMP, x2APIC, and AVX context switching are not implemented. The current baseline x86_64 build uses x87/SSE; the kernel preserves UEFI's identity mappings and uncacheable APIC MMIO mappings in its new page-table root.

`zig build test-apic-keyboard` verifies ACPI overrides and malformed records, scan-code decoding, returning IRQ register/flag preservation, repeated local APIC timer delivery, spurious-interrupt handling, and real IRQ1 delivery using the controller's D2 output-buffer command. It also checks queue overflow/wraparound and end-of-interrupt acknowledgement. Run `zig build test -Doptimize=ReleaseSafe` to exercise the same paths with optimization.

Implementation references: [ACPI MADT specification](https://uefi.org/specs/ACPI/6.6/05_ACPI_Software_Programming_Model.html#multiple-apic-description-table-madt), [Intel system programming manuals](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html), and [QEMU's i8042 controller](https://github.com/qemu/qemu/blob/master/hw/input/pckbd.c).


## Paging and allocators

After `ExitBootServices`, install the GDT/IDT, then call `memory.init(memory_map)` before initializing the APIC and keyboard. Initialization failures are fatal; do not retry. The kernel reports actual managed conventional RAM and available frames instead of a hard-coded memory size.

The physical allocator uses a bitmap for 4 KiB frames below 64 GiB and accepts up to 256 usable memory regions. It honors UEFI descriptor stride, excludes page zero, and rejects unaligned, reserved, and already-free frames. Only conventional RAM is made available. Loader memory (including the kernel), firmware page tables, Boot Services memory, ACPI, runtime services, and MMIO stay reserved. RAM above the limit is ignored. Boot Services memory is deliberately not reclaimed yet.

Paging copies the active PML4 into an allocated frame and loads CR3, preserving existing identity mappings and their cache attributes. PML4 slot 256 (`0xffff800000000000` through `0xffff807fffffffff`) is reserved for new mappings; initialization rejects firmware already using it. `memory.virtual.map(address, frame, flags)` creates supervisor 4 KiB mappings and intermediate tables. `translate` also understands existing 2 MiB and 1 GiB firmware mappings. `unmap` invalidates the local TLB, reclaims empty tables, and returns the data frame for the caller to free. Mapping does not transfer ownership of the data frame. Allocation failures roll back new tables. NX support is required, five-level paging is rejected, and CR0.WP enforces supervisor read-only protection. The implementation follows the [Intel system programming manual](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html).

The heap commits 8 MiB of zeroed, writable, non-executable pages starting at `0xffff800000001000`, with an unmapped page at each end. It implements `std.mem.Allocator` using first-fit blocks, alignment-aware splitting, and coalescing on free. Shrinking retains block capacity; growing `realloc` copies when needed. Ordinary frees reuse heap space without returning pages to the physical allocator. Additional `memory.Heap` instances can commit a chosen page budget and return it with `deinit`, after all their allocations have been freed. Keep allocator objects at stable addresses, and reserve separate, non-overlapping virtual ranges including their guard pages.

```zig
const memory = @import("memory.zig");

fn allocationExample() !void {
    const allocator = memory.allocator();
    const bytes = try allocator.alloc(u8, 1024);
    defer allocator.free(bytes);
    @memset(bytes, 0);

    var scratch: [4096]u8 = undefined;
    var bump = memory.BumpAllocator.init(&scratch);
    _ = try bump.allocator().alloc(u64, 32);
    bump.reset(); // All bump allocations are invalidated.

    var arena = memory.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = try arena.allocator().alloc(u8, 512);

    var pool: memory.ObjectPool(u64) = .empty;
    defer pool.deinit(allocator);
    const object = try pool.create(allocator);
    object.* = 42;
    pool.destroy(object);
}
```

Bump, arena, and object-pool designs reuse Zig's standard implementations over kernel-owned storage. Use bump allocation for bounded scratch space, arenas for groups with a common lifetime, and pools for repeated allocation of one object type. All memory APIs currently require single-CPU task context; interrupt handlers must not allocate. Demand paging, userspace address spaces, SMP TLB shootdowns, automatic heap growth, and reclaiming firmware mappings are not implemented. Retained identity aliases mean NX/read-only permissions on new mappings do not provide isolation from privileged code using those aliases.

Memory tests:

- `zig build test-memory`: reserved-frame filtering, descriptor stride, exhaustion, frame reuse, CR3 activation, mapping/aliasing, TLB invalidation, table reclamation and OOM rollback, heap alignment/realloc/coalescing, fragmentation, rollback, and allocator lifetimes.
- `zig build test-page-fault`: accessing an unmapped page after its TLB entry was populated; verifies CR2 and the CPU error code.
- `zig build test-page-readonly`: a supervisor write to a read-only page faults.
- `zig build test-page-nx`: executing code from a non-executable page faults.
- `zig build test-apic-keyboard`: existing interrupt and keyboard integration under the kernel's new page tables.

`zig build test -Doptimize=ReleaseSafe` runs the same suite with optimization.
