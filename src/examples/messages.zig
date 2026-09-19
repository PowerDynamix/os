//! A fast producer and slower consumer demonstrate channel backpressure. The
//! producer waits on an event for confirmation that the consumer drained the FIFO.
const task = @import("../task.zig");
const sync = @import("../sync.zig");
const shell = @import("../shell.zig");
const std = @import("std");

pub const Demo = struct {
    messages: sync.Channel(u32, 2) = .{},
    drained: sync.Event = .{},
    output: *shell.Shell,
    next: u32 = 1,
    total: u32 = 0,
    received: u32 = 0,
    pause: ?task.Sleep = null,

    pub fn produce(context: *anyopaque, waker: task.Waker) task.Poll {
        const self: *Demo = @ptrCast(@alignCast(context));
        if (self.next <= 5) {
            const sent = self.messages.pollSend(self.next, waker) catch {
                self.output.notify("Message producer stopped.");
                return .complete;
            };
            if (!sent) return .pending;
            self.next += 1;
            return .yield;
        }
        self.messages.close();
        if (!(self.drained.poll(waker) catch return .complete)) return .pending;
        self.output.notify(if (self.received == 5) "Message demo complete: consumer acknowledged all five messages." else "Message demo ended before all messages were consumed.");
        return .complete;
    }

    pub fn consume(context: *anyopaque, waker: task.Waker) task.Poll {
        const self: *Demo = @ptrCast(@alignCast(context));
        if (self.pause == null) self.pause = task.sleep(250) catch return .complete;
        if (!(self.pause.?.poll(waker) catch return .complete)) return .pending;
        const value = self.messages.pollReceive(waker) catch |err| {
            if (err != error.Closed) self.output.notify("Message consumer stopped.");
            return .complete;
        } orelse return .pending;
        self.pause = null;
        self.total += value;
        self.received += 1;
        var buffer: [96]u8 = undefined;
        self.output.notify(std.fmt.bufPrint(&buffer, "Message consumer received {}; total = {}", .{ value, self.total }) catch unreachable);
        return .yield;
    }

    /// Always unblock the peer if either task terminates early.
    pub fn producerCleanup(context: *anyopaque, _: task.Waker) void {
        const self: *Demo = @ptrCast(@alignCast(context));
        self.messages.close();
    }
    pub fn consumerCleanup(context: *anyopaque, _: task.Waker) void {
        const self: *Demo = @ptrCast(@alignCast(context));
        self.messages.close();
        self.drained.signal();
    }
};
