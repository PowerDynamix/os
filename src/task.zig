//! Single-CPU cooperative executor. Task state lives in caller-owned contexts;
//! poll functions must return promptly. No separate stacks or timer preemption.
const std = @import("std");
const irq = @import("interrputs.zig");
const timer = @import("timer.zig");

pub const Poll = enum { pending, yield, complete };
pub const PollFn = *const fn (*anyopaque, Waker) Poll;
pub const CleanupFn = *const fn (*anyopaque, Waker) void;
pub const capacity = 32;

fn restore(enabled: bool) void {
    if (enabled) irq.enable() else irq.disable();
}

/// Copyable task identity and wake handle. The executor must outlive every copy.
/// Generation checking prevents a late wake from targeting a reused task slot.
pub const Waker = struct {
    executor: *Executor,
    slot: u5,
    generation: u64,

    pub fn eql(a: Waker, b: Waker) bool {
        return a.executor == b.executor and a.slot == b.slot and a.generation == b.generation;
    }
    pub fn isActive(self: Waker) bool {
        const enabled = irq.enabled();
        irq.disable();
        defer restore(enabled);
        return self.valid();
    }
    fn valid(self: Waker) bool {
        const slot = &self.executor.slots[self.slot];
        return slot.poll != null and slot.generation == self.generation;
    }
    /// IRQ-safe and allocation-free. Repeated wakes coalesce into one ready bit.
    /// Clear-before-poll means a wake during poll is retained even on .pending.
    pub fn wake(self: Waker) void {
        const enabled = irq.enabled();
        irq.disable();
        defer restore(enabled);
        if (self.valid()) self.executor.ready |= @as(u32, 1) << self.slot;
    }
};

const Slot = struct {
    name: []const u8 = "task",
    context: *anyopaque = undefined,
    poll: ?PollFn = null,
    cleanup: ?CleanupFn = null,
    generation: u64 = 0,
    waker: Waker = undefined,
    wait: WaitNode = .{},
};

const WaitNode = struct {
    owner: ?*WaitQueue = null,
    previous: ?*WaitNode = null,
    next: ?*WaitNode = null,
    waker: Waker = undefined,

    fn unlink(self: *WaitNode) void {
        const queue = self.owner orelse return;
        if (self.previous) |node| node.next = self.next else queue.first = self.next;
        if (self.next) |node| node.previous = self.previous else queue.last = self.previous;
        queue.count -= 1;
        self.owner = null;
        self.previous = null;
        self.next = null;
    }
};

/// Intrusive, allocation-free task wait list. One channel/event wait per task.
/// Keep the queue stable until empty. Executor completion/cancellation detaches
/// nodes automatically. Condition checks and wait() must share an IF-clear region.
pub const WaitQueue = struct {
    first: ?*WaitNode = null,
    last: ?*WaitNode = null,
    count: usize = 0,

    pub fn wait(self: *WaitQueue, waker: Waker) !void {
        const enabled = irq.enabled();
        irq.disable();
        defer restore(enabled);
        if (!waker.valid()) return error.InvalidTask;
        const node = &waker.executor.slots[waker.slot].wait;
        if (node.owner == self) return;
        if (node.owner != null) return error.AlreadyWaiting;
        node.owner = self;
        node.previous = self.last;
        node.next = null;
        node.waker = waker;
        if (self.last) |last| last.next = node else self.first = node;
        self.last = node;
        self.count += 1;
    }

    pub fn cancel(self: *WaitQueue, waker: Waker) void {
        const enabled = irq.enabled();
        irq.disable();
        defer restore(enabled);
        if (!waker.valid()) return;
        const node = &waker.executor.slots[waker.slot].wait;
        if (node.owner == self) node.unlink();
    }

    /// Wake all contenders to avoid stranding work when a woken task is cancelled.
    /// A wake means retry the condition; it does not reserve a resource.
    pub fn wakeAll(self: *WaitQueue) void {
        const enabled = irq.enabled();
        irq.disable();
        defer restore(enabled);
        while (self.first) |node| {
            node.unlink();
            node.waker.wake();
        }
    }

    pub fn waiterCount(self: *WaitQueue) usize {
        const enabled = irq.enabled();
        irq.disable();
        defer restore(enabled);
        return self.count;
    }
};

/// Store this value in task context across polls; creating it again restarts delay.
/// One outstanding sleep per task. Completion/cancellation automatically detaches it.
pub const Sleep = struct {
    deadline: timer.Instant,

    pub fn poll(self: Sleep, waker: Waker) !bool {
        const enabled = irq.enabled();
        irq.disable();
        defer restore(enabled);
        if (!waker.valid()) return error.InvalidTask;
        return timer.waitUntil(self.deadline, &waker.executor.slots[waker.slot], wakeSleepingTask);
    }

    /// Abandon an in-progress sleep when selecting another event in the same task.
    pub fn cancel(waker: Waker) void {
        const enabled = irq.enabled();
        irq.disable();
        defer restore(enabled);
        if (waker.valid()) timer.cancel(&waker.executor.slots[waker.slot]);
    }
};

pub fn sleep(duration_ms: u64) !Sleep {
    return .{ .deadline = try timer.deadlineAfter(duration_ms) };
}

pub fn sleepUntil(deadline: timer.Instant) Sleep {
    return .{ .deadline = deadline };
}

fn wakeSleepingTask(context: *anyopaque) void {
    const slot: *Slot = @ptrCast(@alignCast(context));
    slot.waker.wake();
}

pub const Executor = struct {
    slots: [capacity]Slot = @splat(.{}),
    ready: u32 = 0,
    count: usize = 0,
    cursor: u5 = 0,
    polling: ?u5 = null,
    running: bool = false,

    /// Keep self/context stable until completion or cancellation. Cleanup runs
    /// exactly once in task context, with IF clear, on either path. It may detach
    /// event subscriptions and free context storage, but must not run the executor.
    /// All APIs except Waker.wake/isActive are for task context after APIC setup.
    pub fn spawn(self: *Executor, context: *anyopaque, poll: PollFn, cleanup: ?CleanupFn) !Waker {
        return self.spawnNamed("task", context, poll, cleanup);
    }

    /// Name storage must outlive the task and any retained diagnostic snapshots.
    pub fn spawnNamed(self: *Executor, name: []const u8, context: *anyopaque, poll: PollFn, cleanup: ?CleanupFn) !Waker {
        const enabled = irq.enabled();
        irq.disable();
        defer restore(enabled);
        for (&self.slots, 0..) |*slot, i| {
            if (slot.poll != null or slot.generation == std.math.maxInt(u64)) continue;
            slot.generation += 1;
            slot.context = context;
            slot.name = name;
            slot.poll = poll;
            slot.cleanup = cleanup;
            self.count += 1;
            const index: u5 = @intCast(i);
            self.ready |= @as(u32, 1) << index;
            slot.waker = .{ .executor = self, .slot = index, .generation = slot.generation };
            return slot.waker;
        }
        return error.TaskCapacityExceeded;
    }

    fn finish(self: *Executor, index: u5) void {
        std.debug.assert(!irq.enabled());
        const slot = &self.slots[index];
        const context = slot.context;
        const cleanup = slot.cleanup;
        const waker: Waker = .{ .executor = self, .slot = index, .generation = slot.generation };
        slot.wait.unlink();
        timer.cancel(slot);
        slot.poll = null;
        slot.cleanup = null;
        self.ready &= ~(@as(u32, 1) << index);
        self.count -= 1;
        if (cleanup) |function| function(context, waker);
    }

    pub fn cancel(self: *Executor, handle: Waker) !void {
        const enabled = irq.enabled();
        irq.disable();
        defer restore(enabled);
        if (handle.executor != self or !handle.valid()) return error.InvalidTask;
        if (self.polling == handle.slot) return error.TaskRunning;
        self.finish(handle.slot);
    }

    pub fn activeCount(self: *Executor) usize {
        const enabled = irq.enabled();
        irq.disable();
        defer restore(enabled);
        return self.count;
    }

    pub const TaskInfo = struct {
        slot: usize,
        generation: u64,
        name: []const u8,
        state: enum { running, ready, waiting },
    };

    /// Copies up to output.len live tasks without holding IF clear during printing.
    pub fn snapshot(self: *Executor, output: []TaskInfo) []TaskInfo {
        const enabled = irq.enabled();
        irq.disable();
        defer restore(enabled);
        var count: usize = 0;
        for (self.slots, 0..) |slot, index| {
            if (slot.poll == null) continue;
            if (count == output.len) break;
            output[count] = .{
                .slot = index,
                .generation = slot.generation,
                .name = slot.name,
                .state = if (self.polling == @as(u5, @intCast(index))) .running else if (self.ready & (@as(u32, 1) << @intCast(index)) != 0) .ready else .waiting,
            };
            count += 1;
        }
        return output[0..count];
    }

    /// Poll at most one ready task, round-robin. Poll runs with interrupts enabled;
    /// the caller's IF state is restored afterward. Returns false when none is ready.
    pub fn step(self: *Executor) bool {
        const enabled = irq.enabled();
        irq.disable();
        defer restore(enabled);
        std.debug.assert(self.polling == null);
        for (0..capacity) |_| {
            const index = self.cursor;
            self.cursor +%= 1;
            const mask = @as(u32, 1) << index;
            if (self.ready & mask == 0) continue;
            self.ready &= ~mask;
            const slot = &self.slots[index];
            const waker: Waker = .{ .executor = self, .slot = index, .generation = slot.generation };
            self.polling = index;
            irq.enable();
            const result = slot.poll.?(slot.context, waker);
            irq.disable();
            self.polling = null;
            switch (result) {
                .pending => {},
                .yield => self.ready |= mask,
                .complete => self.finish(index),
            }
            return true;
        }
        return false;
    }

    /// Run until every task completes. Pending tasks need an external wake source.
    /// Check readiness with IF clear, then STI;HLT atomically avoids a lost wake.
    pub fn run(self: *Executor) void {
        std.debug.assert(!self.running and self.polling == null);
        const enabled = irq.enabled();
        self.running = true;
        defer {
            self.running = false;
            restore(enabled);
        }
        while (true) {
            irq.disable();
            if (self.count == 0) return;
            if (self.ready != 0) {
                _ = self.step();
            } else {
                irq.wait_for_interrupt();
            }
        }
    }
};
