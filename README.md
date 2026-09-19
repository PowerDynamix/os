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
- Cooperative multitasking with IRQ wakeups and an async keyboard task
- Calibrated APIC timer, task sleep, and absolute deadlines
- QEMU integration tests (with serial logger)

## Exception handling tests

Run `zig build test` to execute all thirteen QEMU tests. Individual exception tests:

- `zig build test-idt-layout`: loaded IDT/GDT limits, gate addresses and flags, TSS/IST setup, and table reload.
- `zig build test-breakpoint`: actual `int3` delivery and saved register frame.
- `zig build test-double-fault`: a general-protection fault escalates into a double fault.
- `zig build test-double-fault-stack`: a fault with an unusable stack reaches the emergency stack.

The double-fault tests verify the CPU's zero error code, saved frame, and handler stack location. Tests use fatal callbacks to report through serial and QEMU's debug-exit device. The normal kernel handler prints diagnostics and halts. Call `init_gdt()` before `init_idt()`, after leaving UEFI Boot Services and initializing the framebuffer console.

Exception setup installs breakpoint, double-fault, and page-fault gates. APIC initialization then installs returning hardware gates for vectors 32–255. The TSS and 32 KiB emergency stack currently serve a single CPU. QEMU tests require `timeout`, rerun on every invocation, disable reboot, and fail after 30 seconds if no result arrives. Logs are under `build/test-disk-*/serial-log.txt`.


## APIC and keyboard input

Run `zig build run`, focus the QEMU window, and type. The kernel reads ACPI's MADT before leaving Boot Services, masks the legacy PIC and unused I/O APIC routes, initializes the boot CPU's xAPIC, and routes keyboard IRQ1 using any ACPI source override. All hardware gates are installed before interrupts are enabled. Handlers preserve general registers and x87/SSE state, acknowledge real interrupts through the local APIC, and return with `iretq`; the spurious vector does not send EOI.

The PS/2 driver sets scan-code set 2 with controller translation to set 1. Its interrupt callback decodes input into a bounded FIFO; console rendering happens in the keyboard task. The reader checks input and registers its wake handle with interrupts disabled. The executor uses `sti; hlt` when no task is ready, avoiding lost wakeups. Overflow drops the newest character and increments `keyboard.dropped`. Extended navigation keys are ignored; this is text input, not a shell or a full terminal. USB keyboards, mouse input, SMP, x2APIC, and AVX context switching are not implemented. The current baseline x86_64 build uses x87/SSE; the kernel preserves UEFI's identity mappings and uncacheable APIC MMIO mappings in its new page-table root.

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


## Cooperative multitasking and async examples

`src/task.zig` provides a single-CPU, stackless executor for up to 32 tasks. Each task has a caller-owned context and a poll function returning `.yield` (schedule another turn), `.pending` (wait for an event to wake it), or `.complete` (release its slot). Ready tasks run round-robin. The executor clears readiness before polling so a wake during the poll is retained, and repeated wakes coalesce. A task generation identifies each slot lifetime; late wakes cannot target a replacement task. Cancelled and completed tasks run their optional cleanup exactly once.

`src/examples/tasks.zig` contains these examples; `main.zig` starts `PeriodicWorker` and `Keyboard`:

- `Counter` is the original basic execution example: it adds 1 through 5, yields between steps, and completes with a total of 15.
- `PeriodicWorker` sleeps between five progress messages, roughly one second apart, then completes.
- `Keyboard` waits for input with `keyboard.pollRead`, echoes one character per poll, and yields while draining buffered input. An empty FIFO suspends it until IRQ1 wakes it. Its cleanup detaches the keyboard subscription.

Run `zig build run` and type while the periodic worker prints progress. Both tasks are registered together; the keyboard remains responsive while the worker sleeps and stays active after the worker completes. The async interface uses explicit state machines and wake handles, without Zig language-level `async`/`await` syntax.

A minimal execution example, after memory, APIC, and keyboard initialization:

```zig
const task = @import("task.zig");

const Job = struct {
    remaining: usize = 3,

    fn poll(context: *anyopaque, _: task.Waker) task.Poll {
        const self: *Job = @ptrCast(@alignCast(context));
        // Perform one bounded piece of work here.
        self.remaining -= 1;
        return if (self.remaining == 0) .complete else .yield;
    }
};

fn executeExample() !void {
    var executor: task.Executor = .{};
    var job: Job = .{};
    _ = try executor.spawn(&job, Job.poll, null);
    executor.run(); // Returns when all tasks have completed.
}
```

Polls run with interrupts enabled. Task state survives in the context across calls; local variables in the poll function do not. Polls must return promptly and must not block or spin waiting for I/O. There is no timer preemption, separate task stack, userspace isolation, or SMP scheduling. A task that never returns prevents other tasks from running. Heap allocation and console printing remain safe between cooperative tasks because IRQ handlers do not use them.

`Executor.step()` polls at most one ready task without sleeping. `Executor.run()` sleeps when only pending tasks remain and returns when there are none left. Both restore the caller's interrupt-enable state. IRQ handlers may call `Waker.wake()`; they must not spawn, cancel, run tasks, or allocate. The idle sequence follows the interrupt-shadow behavior described in the [Intel instruction manual](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html).

Keep the executor and task contexts at stable addresses. Contexts must live until completion/cancellation; the executor must outlive all retained wake handles. An optional cleanup callback can release heap-owned contexts and detach event subscriptions. Cleanup runs with interrupts disabled and must be short; it must not run the executor. Use `executor.cancel(handle)` to cancel a task; cancellation of the currently polling task is rejected (return `.complete` instead). Do not reset or copy a live executor. There is one outstanding async keyboard reader; competing subscriptions receive `ReaderBusy`. Do not mix a separate `keyboard.pop()` consumer with it.

`zig build test-tasks` checks round-robin execution, completion and cancellation cleanup, pending tasks without busy polling, wake coalescing, waking during a poll, stale handles, slot capacity/reuse, interrupt-state restoration, APIC wake from idle, and real IRQ1 delivery to the async reader. It also verifies reader cancellation and input already buffered before subscription. The aggregate Debug and ReleaseSafe suites include this test.


## Timer-backed sleep and deadlines

Call `timer.init()` after `apic.init()` with interrupts disabled. Boot now does this after keyboard initialization. Calibration uses three approximately 10 ms PIT channel-2 one-shots and the smallest measured LAPIC count, then starts a periodic APIC interrupt every 10 ms. PIT IRQ0 is never enabled; the speaker is disabled during measurement. Calibration is bounded and reports failure if the PIT does not produce the expected transition or the APIC count is invalid. It requires a legacy PC/AT PIT and takes ownership of channel 2, restoring its gate/speaker control bits afterward but not its previous mode/count.

`timer.now()` returns a monotonic millisecond tick count since initialization. `task.sleep(milliseconds)` creates a sleep value with a fixed deadline; keep it in the task context and call `sleep.poll(waker)` on subsequent polls. It returns `false` while waiting and `true` when due. A wake from another event does not restart the stored sleep. Zero-length sleeps and past deadlines complete immediately. Positive durations round up to ticks and add one tick to cover the unknown tick phase; arithmetic overflow returns `error.Overflow`.

```zig
const task = @import("task.zig");

const DelayedJob = struct {
    wait: ?task.Sleep = null,

    fn poll(context: *anyopaque, waker: task.Waker) task.Poll {
        const self: *DelayedJob = @ptrCast(@alignCast(context));
        if (self.wait == null) self.wait = task.sleep(1000) catch return .complete;
        const ready = self.wait.?.poll(waker) catch return .complete;
        if (!ready) return .pending;
        // Perform work after the delay. A repeating job can clear wait and yield.
        return .complete;
    }
};
```

Use `task.sleepUntil(deadline_ms)` for an absolute deadline in the `timer.now()` clock domain. Repeated absolute deadlines can maintain a fixed schedule; decide whether to catch up or skip intervals if work runs late. Relative sleeps begin when created, not when first polled. There is one outstanding timer subscription per task and 32 across all executors. Polling a different sleep replaces that task's registration. `task.Sleep.cancel(waker)` abandons a wait; task completion and cancellation also remove it automatically before context cleanup or slot reuse. Queue exhaustion returns `error.TimerCapacityExceeded`.

Timer IRQs only advance the clock and wake due tasks. They do not poll tasks, allocate, print, or preempt the current task. The executor still halts when no task is runnable; periodic ticks may wake the CPU without making a task runnable. Task execution can occur later than its deadline. This clock counts delivered interrupts: long periods with interrupts masked can lose/coalesce ticks and delay timekeeping. It is not a wall clock or a hard real-time timer, and power states that stop the LAPIC timer are unsupported. Do not use the raw APIC one-shot/stop/calibration APIs or reinitialize the APIC after starting the timer service, since they share its hardware timer and vector.

`zig build test-timer` checks calibration against a separate 50 ms PIT interval, repeated periodic delivery and EOI, deadline rounding and overflow, ordered and equal-deadline sleepers, unrelated wakes, cancellation and slot reuse, immediate deadlines, queue capacity, and keyboard IRQ delivery alongside a periodic worker. All thirteen tests also run with `zig build test -Doptimize=ReleaseSafe`.

Hardware references: [Intel APIC timer documentation](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html), [QEMU PIT implementation](https://github.com/qemu/qemu/blob/master/hw/timer/i8254.c), and [QEMU speaker/gate port implementation](https://github.com/qemu/qemu/blob/master/hw/audio/pcspk.c).
