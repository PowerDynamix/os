const std = @import("std");
const uefi = std.os.uefi;
const kernel = @import("os_kernel");
const task = kernel.task;
const irq = kernel.interrupts;
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
    serial.writeString("Unexpected double fault\n");
    runner.exitQemu(.Failed);
}
fn pageFault(_: *const irq.InterruptFrame, _: u64, _: usize) noreturn {
    serial.writeString("Unexpected page fault\n");
    runner.exitQemu(.Failed);
}

var trace: [12]u8 = undefined;
var trace_len: usize = 0;
const Worker = struct {
    id: u8,
    polls: usize = 0,
    cleaned: usize = 0,
    fn poll(context: *anyopaque, _: task.Waker) task.Poll {
        const self: *Worker = @ptrCast(@alignCast(context));
        check(irq.enabled(), "Task polled with IF clear\n");
        trace[trace_len] = self.id;
        trace_len += 1;
        self.polls += 1;
        return if (self.polls == 4) .complete else .yield;
    }
    fn cleanup(context: *anyopaque, _: task.Waker) void {
        const self: *Worker = @ptrCast(@alignCast(context));
        self.cleaned += 1;
    }
};

const Sleeper = struct {
    polls: usize = 0,
    cleaned: usize = 0,
    self_wake: bool = false,
    done: bool = false,
    fn poll(context: *anyopaque, waker: task.Waker) task.Poll {
        const self: *Sleeper = @ptrCast(@alignCast(context));
        self.polls += 1;
        if (self.self_wake) {
            self.self_wake = false;
            waker.wake();
        }
        return if (self.done) .complete else .pending;
    }
    fn cleanup(context: *anyopaque, _: task.Waker) void {
        const self: *Sleeper = @ptrCast(@alignCast(context));
        self.cleaned += 1;
    }
};

fn executionTests() !void {
    var executor: task.Executor = .{};
    var a: Worker = .{ .id = 1 };
    var b: Worker = .{ .id = 2 };
    var c: Worker = .{ .id = 3 };
    _ = try executor.spawn(&a, Worker.poll, Worker.cleanup);
    _ = try executor.spawn(&b, Worker.poll, Worker.cleanup);
    _ = try executor.spawn(&c, Worker.poll, Worker.cleanup);
    executor.run();
    check(!irq.enabled(), "Executor did not restore IF\n");
    check(std.mem.eql(u8, &trace, &.{ 1, 2, 3, 1, 2, 3, 1, 2, 3, 1, 2, 3 }), "Round-robin fairness\n");
    check(executor.activeCount() == 0 and a.cleaned == 1 and b.cleaned == 1 and c.cleaned == 1, "Task completion cleanup\n");

    var sleeper: Sleeper = .{ .self_wake = true };
    const old = try executor.spawn(&sleeper, Sleeper.poll, Sleeper.cleanup);
    check(executor.step() and sleeper.polls == 1, "Initial scheduling\n");
    check(executor.step() and sleeper.polls == 2, "Wake during poll lost\n");
    check(!executor.step(), "Pending task busy-polled\n");
    old.wake();
    old.wake();
    check(executor.step() and !executor.step() and sleeper.polls == 3, "Wake coalescing\n");
    try executor.cancel(old);
    check(sleeper.cleaned == 1 and !old.isActive(), "Cancel cleanup\n");
    var reused: Sleeper = .{};
    const fresh = try executor.spawn(&reused, Sleeper.poll, Sleeper.cleanup);
    check(fresh.slot == old.slot and fresh.generation != old.generation, "Task slot generation\n");
    _ = executor.step();
    old.wake();
    check(!executor.step(), "Stale waker woke reused slot\n");
    if (executor.cancel(old)) |_| return error.StaleCancellation else |err| check(err == error.InvalidTask, "Cancel stale ID\n");
    reused.done = true;
    fresh.wake();
    irq.enable();
    executor.run();
    check(irq.enabled(), "Enabled IF not restored\n");
    irq.disable();
    check(reused.cleaned == 1, "Reused slot cleanup\n");

    var sleepers: [task.capacity]Sleeper = @splat(.{});
    var handles: [task.capacity]task.Waker = undefined;
    for (&sleepers, &handles) |*context, *handle| handle.* = try executor.spawn(context, Sleeper.poll, Sleeper.cleanup);
    if (executor.spawn(&sleeper, Sleeper.poll, null)) |_| return error.ExpectedCapacityError else |err| check(err == error.TaskCapacityExceeded, "Task capacity\n");
    for (handles) |handle| try executor.cancel(handle);
    for (sleepers) |context| check(context.cleaned == 1, "Capacity cancellation cleanup\n");
    check(executor.activeCount() == 0 and !executor.step(), "Cancelled runnable tasks remain\n");
    serial.writeString("Task fairness, completion, cancellation, stale wakes and capacity passed\n");
}

var timer_waker: ?task.Waker = null;
var timer_fired = false;
fn timerWake() void {
    check(!irq.enabled(), "IRQ has IF set\n");
    @atomicStore(bool, &timer_fired, true, .release);
    timer_waker.?.wake();
}
const TimerTask = struct {
    polls: usize = 0,
    fn poll(context: *anyopaque, waker: task.Waker) task.Poll {
        const self: *TimerTask = @ptrCast(@alignCast(context));
        self.polls += 1;
        if (@atomicLoad(bool, &timer_fired, .acquire)) return .complete;
        irq.disable();
        timer_waker = waker;
        kernel.apic.start_timer(100_000, timerWake);
        irq.enable();
        return .pending;
    }
};
fn idleTest() !void {
    var executor: task.Executor = .{};
    var timer: TimerTask = .{};
    _ = try executor.spawn(&timer, TimerTask.poll, null);
    executor.run();
    timer_waker = null;
    check(timer.polls == 2 and timer_fired, "IRQ idle wake did not resume task\n");
    check(!kernel.apic.in_service(kernel.apic.timer_vector), "Timer EOI missing\n");
    serial.writeString("Idle executor resumed from APIC IRQ wake\n");
}

const Reader = struct {
    polls: usize = 0,
    got: ?u8 = null,
    fn poll(context: *anyopaque, waker: task.Waker) task.Poll {
        const self: *Reader = @ptrCast(@alignCast(context));
        self.polls += 1;
        self.got = kernel.keyboard.pollRead(waker) catch |err| failed(err);
        return if (self.got != null) .complete else .pending;
    }
    fn cleanup(_: *anyopaque, waker: task.Waker) void {
        kernel.keyboard.cancelRead(waker);
    }
};
fn controllerReady() void {
    for (0..100_000) |_| {
        if (kernel.io.inb(0x64) & 2 == 0) return;
        kernel.io.pause();
    }
    failed(error.ControllerTimeout);
}
fn inject(_: *anyopaque, _: task.Waker) task.Poll {
    // Real i8042 output-buffer injection, delivered through IRQ1 after this poll.
    irq.disable();
    controllerReady();
    kernel.io.outb(0x64, 0xd2);
    controllerReady();
    kernel.io.outb(0x60, 0x1e);
    irq.enable();
    return .complete;
}
fn keyboardTests() !void {
    var executor: task.Executor = .{};
    var reader: Reader = .{};
    const handle = try executor.spawn(&reader, Reader.poll, Reader.cleanup);
    check(executor.step() and reader.polls == 1 and reader.got == null, "Keyboard did not suspend\n");
    check(!executor.step(), "Keyboard busy-polled\n");
    var other: Sleeper = .{};
    const second = try executor.spawn(&other, Sleeper.poll, Sleeper.cleanup);
    if (kernel.keyboard.pollRead(second)) |_| return error.ExpectedReaderBusy else |err| check(err == error.ReaderBusy, "Multiple readers\n");
    try executor.cancel(second);
    try executor.cancel(handle);
    check(!handle.isActive(), "Reader cancellation\n");
    // A new reader can subscribe after cancellation without dangling registration.
    reader = .{};
    _ = try executor.spawn(&reader, Reader.poll, Reader.cleanup);
    _ = executor.step();
    _ = try executor.spawn(&other, inject, null);
    executor.run();
    check(reader.got == 'a' and reader.polls == 2, "IRQ1 did not resume keyboard task\n");
    check(!kernel.apic.in_service(kernel.apic.keyboard_vector), "Keyboard EOI missing\n");
    // Input arriving before subscription is read on the first poll.
    const before = @atomicLoad(u32, &kernel.keyboard.interrupt_count, .monotonic);
    _ = inject(&other, handle);
    irq.disable();
    while (@atomicLoad(u32, &kernel.keyboard.interrupt_count, .monotonic) == before) {
        irq.wait_for_interrupt();
        irq.disable();
    }
    reader = .{};
    _ = try executor.spawn(&reader, Reader.poll, Reader.cleanup);
    executor.run();
    check(reader.got == 'a' and reader.polls == 1, "Buffered keyboard input lost\n");
    serial.writeString("Async keyboard IRQ wake, cancellation and buffered input passed\n");
}

pub fn main() uefi.Status {
    serial.initSerial();
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
    executionTests() catch |err| failed(err);
    idleTest() catch |err| failed(err);
    keyboardTests() catch |err| failed(err);
    runner.exitQemu(.Success);
}
