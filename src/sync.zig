//! Single-CPU communication. Short IF-clear regions make condition checks and
//! subscriptions atomic with IRQ producers. No allocations or task polling here.
const task = @import("task.zig");
const irq = @import("interrputs.zig");

fn restore(enabled: bool) void {
    if (enabled) irq.enable() else irq.disable();
}

/// FIFO messages copied by value. Keep the channel stable while tasks wait on it.
/// Payload resources remain caller-owned until sent, then receiver-owned; closing
/// does not destroy buffered values. Drain them before releasing channel storage.
pub fn Channel(comptime T: type, comptime capacity: usize) type {
    if (capacity == 0) @compileError("Channel capacity must be positive");
    return struct {
        const Self = @This();
        buffer: [capacity]T = undefined,
        head: usize = 0,
        tail: usize = 0,
        len: usize = 0,
        closed: bool = false,
        senders: task.WaitQueue = .{},
        receivers: task.WaitQueue = .{},

        fn advance(index: usize) usize {
            return if (index == capacity - 1) 0 else index + 1;
        }

        /// IRQ-safe for small payloads. false means full; nothing was consumed.
        pub fn trySend(self: *Self, value: T) error{Closed}!bool {
            const enabled = irq.enabled();
            irq.disable();
            defer restore(enabled);
            if (self.closed) return error.Closed;
            if (self.len == capacity) return false;
            self.buffer[self.tail] = value;
            self.tail = advance(self.tail);
            self.len += 1;
            self.receivers.wakeAll();
            return true;
        }

        /// null means empty and open. Closed channels first deliver buffered data,
        /// then return error.Closed. IRQ-safe; never waits.
        pub fn tryReceive(self: *Self) error{Closed}!?T {
            const enabled = irq.enabled();
            irq.disable();
            defer restore(enabled);
            if (self.len == 0) {
                if (self.closed) return error.Closed;
                return null;
            }
            const value = self.buffer[self.head];
            self.head = advance(self.head);
            self.len -= 1;
            self.senders.wakeAll();
            return value;
        }

        /// false means registered for space: return .pending and retain the value
        /// in task context. Retry it on wake; only true transfers the message.
        pub fn pollSend(self: *Self, value: T, waker: task.Waker) !bool {
            const enabled = irq.enabled();
            irq.disable();
            defer restore(enabled);
            if (!waker.isActive()) return error.InvalidTask;
            const sent = self.trySend(value) catch |err| {
                self.senders.cancel(waker);
                return err;
            };
            if (sent) self.senders.cancel(waker) else try self.senders.wait(waker);
            return sent;
        }

        /// null means registered for data: return .pending. Condition testing and
        /// registration are atomic, so an IRQ cannot produce a lost wakeup.
        pub fn pollReceive(self: *Self, waker: task.Waker) !?T {
            const enabled = irq.enabled();
            irq.disable();
            defer restore(enabled);
            if (!waker.isActive()) return error.InvalidTask;
            const value = self.tryReceive() catch |err| {
                self.receivers.cancel(waker);
                return err;
            };
            if (value != null) self.receivers.cancel(waker) else try self.receivers.wait(waker);
            return value;
        }

        /// Abandon a send/receive without cancelling its task (e.g. timeout).
        pub fn cancel(self: *Self, waker: task.Waker) void {
            const enabled = irq.enabled();
            irq.disable();
            defer restore(enabled);
            self.senders.cancel(waker);
            self.receivers.cancel(waker);
        }

        /// Idempotent, IRQ-safe shutdown; wake both sides to observe closure.
        pub fn close(self: *Self) void {
            const enabled = irq.enabled();
            irq.disable();
            defer restore(enabled);
            self.closed = true;
            self.senders.wakeAll();
            self.receivers.wakeAll();
        }
    };
}

/// Manual-reset event: signal latches readiness and wakes every waiter. It stays
/// ready until reset; repeated signals coalesce. Not a counter or a pulse queue.
pub const Event = struct {
    signaled: bool = false,
    waiters: task.WaitQueue = .{},

    pub fn poll(self: *Event, waker: task.Waker) !bool {
        const enabled = irq.enabled();
        irq.disable();
        defer restore(enabled);
        if (!waker.isActive()) return error.InvalidTask;
        if (self.signaled) {
            self.waiters.cancel(waker);
            return true;
        }
        try self.waiters.wait(waker);
        return false;
    }

    /// IRQ-safe; only schedules tasks, never executes them in the handler.
    pub fn signal(self: *Event) void {
        const enabled = irq.enabled();
        irq.disable();
        defer restore(enabled);
        self.signaled = true;
        self.waiters.wakeAll();
    }

    /// A task that has not polled yet will wait again if reset precedes its poll.
    pub fn reset(self: *Event) void {
        const enabled = irq.enabled();
        irq.disable();
        defer restore(enabled);
        self.signaled = false;
    }

    pub fn cancel(self: *Event, waker: task.Waker) void {
        self.waiters.cancel(waker);
    }
};
