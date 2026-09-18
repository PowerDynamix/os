//! Single-CPU cooperative executor. Task state lives in caller-owned contexts;
//! poll functions must return promptly. No separate stacks or timer preemption.
const std = @import("std");
const irq = @import("interrputs.zig");

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
    context: *anyopaque = undefined,
    poll: ?PollFn = null,
    cleanup: ?CleanupFn = null,
    generation: u64 = 0,
};

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
        const enabled = irq.enabled();
        irq.disable();
        defer restore(enabled);
        for (&self.slots, 0..) |*slot, i| {
            if (slot.poll != null or slot.generation == std.math.maxInt(u64)) continue;
            slot.generation += 1;
            slot.context = context;
            slot.poll = poll;
            slot.cleanup = cleanup;
            self.count += 1;
            const index: u5 = @intCast(i);
            self.ready |= @as(u32, 1) << index;
            return .{ .executor = self, .slot = index, .generation = slot.generation };
        }
        return error.TaskCapacityExceeded;
    }

    fn finish(self: *Executor, index: u5) void {
        std.debug.assert(!irq.enabled());
        const slot = &self.slots[index];
        const context = slot.context;
        const cleanup = slot.cleanup;
        const waker: Waker = .{ .executor = self, .slot = index, .generation = slot.generation };
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
