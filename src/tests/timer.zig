const std = @import("std");
const uefi = std.os.uefi;
const kernel = @import("os_kernel");
const task = kernel.task;
const timer = kernel.timer;
const irq = kernel.interrupts;
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
fn doubleFault(_: *const irq.InterruptFrame, _: u64) noreturn {
    failed(error.UnexpectedDoubleFault);
}
fn pageFault(_: *const irq.InterruptFrame, _: u64, _: usize) noreturn {
    failed(error.UnexpectedPageFault);
}
fn unexpectedCallback(_: *anyopaque) void {
    failed(error.UnexpectedDeadline);
}

fn clockTests() !void {
    check(!irq.enabled(), "Timer init changed IF\n");
    check(timer.countsPerTick() >= 100, "Invalid APIC calibration\n");
    if (timer.init()) |_| return error.ReinitializedTimer else |err| check(err == error.AlreadyInitialized, "Repeated init\n");
    check(try timer.deadlineAfter(0) == timer.now(), "Zero duration\n");
    check(try timer.deadlineAfter(1) == timer.now() + 20, "Subtick rounding\n");
    check(try timer.deadlineAfter(10) == timer.now() + 20, "Tick phase allowance\n");
    check(try timer.deadlineAfter(11) == timer.now() + 30, "Duration rounding\n");
    if (task.sleep(std.math.maxInt(u64))) |_| return error.WrappedDeadline else |err| check(err == error.Overflow, "Deadline overflow\n");

    // Independent 50 ms PIT interval checks the calibrated periodic APIC clock.
    // Allow tick phase and emulation jitter; this catches order-of-magnitude errors.
    const original = io.inb(0x61);
    defer io.outb(0x61, original);
    io.outb(0x61, original & ~@as(u8, 3));
    io.outb(0x43, 0xb2);
    const count: u16 = 59659;
    io.outb(0x42, @truncate(count));
    io.outb(0x42, @truncate(count >> 8));
    const start = timer.now();
    io.outb(0x61, (original & ~@as(u8, 3)) | 1);
    var low_seen = false;
    var finished = false;
    irq.enable();
    for (0..20_000_000) |_| {
        const high = io.inb(0x61) & 0x20 != 0;
        if (!high) low_seen = true;
        if (high and low_seen) {
            finished = true;
            break;
        }
        io.pause();
    }
    irq.disable();
    const elapsed = timer.now() - start;
    check(finished and elapsed >= 30 and elapsed <= 80, "APIC clock disagrees with PIT reference\n");
    check(!kernel.apic.in_service(kernel.apic.timer_vector), "Periodic timer EOI\n");
    serial.writeString("Calibration, periodic delivery, rounding and overflow passed\n");
}

var order: [3]u8 = undefined;
var completed: usize = 0;
const TimedTask = struct {
    id: u8,
    wait: task.Sleep,
    polls: usize = 0,
    finished_at: u64 = 0,
    fn poll(context: *anyopaque, waker: task.Waker) task.Poll {
        const self: *TimedTask = @ptrCast(@alignCast(context));
        check(irq.enabled(), "Sleep polled with IF clear\n");
        self.polls += 1;
        if (!(self.wait.poll(waker) catch |err| failed(err))) return .pending;
        self.finished_at = timer.now();
        check(self.finished_at >= self.wait.deadline, "Early deadline wake\n");
        order[completed] = self.id;
        completed += 1;
        return .complete;
    }
};
fn sleepTests() !void {
    var executor: task.Executor = .{};
    const start = timer.now();
    var a: TimedTask = .{ .id = 1, .wait = task.sleepUntil(start + 130) };
    var b: TimedTask = .{ .id = 2, .wait = task.sleepUntil(start + 100) };
    var c: TimedTask = .{ .id = 3, .wait = task.sleepUntil(start + 130) };
    const a_handle = try executor.spawn(&a, TimedTask.poll, null);
    _ = try executor.spawn(&b, TimedTask.poll, null);
    _ = try executor.spawn(&c, TimedTask.poll, null);
    for (0..3) |_| check(executor.step(), "Initial sleep poll\n");
    check(!executor.step() and timer.pendingCount() == 3, "Sleeping task busy-polled\n");
    // An unrelated wake must not complete or restart a stored sleep.
    a_handle.wake();
    check(executor.step() and a.polls == 2 and a.finished_at == 0, "Spurious wake completed sleep\n");
    check(a.wait.deadline == start + 130 and timer.pendingCount() == 3, "Spurious wake changed deadline\n");
    executor.run();
    check(completed == 3 and order[0] == 2, "Deadline order\n");
    check(a.polls == 3 and b.polls == 2 and c.polls == 2, "Sleep poll count\n");
    // Equal deadlines make both runnable in one IRQ, but task dispatch can be late.
    check(a.finished_at >= b.finished_at and c.finished_at >= b.finished_at, "Simultaneous deadlines\n");
    check(timer.pendingCount() == 0 and !irq.enabled(), "Sleep leaked registration or IF\n");
    serial.writeString("Deadline order, simultaneous wakes, idle sleep and spurious wakes passed\n");
}

const Parked = struct {
    wait: task.Sleep,
    polls: usize = 0,
    done: bool = false,
    abandon: bool = false,
    fn poll(context: *anyopaque, waker: task.Waker) task.Poll {
        const self: *Parked = @ptrCast(@alignCast(context));
        self.polls += 1;
        _ = self.wait.poll(waker) catch |err| failed(err);
        if (self.abandon) task.Sleep.cancel(waker);
        return if (self.done) .complete else .pending;
    }
};
fn lifecycleTests() !void {
    var executor: task.Executor = .{};
    var parked: Parked = .{ .wait = try task.sleep(100) };
    const old = try executor.spawn(&parked, Parked.poll, null);
    _ = executor.step();
    check(timer.pendingCount() == 1, "Sleep not armed\n");
    try executor.cancel(old);
    check(timer.pendingCount() == 0, "Cancelled sleep retained executor pointer\n");
    var replacement: Parked = .{ .wait = try task.sleep(1000) };
    const new = try executor.spawn(&replacement, Parked.poll, null);
    _ = executor.step();
    check(new.slot == old.slot and timer.pendingCount() == 1, "Slot reuse\n");
    if (parked.wait.poll(old)) |_| return error.StaleSleep else |err| check(err == error.InvalidTask, "Stale sleep handle\n");
    task.Sleep.cancel(old); // Must not affect another generation.
    check(timer.pendingCount() == 1, "Stale handle cancelled replacement sleep\n");
    task.Sleep.cancel(new);
    check(timer.pendingCount() == 0, "Explicit sleep cancellation\n");
    old.wake();
    check(!executor.step(), "Stale wake revived task\n");
    // Pass the cancelled deadline with the reused slot still pending.
    const until = timer.now() + 150;
    while (timer.now() < until) {
        irq.wait_for_interrupt();
        irq.disable();
    }
    check(!executor.step() and replacement.polls == 1, "Cancelled timer woke reused slot\n");
    try executor.cancel(new);

    parked = .{ .wait = try task.sleep(1000), .done = true };
    _ = try executor.spawn(&parked, Parked.poll, null);
    executor.run();
    check(timer.pendingCount() == 0, "Completion retained sleep\n");
    parked = .{ .wait = try task.sleep(0), .done = true };
    const zero = try executor.spawn(&parked, Parked.poll, null);
    check(try parked.wait.poll(zero), "Zero sleep was not ready\n");
    check(try task.sleepUntil(0).poll(zero), "Past deadline was not ready\n");
    executor.run();
    check(timer.pendingCount() == 0, "Immediate sleep registered\n");

    var contexts: [timer.capacity + 1]u8 = @splat(0);
    for (contexts[0..timer.capacity]) |*context| {
        check(!try timer.waitUntil(timer.now() + 1000, context, unexpectedCallback), "Future timer ready\n");
    }
    if (timer.waitUntil(timer.now() + 1000, &contexts[timer.capacity], unexpectedCallback)) |_| return error.ExpectedTimerCapacity else |err| check(err == error.TimerCapacityExceeded, "Timer capacity\n");
    check(!try timer.waitUntil(timer.now() + 2000, &contexts[0], unexpectedCallback), "Full queue update\n");
    check(try timer.waitUntil(timer.now(), &contexts[0], unexpectedCallback), "Due timer not removed\n");
    for (&contexts) |*context| timer.cancel(context);
    check(timer.pendingCount() == 0, "Timer queue cleanup\n");
    serial.writeString("Sleep cancellation, slot reuse, completion, immediate deadlines and capacity passed\n");
}

const KeyboardReader = struct {
    got: ?u8 = null,
    polls: usize = 0,
    fn poll(context: *anyopaque, waker: task.Waker) task.Poll {
        const self: *KeyboardReader = @ptrCast(@alignCast(context));
        self.polls += 1;
        self.got = kernel.keyboard.pollRead(waker) catch |err| failed(err);
        return if (self.got == null) .pending else .complete;
    }
    fn cleanup(_: *anyopaque, waker: task.Waker) void {
        kernel.keyboard.cancelRead(waker);
    }
};
fn controllerReady() void {
    for (0..100_000) |_| {
        if (io.inb(0x64) & 2 == 0) return;
        io.pause();
    }
    failed(error.ControllerTimeout);
}
const Periodic = struct {
    wait: ?task.Sleep = null,
    ticks: usize = 0,
    fn poll(context: *anyopaque, waker: task.Waker) task.Poll {
        const self: *Periodic = @ptrCast(@alignCast(context));
        if (self.wait == null) self.wait = task.sleep(20) catch |err| failed(err);
        if (!(self.wait.?.poll(waker) catch |err| failed(err))) return .pending;
        self.ticks += 1;
        self.wait = null;
        if (self.ticks == 1) {
            // Input arrives while the executor also has timer-backed work.
            irq.disable();
            controllerReady();
            io.outb(0x64, 0xd2);
            controllerReady();
            io.outb(0x60, 0x1e);
            irq.enable();
        }
        return if (self.ticks == 3) .complete else .yield;
    }
};
fn keyboardTest() !void {
    var executor: task.Executor = .{};
    var reader: KeyboardReader = .{};
    var periodic: Periodic = .{};
    _ = try executor.spawn(&reader, KeyboardReader.poll, KeyboardReader.cleanup);
    _ = try executor.spawn(&periodic, Periodic.poll, null);
    executor.run();
    check(reader.got == 'a' and reader.polls == 2 and periodic.ticks == 3, "Keyboard/timer coexistence\n");
    check(timer.pendingCount() == 0, "Periodic worker leaked waits\n");
    check(!kernel.apic.in_service(kernel.apic.keyboard_vector) and !kernel.apic.in_service(kernel.apic.timer_vector), "Missing EOI\n");
    serial.writeString("Periodic worker and real IRQ1 keyboard input completed together\n");
}

pub fn main() uefi.Status {
    serial.initSerial();
    if (task.sleep(1)) |_| failed(error.SleepBeforeInit) else |err| check(err == error.TimerNotInitialized, "Uninitialized sleep\n");
    const topology = kernel.acpi.discover() catch |err| failed(err);
    const bs = uefi.system_table.boot_services.?;
    var buffer: [32 * 1024]u8 align(@alignOf(uefi.tables.MemoryDescriptor)) = undefined;
    const map = bs.getMemoryMap(&buffer) catch |err| failed(err);
    bs.exitBootServices(uefi.handle, map.info.key) catch |err| failed(err);
    irq.init_gdt();
    irq.init_idt_with_handlers(.{ .double_fault = doubleFault, .page_fault = pageFault });
    kernel.memory.init(map) catch |err| failed(err);
    kernel.apic.init(topology) catch |err| failed(err);
    kernel.keyboard.init() catch |err| failed(err);
    timer.init() catch |err| failed(err);
    clockTests() catch |err| failed(err);
    sleepTests() catch |err| failed(err);
    lifecycleTests() catch |err| failed(err);
    keyboardTest() catch |err| failed(err);
    runner.exitQemu(.Success);
}
