# Os
This is a UEFI os kernel written in zig for personal study.

**Zig Version**: 0.16.0

## Current Capabilities
- Booting out of UEFI services.
- Basic console printing and panicking
- Breakpoint and double-fault handling with an emergency stack
- ACPI-discovered local APIC and I/O APIC interrupt routing
- PS/2 keyboard input with US layout, Shift, Caps Lock, Enter, Tab, and Backspace
- QEMU integration tests (with serial logger)

## Exception handling tests

Run `zig build test` to execute all seven QEMU tests. Individual exception tests:

- `zig build test-idt-layout`: loaded IDT/GDT limits, gate addresses and flags, TSS/IST setup, and table reload.
- `zig build test-breakpoint`: actual `int3` delivery and saved register frame.
- `zig build test-double-fault`: a general-protection fault escalates into a double fault.
- `zig build test-double-fault-stack`: a fault with an unusable stack reaches the emergency stack.

The double-fault tests verify the CPU's zero error code, saved frame, and handler stack location. Tests use fatal callbacks to report through serial and QEMU's debug-exit device. The normal kernel handler prints diagnostics and halts. Call `init_gdt()` before `init_idt()`, after leaving UEFI Boot Services and initializing the framebuffer console.

Exception setup installs breakpoint and double-fault gates. APIC initialization then installs returning hardware gates for vectors 32–255. The TSS and 32 KiB emergency stack currently serve a single CPU. QEMU tests require `timeout`, rerun on every invocation, disable reboot, and fail after 30 seconds if no result arrives. Logs are under `build/test-disk-*/serial-log.txt`.


## APIC and keyboard input

Run `zig build run`, focus the QEMU window, and type. The kernel reads ACPI's MADT before leaving Boot Services, masks the legacy PIC and unused I/O APIC routes, initializes the boot CPU's xAPIC, and routes keyboard IRQ1 using any ACPI source override. All hardware gates are installed before interrupts are enabled. Handlers preserve general registers and x87/SSE state, acknowledge real interrupts through the local APIC, and return with `iretq`; the spurious vector does not send EOI.

The PS/2 driver sets scan-code set 2 with controller translation to set 1. Its interrupt callback decodes input into a bounded FIFO; console rendering happens in the main loop. The loop checks input with interrupts disabled and uses `sti; hlt` to sleep without losing wakeups. Overflow drops the newest character and increments `keyboard.dropped`. Extended navigation keys are ignored; this is text input, not a shell or a full terminal. USB keyboards, mouse input, SMP, x2APIC, and AVX context switching are not implemented. The current baseline x86_64 build uses x87/SSE; the driver retains UEFI's identity mappings and uncacheable APIC MMIO mappings.

`zig build test-apic-keyboard` verifies ACPI overrides and malformed records, scan-code decoding, returning IRQ register/flag preservation, repeated local APIC timer delivery, spurious-interrupt handling, and real IRQ1 delivery using the controller's D2 output-buffer command. It also checks queue overflow/wraparound and end-of-interrupt acknowledgement. Run `zig build test -Doptimize=ReleaseSafe` to exercise the same paths with optimization.

Implementation references: [ACPI MADT specification](https://uefi.org/specs/ACPI/6.6/05_ACPI_Software_Programming_Model.html#multiple-apic-description-table-madt), [Intel system programming manuals](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html), and [QEMU's i8042 controller](https://github.com/qemu/qemu/blob/master/hw/input/pckbd.c).
