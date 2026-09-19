//! Bounded, allocation-free shell. Single keyboard consumer, polled as a task.
const std = @import("std");
const task = @import("task.zig");
const keyboard = @import("keyboard.zig");
const memory = @import("memory.zig");
const console = @import("console.zig");

pub const line_capacity = 128;

/// Task-context output operations. redraw replaces the current prompt row;
/// null hides the prompt. Keep input on one row (scroll the view for long lines).
pub const Output = struct {
    context: *anyopaque,
    write: *const fn (*anyopaque, []const u8) void,
    clear: *const fn (*anyopaque) void,
    redraw: *const fn (*anyopaque, ?[]const u8) void,

    pub fn framebuffer(value: *console.Console) Output {
        return .{ .context = value, .write = writeConsole, .clear = clearConsole, .redraw = redrawConsole };
    }
    fn writeConsole(ctx: *anyopaque, text: []const u8) void {
        const value: *console.Console = @ptrCast(@alignCast(ctx));
        value.putString(text);
    }
    fn clearConsole(ctx: *anyopaque) void {
        const value: *console.Console = @ptrCast(@alignCast(ctx));
        value.clear();
    }
    fn redrawConsole(ctx: *anyopaque, input: ?[]const u8) void {
        const value: *console.Console = @ptrCast(@alignCast(ctx));
        value.clearLine();
        const line = input orelse return;
        const columns = value.fb.width / value.font.width;
        if (columns < 7) return;
        value.putString("os> ");
        const available = columns - 6; // Prompt, continuation marker, spare cell.
        if (line.len > available) value.putChar('<');
        value.putString(line[line.len - @min(line.len, available) ..]);
    }
};

pub const Shell = struct {
    executor: *task.Executor,
    output: Output,
    buffer: [line_capacity]u8 = undefined,
    len: usize = 0,
    started: bool = false,
    full_reported: bool = false,
    stress: memory.Stress = undefined,
    stress_handle: ?task.Waker = null,

    pub fn init(executor: *task.Executor, output: Output) Shell {
        return .{ .executor = executor, .output = output };
    }
    pub fn line(self: *const Shell) []const u8 {
        return self.buffer[0..self.len];
    }
    fn write(self: *Shell, text: []const u8) void {
        self.output.write(self.output.context, text);
    }
    fn print(self: *Shell, comptime format: []const u8, args: anytype) void {
        var buffer: [512]u8 = undefined;
        self.write(std.fmt.bufPrint(&buffer, format, args) catch "[output too long]\n");
    }
    fn redraw(self: *Shell) void {
        self.output.redraw(self.output.context, self.line());
    }

    /// Background tasks route messages here to preserve partially typed commands.
    /// No yields/allocations: prompt removal, output and redraw are one task turn.
    pub fn notify(self: *Shell, text: []const u8) void {
        if (self.started) {
            self.output.redraw(self.output.context, null);
        }
        self.write(text);
        if (text.len == 0 or text[text.len - 1] != '\n') self.write("\n");
        if (self.started) self.redraw();
    }

    pub fn start(self: *Shell) void {
        if (self.started) return;
        self.started = true;
        self.write("Shell ready. Type 'help'.\n");
        self.redraw();
    }

    /// Append/backspace editing plus Ctrl-U (line), Ctrl-W (word), Ctrl-C (cancel).
    pub fn feed(self: *Shell, ch: u8) void {
        self.start();
        switch (ch) {
            '\n', '\r' => {
                self.write("\n");
                self.execute(self.line());
                self.len = 0;
                self.full_reported = false;
            },
            8, 127 => {
                if (self.len > 0) self.len -= 1;
                self.full_reported = false;
            },
            21 => { // Ctrl-U
                self.len = 0;
                self.full_reported = false;
            },
            23 => { // Ctrl-W
                while (self.len > 0 and self.buffer[self.len - 1] == ' ') self.len -= 1;
                while (self.len > 0 and self.buffer[self.len - 1] != ' ') self.len -= 1;
                self.full_reported = false;
            },
            3 => { // Ctrl-C
                self.write("^C\n");
                self.len = 0;
                self.full_reported = false;
            },
            else => {
                const printable = if (ch == '\t') @as(u8, ' ') else ch;
                if (printable < 32 or printable > 126) return;
                if (self.len == self.buffer.len) {
                    if (!self.full_reported) self.notify("Line full (128 characters). Use Backspace or Ctrl-U.");
                    self.full_reported = true;
                    return;
                }
                self.buffer[self.len] = printable;
                self.len += 1;
            },
        }
        self.redraw();
    }

    fn execute(self: *Shell, input: []const u8) void {
        var words = std.mem.tokenizeAny(u8, input, " \t");
        const command = words.next() orelse return;
        if (words.next() != null) {
            self.write("Commands take no arguments. Type 'help'.\n");
            return;
        }
        if (std.mem.eql(u8, command, "help")) {
            self.write("help  - show commands and editing keys\nmem   - show memory diagnostics\nmemtest - start allocator stress test\nmemstop - cancel allocator stress test\ntasks - list live tasks and their states\nclear - clear the screen\nBackspace: erase; Ctrl-U: clear line; Ctrl-W: erase word; Ctrl-C: cancel.\n");
        } else if (std.mem.eql(u8, command, "mem")) {
            self.print("Managed RAM: {} KiB; free: {} KiB ({} frames)\n", .{
                memory.physical.total_count * 4, memory.physical.free_count * 4, memory.physical.free_count,
            });
            const stats = memory.heap.inspect() catch |err| {
                self.print("Heap integrity FAILED: {s}\n", .{@errorName(err)});
                return;
            };
            const free = stats.free_bytes;
            self.print("Heap: {} bytes; free: {}; used incl. metadata/padding: {}; allocations: {}\n", .{
                memory.heap.size, free, memory.heap.size - free, memory.heap.live_allocations,
            });
            self.print("Requested: {} bytes; peak occupied: {} bytes\n", .{ memory.heap.requested_bytes, memory.heap.peak_used_bytes });
            self.print("Heap allocations/frees: {}/{}; OOM: {}; resizes/rejected: {}/{}\n", .{
                memory.heap.allocations, memory.heap.frees, memory.heap.allocation_failures, memory.heap.resizes, memory.heap.resize_failures,
            });
            self.print("Free blocks: {}; largest: {} bytes; external fragmentation: {}%\n", .{
                stats.free_blocks, stats.largest_free_block, if (free == 0) @as(usize, 0) else (free - stats.largest_free_block) * 100 / free,
            });
            self.print("Frames used/peak: {}/{}; alloc/free: {}/{}; OOM: {}; regions: {}\n", .{
                memory.physical.total_count - memory.physical.free_count, memory.physical.peak_used,
                memory.physical.allocations,                              memory.physical.frees,
                memory.physical.allocation_failures,                      memory.physical.region_count,
            });
            self.write("Heap integrity: OK\n");
        } else if (std.mem.eql(u8, command, "memtest")) {
            if (self.stress_handle != null) {
                self.write("Memory test already running. Use memstop to cancel.\n");
                return;
            }
            self.stress = memory.Stress.init(&memory.virtual) catch |err| {
                self.print("Memory test could not start: {s}\n", .{@errorName(err)});
                return;
            };
            self.stress_handle = self.executor.spawnNamed("memtest", self, stressPoll, stressCleanup) catch |err| {
                self.stress.deinit();
                self.print("Memory test could not start: {s}\n", .{@errorName(err)});
                return;
            };
            self.write("Memory test started: 2048 operations on an isolated 256 KiB heap.\n");
        } else if (std.mem.eql(u8, command, "memstop")) {
            const handle = self.stress_handle orelse {
                self.write("No memory test is running.\n");
                return;
            };
            self.executor.cancel(handle) catch |err| {
                self.print("Memory test cancellation failed: {s}\n", .{@errorName(err)});
                return;
            };
            self.write("Memory test cancelled; pages released.\n");
        } else if (std.mem.eql(u8, command, "tasks")) {
            var buffer: [task.capacity]task.Executor.TaskInfo = undefined;
            const live = self.executor.snapshot(&buffer);
            self.print("{} live task(s)\nID:GEN  STATE    NAME\n", .{live.len});
            for (live) |info| self.print("{}:{}  {s}  {s}\n", .{ info.slot, info.generation, @tagName(info.state), info.name });
        } else if (std.mem.eql(u8, command, "clear")) {
            self.output.clear(self.output.context);
        } else {
            self.print("Unknown command: {s}. Type 'help'.\n", .{command});
        }
    }

    pub fn poll(context: *anyopaque, waker: task.Waker) task.Poll {
        const self: *Shell = @ptrCast(@alignCast(context));
        self.start();
        const ch = keyboard.pollRead(waker) catch |err| {
            self.print("\nShell keyboard error: {s}\n", .{@errorName(err)});
            return .complete;
        } orelse return .pending;
        self.feed(ch);
        return .yield;
    }
    pub fn cleanup(context: *anyopaque, waker: task.Waker) void {
        const self: *Shell = @ptrCast(@alignCast(context));
        if (self.stress_handle) |handle| self.executor.cancel(handle) catch unreachable;
        keyboard.cancelRead(waker);
    }

    fn stressPoll(context: *anyopaque, _: task.Waker) task.Poll {
        const self: *Shell = @ptrCast(@alignCast(context));
        const done = self.stress.step() catch |err| {
            var text: [128]u8 = undefined;
            self.notify(std.fmt.bufPrint(&text, "Memory test FAILED: {s}", .{@errorName(err)}) catch "Memory test FAILED");
            return .complete;
        };
        if (!done) return .yield;
        self.notify("Memory test PASS: data, alignment, realloc, coalescing and OOM verified; releasing pages.");
        return .complete;
    }

    fn stressCleanup(context: *anyopaque, _: task.Waker) void {
        const self: *Shell = @ptrCast(@alignCast(context));
        self.stress.deinit();
        self.stress_handle = null;
    }
};
