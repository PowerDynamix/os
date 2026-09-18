//! Explicit poll state machines provide async tasks without language async syntax.
const task = @import("../task.zig");
const keyboard = @import("../keyboard.zig");
const cs = @import("../console.zig");

/// Basic execution example: keep local progress across cooperative yields.
pub const Counter = struct {
    next: u32 = 1,
    total: u32 = 0,

    pub fn poll(context: *anyopaque, _: task.Waker) task.Poll {
        const self: *Counter = @ptrCast(@alignCast(context));
        self.total += self.next;
        cs.k_console.print("Worker step {}: total = {}\n", .{ self.next, self.total });
        self.next += 1;
        if (self.next <= 5) return .yield;
        cs.k_console.print("Worker completed. Type on the PS/2 keyboard:\n", .{});
        return .complete;
    }
};

/// Async keyboard example: an empty FIFO parks this task without spinning.
pub const Keyboard = struct {
    characters: usize = 0,

    pub fn poll(context: *anyopaque, waker: task.Waker) task.Poll {
        const self: *Keyboard = @ptrCast(@alignCast(context));
        const ch = keyboard.pollRead(waker) catch |err| {
            cs.k_console.print("Keyboard task stopped: {s}\n", .{@errorName(err)});
            return .complete;
        } orelse return .pending;
        if (ch >= 32 or ch == '\n' or ch == '\t' or ch == '\x08') {
            cs.k_console.putChar(ch);
            self.characters += 1;
        }
        // Bound each poll to one character, including when input is continuous.
        return .yield;
    }

    pub fn cleanup(_: *anyopaque, waker: task.Waker) void {
        keyboard.cancelRead(waker);
    }
};
