const std = @import("std");
const uefi = std.os.uefi;
const kernel = @import("os_kernel");
const task = kernel.task;
const sync = kernel.sync;
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
    failed(error.UnexpectedDoubleFault);
}
fn pageFault(_: *const irq.InterruptFrame, _: u64, _: usize) noreturn {
    failed(error.UnexpectedPageFault);
}
fn parked(_: *anyopaque, _: task.Waker) task.Poll {
    return .pending;
}

fn ringTests() !void {
    var channel: sync.Channel(u32, 3) = .{};
    check(try channel.tryReceive() == null, "Empty receive\n");
    for (0..100) |round| {
        for (0..3) |index| check(try channel.trySend(@intCast(round * 3 + index)), "Ring send\n");
        check(!try channel.trySend(999), "Full ring accepted value\n");
        for (0..3) |index| check((try channel.tryReceive()).? == round * 3 + index, "FIFO wraparound\n");
    }
    check(try channel.trySend(42), "Final send\n");
    channel.close();
    channel.close();
    if (channel.trySend(43)) |_| return error.SendAfterClose else |err| check(err == error.Closed, "Closed send\n");
    check((try channel.tryReceive()).? == 42, "Close discarded buffered data\n");
    if (channel.tryReceive()) |_| return error.ReceiveAfterDrain else |err| check(err == error.Closed, "Closed empty receive\n");
    var optional: sync.Channel(?u8, 1) = .{};
    check(try optional.trySend(null), "Optional send\n");
    const result = try optional.tryReceive();
    check(result != null and result.? == null, "Null payload confused with pending\n");
    serial.writeString("Channel bounds, FIFO wraparound, optional payload and close/drain passed\n");
}

fn waitTests() !void {
    var executor: task.Executor = .{};
    var value: u8 = 0;
    var channel: sync.Channel(u8, 1) = .{};
    var event: sync.Event = .{};
    const a = try executor.spawn(&value, parked, null);
    const b = try executor.spawn(&value, parked, null);
    const c = try executor.spawn(&value, parked, null);
    while (executor.step()) {}
    for ([_]task.Waker{ a, b, c }) |handle| check(try channel.pollReceive(handle) == null, "Receive not pending\n");
    check(try channel.pollReceive(b) == null and channel.receivers.waiterCount() == 3, "Duplicate wait node\n");
    if (event.poll(b)) |_| return error.DoubleSubscription else |err| check(err == error.AlreadyWaiting, "Second wait must be rejected\n");
    // Unlink a middle node, then reuse its executor slot without inheriting a wait.
    try executor.cancel(b);
    const replacement = try executor.spawn(&value, parked, null);
    _ = executor.step();
    check(replacement.slot == b.slot and channel.receivers.waiterCount() == 2, "Cancellation retained wait\n");
    if (channel.pollReceive(b)) |_| return error.StaleReceive else |err| check(err == error.InvalidTask, "Stale handle\n");
    check(try channel.trySend(7), "Send to waiters\n");
    try executor.cancel(a); // Cancellation of a woken reader must not strand data.
    check(executor.step() and !executor.step(), "Broadcast wake/stale replacement\n");
    check((try channel.pollReceive(c)).? == 7, "Data stranded after wake cancellation\n");
    check(try channel.trySend(8), "Fill queue\n");
    check(!try channel.pollSend(9, replacement), "Sender did not suspend\n");
    check(!executor.step(), "Full sender busy-polled\n");
    check((try channel.tryReceive()).? == 8, "Drain queue\n");
    check(executor.step(), "Sender did not wake for space\n");
    check(try channel.pollSend(9, replacement), "Sender retry failed\n");
    check((try channel.tryReceive()).? == 9, "Retry duplicated/lost value\n");
    check(try channel.pollReceive(c) == null, "Receiver wait\n");
    channel.cancel(c);
    check(channel.receivers.waiterCount() == 0, "Explicit wait cancellation\n");
    check(try channel.pollReceive(c) == null, "Receiver rearm\n");
    channel.close();
    check(executor.step(), "Closed channel did not wake reader\n");
    if (channel.pollReceive(c)) |_| return error.ClosedPollReceive else |err| check(err == error.Closed, "Closed poll result\n");
    try executor.cancel(c);
    try executor.cancel(replacement);

    var full: sync.Channel(u8, 1) = .{};
    const sender = try executor.spawn(&value, parked, null);
    _ = executor.step();
    _ = try full.trySend(1);
    check(!try full.pollSend(2, sender), "Full send wait\n");
    full.close();
    check(executor.step(), "Close did not wake sender\n");
    if (full.pollSend(2, sender)) |_| return error.ClosedPollSend else |err| check(err == error.Closed, "Closed sender result\n");
    try executor.cancel(sender);
    serial.writeString("Channel waiter cleanup, duplicate waits, backpressure and closure wakes passed\n");
}

const EventTask = struct {
    event: *sync.Event,
    polls: usize = 0,
    complete_while_waiting: bool = false,
    fn poll(context: *anyopaque, waker: task.Waker) task.Poll {
        const self: *EventTask = @ptrCast(@alignCast(context));
        self.polls += 1;
        const ready = self.event.poll(waker) catch |err| failed(err);
        return if (ready or self.complete_while_waiting) .complete else .pending;
    }
};
var interrupt_event: sync.Event = .{};
var interrupt_channel: sync.Channel(u8, 1) = .{};
fn signalFromIrq() void {
    check(!irq.enabled(), "Event IRQ enabled interrupts\n");
    interrupt_event.signal();
    check(interrupt_channel.trySend(99) catch false, "IRQ channel send failed\n");
    check(!irq.enabled(), "Event signal changed IRQ IF\n");
}
const IrqReader = struct {
    polls: usize = 0,
    value: ?u8 = null,
    fn poll(context: *anyopaque, waker: task.Waker) task.Poll {
        const self: *IrqReader = @ptrCast(@alignCast(context));
        self.polls += 1;
        self.value = interrupt_channel.pollReceive(waker) catch |err| failed(err);
        return if (self.value == null) .pending else .complete;
    }
};
fn eventTests() !void {
    var executor: task.Executor = .{};
    var event: sync.Event = .{};
    var a: EventTask = .{ .event = &event };
    var b: EventTask = .{ .event = &event };
    const first = try executor.spawn(&a, EventTask.poll, null);
    _ = try executor.spawn(&b, EventTask.poll, null);
    while (executor.step()) {}
    check(event.waiters.waiterCount() == 2 and a.polls == 1 and b.polls == 1, "Event pending\n");
    event.signal();
    event.reset(); // Level-triggered: reset before poll makes both wait again.
    while (executor.step()) {}
    check(event.waiters.waiterCount() == 2 and a.polls == 2, "Reset before poll\n");
    irq.enable();
    event.signal();
    check(irq.enabled(), "Signal did not preserve enabled IF\n");
    event.signal();
    irq.disable();
    executor.run();
    check(a.polls == 3 and b.polls == 3 and event.waiters.waiterCount() == 0, "Event broadcast\n");
    a = .{ .event = &event };
    _ = try executor.spawn(&a, EventTask.poll, null);
    executor.run();
    check(a.polls == 1, "Signal before wait lost\n");
    event.reset();
    a = .{ .event = &event, .complete_while_waiting = true };
    _ = try executor.spawn(&a, EventTask.poll, null);
    executor.run();
    check(event.waiters.waiterCount() == 0, "Completion failed to unlink waiter\n");
    event.cancel(first); // Old generation cannot affect a new task.

    a = .{ .event = &interrupt_event };
    _ = try executor.spawn(&a, EventTask.poll, null);
    _ = executor.step();
    var reader: IrqReader = .{};
    _ = try executor.spawn(&reader, IrqReader.poll, null);
    _ = executor.step();
    kernel.apic.start_timer(100_000, signalFromIrq);
    executor.run();
    check(a.polls == 2 and !kernel.apic.in_service(kernel.apic.timer_vector), "IRQ event wake/EOI\n");
    check(reader.polls == 2 and reader.value == 99, "IRQ producer did not wake receiver\n");
    serial.writeString("Event latch, reset, broadcast, automatic cleanup and real IRQ wake passed\n");
}

const Message = struct { producer: usize, sequence: u32 };
const Pipe = sync.Channel(Message, 1);
const Producer = struct {
    pipe: *Pipe,
    id: usize,
    sequence: u32 = 0,
    stalls: usize = 0,
    remaining: *usize,
    fn poll(context: *anyopaque, waker: task.Waker) task.Poll {
        const self: *Producer = @ptrCast(@alignCast(context));
        const sent = self.pipe.pollSend(.{ .producer = self.id, .sequence = self.sequence }, waker) catch |err| failed(err);
        if (!sent) {
            self.stalls += 1;
            return .pending;
        }
        self.sequence += 1;
        if (self.sequence < 100) return .yield;
        self.remaining.* -= 1;
        if (self.remaining.* == 0) self.pipe.close();
        return .complete;
    }
};
const Consumer = struct {
    pipe: *Pipe,
    expected: [2]u32 = @splat(0),
    fn poll(context: *anyopaque, waker: task.Waker) task.Poll {
        const self: *Consumer = @ptrCast(@alignCast(context));
        const message = self.pipe.pollReceive(waker) catch |err| {
            check(err == error.Closed, "Consumer error\n");
            return .complete;
        } orelse return .pending;
        check(message.producer < 2 and message.sequence == self.expected[message.producer], "Message duplicated/lost/reordered\n");
        self.expected[message.producer] += 1;
        return .yield;
    }
};
fn executionTest() !void {
    var executor: task.Executor = .{};
    var pipe: Pipe = .{};
    var remaining: usize = 2;
    var a: Producer = .{ .pipe = &pipe, .id = 0, .remaining = &remaining };
    var b: Producer = .{ .pipe = &pipe, .id = 1, .remaining = &remaining };
    var consumer: Consumer = .{ .pipe = &pipe };
    _ = try executor.spawn(&a, Producer.poll, null);
    _ = try executor.spawn(&b, Producer.poll, null);
    _ = try executor.spawn(&consumer, Consumer.poll, null);
    executor.run();
    check(consumer.expected[0] == 100 and consumer.expected[1] == 100, "Not all messages received\n");
    check(a.stalls + b.stalls > 0, "Backpressure was not exercised\n");
    check(pipe.senders.waiterCount() == 0 and pipe.receivers.waiterCount() == 0, "Execution leaked waiters\n");
    serial.writeString("Two producers delivered 200 ordered messages under backpressure\n");
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
    ringTests() catch |err| failed(err);
    waitTests() catch |err| failed(err);
    eventTests() catch |err| failed(err);
    executionTest() catch |err| failed(err);
    check(!irq.enabled(), "Communication changed caller IF\n");
    runner.exitQemu(.Success);
}
