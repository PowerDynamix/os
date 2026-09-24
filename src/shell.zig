//! Bounded, allocation-free shell. Single keyboard consumer, polled as a task.
const std = @import("std");
const task = @import("task.zig");
const keyboard = @import("keyboard.zig");
const memory = @import("memory.zig");
const log = @import("log.zig");
const console = @import("console.zig");

pub const line_capacity = 128;
pub const history_capacity = 16;
pub const job_capacity = 8;

/// Task-context output operations. redraw replaces the current prompt row;
/// null hides the prompt. Keep input on one row (scroll the view for long lines).
pub const Output = struct {
    context: *anyopaque,
    write: *const fn (*anyopaque, []const u8) void,
    clear: *const fn (*anyopaque) void,
    redraw: *const fn (*anyopaque, ?[]const u8, ?usize) void,

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
    fn redrawConsole(ctx: *anyopaque, input: ?[]const u8, cursor: ?usize) void {
        const value: *console.Console = @ptrCast(@alignCast(ctx));
        value.clearLine();
        const line = input orelse return;
        const columns = value.fb.width / value.font.width;
        if (columns < 8) return;
        value.putString("os> ");
        const available = columns - 7; // Two markers and a cursor cell.
        const position = @min(cursor orelse line.len, line.len);
        const start = position -| available;
        const end = @min(line.len, start + available);
        value.putChar(if (start > 0) '<' else ' ');
        value.putString(line[start..end]);
        if (end < line.len) value.putChar('>');
        value.cursor_x = @as(u32, @intCast(5 + position - start)) * value.font.width;
        if (cursor != null) value.drawCursor();
    }
};

pub const Shell = struct {
    const Job = struct {
        owner: *Shell = undefined,
        id: u64 = 0,
        handle: ?task.Waker = null,
        name: []const u8 = "",
        interval_ms: u64 = 1000,
        sleep: ?task.Sleep = null,
    };

    // Shell storage must remain stable while any of its jobs are active.
    jobs: [job_capacity]Job = @splat(.{}),
    next_job_id: u64 = 1,
    executor: *task.Executor,
    output: Output,
    buffer: [line_capacity]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,
    history: [history_capacity][line_capacity]u8 = undefined,
    history_lengths: [history_capacity]usize = @splat(0),
    history_count: usize = 0,
    history_next: usize = 0,
    history_offset: usize = 0,
    draft: [line_capacity]u8 = undefined,
    draft_len: usize = 0,
    draft_cursor: usize = 0,
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
        self.output.redraw(self.output.context, self.line(), self.cursor);
    }

    /// Background tasks route messages here to preserve partially typed commands.
    /// No yields/allocations: prompt removal, output and redraw are one task turn.
    pub fn notify(self: *Shell, text: []const u8) void {
        if (self.started) {
            self.output.redraw(self.output.context, null, null);
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

    fn resetLine(self: *Shell) void {
        self.len = 0;
        self.cursor = 0;
        self.history_offset = 0;
        self.full_reported = false;
    }

    fn remember(self: *Shell) void {
        if (std.mem.trim(u8, self.line(), " \t").len == 0) return;
        if (self.history_count > 0) {
            const last = (self.history_next + history_capacity - 1) % history_capacity;
            if (std.mem.eql(u8, self.line(), self.history[last][0..self.history_lengths[last]])) return;
        }
        @memcpy(self.history[self.history_next][0..self.len], self.line());
        self.history_lengths[self.history_next] = self.len;
        self.history_next = (self.history_next + 1) % history_capacity;
        self.history_count = @min(self.history_count + 1, history_capacity);
    }

    fn recall(self: *Shell, older: bool) void {
        if (older) {
            if (self.history_offset == self.history_count) return;
            if (self.history_offset == 0) {
                @memcpy(self.draft[0..self.len], self.line());
                self.draft_len = self.len;
                self.draft_cursor = self.cursor;
            }
            self.history_offset += 1;
        } else {
            if (self.history_offset == 0) return;
            self.history_offset -= 1;
        }
        if (self.history_offset == 0) {
            self.len = self.draft_len;
            @memcpy(self.buffer[0..self.len], self.draft[0..self.len]);
            self.cursor = self.draft_cursor;
        } else {
            const index = (self.history_next + history_capacity - self.history_offset) % history_capacity;
            self.len = self.history_lengths[index];
            @memcpy(self.buffer[0..self.len], self.history[index][0..self.len]);
            self.cursor = self.len;
        }
        self.full_reported = false;
    }

    fn erase(self: *Shell, begin: usize, end: usize) void {
        std.mem.copyForwards(u8, self.buffer[begin..], self.buffer[end..self.len]);
        self.len -= end - begin;
        self.cursor = begin;
        self.full_reported = false;
    }

    /// Complete the command token, or the command-name argument to help/watch.
    /// Replace the whole token at the cursor, leaving other arguments intact.
    fn complete(self: *Shell) void {
        var begin = self.cursor;
        while (begin > 0 and self.buffer[begin - 1] != ' ') begin -= 1;
        var end = self.cursor;
        while (end < self.len and self.buffer[end] != ' ') end += 1;
        var before = std.mem.tokenizeScalar(u8, self.buffer[0..begin], ' ');
        var watch_argument = false;
        if (before.next()) |first| {
            watch_argument = std.mem.eql(u8, first, "watch");
            if ((!std.mem.eql(u8, first, "help") and !watch_argument) or before.next() != null) return;
        }
        const prefix = self.buffer[begin..self.cursor];
        var matches: usize = 0;
        var common: []const u8 = "";
        for (commands) |command| {
            if (watch_argument and !std.mem.eql(u8, command.name, "mem")) continue;
            if (!std.mem.startsWith(u8, command.name, prefix)) continue;
            if (matches == 0) {
                common = command.name;
            } else {
                var len: usize = 0;
                while (len < common.len and len < command.name.len and common[len] == command.name[len]) len += 1;
                common = common[0..len];
            }
            matches += 1;
        }
        if (matches == 0) return;
        if (matches > 1) {
            self.output.redraw(self.output.context, null, null);
            for (commands) |command| {
                if (std.mem.startsWith(u8, command.name, prefix)) self.print("{s}  ", .{command.name});
            }
            self.write("\n");
        }
        // Ambiguous completion may extend a prefix but must not erase its suffix.
        if (matches > 1 and (common.len <= prefix.len or self.cursor != end)) return;
        const space: usize = if (matches == 1 and end == self.len) 1 else 0;
        const replacement_len = common.len + space;
        const new_len = self.len - (end - begin) + replacement_len;
        if (new_len > self.buffer.len) {
            self.notify("Completion exceeds line capacity (128 characters).");
            return;
        }
        const tail = self.buffer[end..self.len];
        const destination = self.buffer[begin + replacement_len .. new_len];
        if (begin + replacement_len > end) std.mem.copyBackwards(u8, destination, tail) else std.mem.copyForwards(u8, destination, tail);
        @memcpy(self.buffer[begin..][0..common.len], common);
        if (space == 1) self.buffer[begin + common.len] = ' ';
        self.len = new_len;
        self.cursor = begin + replacement_len;
        if (matches == 1 and space == 0 and self.cursor < self.len) self.cursor += 1;
        self.full_reported = false;
    }

    /// ASCII input and keyboard.Key navigation tokens, all bounded and allocation-free.
    pub fn feed(self: *Shell, ch: u8) void {
        self.start();
        switch (ch) {
            '\t' => self.complete(),
            '\n', '\r' => {
                // Remove the visible cursor before committing this prompt row.
                self.output.redraw(self.output.context, self.line(), null);
                self.write("\n");
                self.remember();
                self.execute(self.line());
                self.resetLine();
            },
            keyboard.Key.left => self.cursor -|= 1,
            keyboard.Key.right => self.cursor = @min(self.cursor + 1, self.len),
            keyboard.Key.home => self.cursor = 0,
            keyboard.Key.end => self.cursor = self.len,
            keyboard.Key.up => self.recall(true),
            keyboard.Key.down => self.recall(false),
            keyboard.Key.delete => {
                if (self.cursor < self.len) self.erase(self.cursor, self.cursor + 1);
            },
            8, 127 => {
                if (self.cursor > 0) self.erase(self.cursor - 1, self.cursor);
            },
            21 => self.resetLine(), // Ctrl-U
            23 => { // Ctrl-W: erase the word before the cursor, preserving the suffix.
                var begin = self.cursor;
                while (begin > 0 and self.buffer[begin - 1] == ' ') begin -= 1;
                while (begin > 0 and self.buffer[begin - 1] != ' ') begin -= 1;
                self.erase(begin, self.cursor);
            },
            3 => {
                self.output.redraw(self.output.context, self.line(), null);
                self.write("^C\n");
                self.resetLine();
            },
            else => {
                const printable = ch;
                if (printable < 32 or printable > 126) return;
                if (self.len == self.buffer.len) {
                    if (!self.full_reported) self.notify("Line full (128 characters). Use Backspace or Ctrl-U.");
                    self.full_reported = true;
                    return;
                }
                std.mem.copyBackwards(u8, self.buffer[self.cursor + 1 .. self.len + 1], self.buffer[self.cursor..self.len]);
                self.buffer[self.cursor] = printable;
                self.len += 1;
                self.cursor += 1;
            },
        }
        self.redraw();
    }

    const Command = struct {
        name: []const u8,
        description: []const u8,
        usage: []const u8,
        min_args: usize = 0,
        max_args: usize = 0,
        handler: *const fn (*Shell, []const []const u8) void,
    };
    const commands = [_]Command{
        .{ .name = "help", .description = "show commands or detailed command help", .usage = "help [command]", .max_args = 1, .handler = commandHelp },
        .{ .name = "dmesg", .description = "show retained kernel log messages", .usage = "dmesg", .handler = commandDmesg },
        .{ .name = "mem", .description = "show memory diagnostics", .usage = "mem", .handler = commandMem },
        .{ .name = "memtest", .description = "start allocator stress test (default 2048 operations; range 1..1000000)", .usage = "memtest [operations]", .max_args = 1, .handler = commandMemtest },
        .{ .name = "memstop", .description = "cancel allocator stress test", .usage = "memstop", .handler = commandMemstop },
        .{ .name = "jobs", .description = "list active shell jobs and their states", .usage = "jobs", .handler = commandJobs },
        .{ .name = "kill", .description = "cancel a shell job by its job ID", .usage = "kill <id>", .min_args = 1, .max_args = 1, .handler = commandKill },
        .{ .name = "watch", .description = "repeat memory diagnostics (default 1000 ms; range 10..3600000 ms)", .usage = "watch mem [milliseconds]", .min_args = 1, .max_args = 2, .handler = commandWatch },
        .{ .name = "tasks", .description = "list live tasks and their states", .usage = "tasks", .handler = commandTasks },
        .{ .name = "clear", .description = "clear the screen", .usage = "clear", .handler = commandClear },
    };

    fn findCommand(name: []const u8) ?*const Command {
        for (&commands) |*command| if (std.mem.eql(u8, command.name, name)) return command;
        return null;
    }

    fn execute(self: *Shell, input: []const u8) void {
        var words = std.mem.tokenizeAny(u8, input, " \t");
        const name = words.next() orelse return;
        const command = findCommand(name) orelse {
            self.print("Unknown command: {s}. Type 'help'.\n", .{name});
            return;
        };
        var args: [8][]const u8 = undefined;
        var count: usize = 0;
        while (words.next()) |word| {
            if (count == args.len or count == command.max_args) {
                self.print("Usage: {s}\n", .{command.usage});
                return;
            }
            args[count] = word;
            count += 1;
        }
        if (count < command.min_args) {
            self.print("Usage: {s}\n", .{command.usage});
            return;
        }
        command.handler(self, args[0..count]);
    }

    fn commandHelp(self: *Shell, args: []const []const u8) void {
        if (args.len == 1) {
            const command = findCommand(args[0]) orelse {
                self.print("Unknown command: {s}. Type 'help'.\n", .{args[0]});
                return;
            };
            self.print("Usage: {s}\n{s}\n", .{ command.usage, command.description });
            return;
        }
        for (commands) |command| self.print("{s} - {s}\n", .{ command.usage, command.description });
        self.write("Tab: complete commands; Arrows: move/history; Home/End: line ends; Delete: erase ahead.\nBackspace: erase; Ctrl-U: clear line; Ctrl-W: erase word; Ctrl-C: cancel.\n");
    }

    fn commandDmesg(self: *Shell, _: []const []const u8) void {
        var snapshot: log.Snapshot = undefined;
        log.snapshot(&snapshot);
        if (snapshot.overwritten > 0) self.print("[{} older log messages overwritten]\n", .{snapshot.overwritten});
        if (snapshot.count == 0) self.write("Kernel log is empty.\n");
        for (snapshot.records[0..snapshot.count]) |*record| {
            if (record.timestamp_ms) |ms| self.print("[{} ms] ", .{ms}) else self.write("[boot] ");
            self.print("{s}: {s}{s}\n", .{ @tagName(record.level), record.text(), if (record.truncated) " [truncated]" else "" });
        }
    }

    fn commandMem(self: *Shell, _: []const []const u8) void {
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
    }

    fn commandMemtest(self: *Shell, args: []const []const u8) void {
        var rounds: usize = memory.Stress.rounds;
        if (args.len == 1) {
            for (args[0]) |ch| if (ch < '0' or ch > '9') {
                self.write("Operations must be a decimal integer from 1 to 1000000.\n");
                return;
            };
            rounds = std.fmt.parseInt(usize, args[0], 10) catch 0;
            if (rounds == 0 or rounds > 1_000_000) {
                self.write("Operations must be a decimal integer from 1 to 1000000.\n");
                return;
            }
        }
        if (self.stress_handle != null) {
            self.write("Memory test already running. Use memstop to cancel.\n");
            return;
        }
        const job = self.availableJob() orelse return;
        self.stress = memory.Stress.init(&memory.virtual) catch |err| {
            self.print("Memory test could not start: {s}\n", .{@errorName(err)});
            return;
        };
        self.stress.target_rounds = rounds;
        self.stress_handle = self.executor.spawnNamed("memtest", self, stressPoll, stressCleanup) catch |err| {
            self.stress.deinit();
            self.print("Memory test could not start: {s}\n", .{@errorName(err)});
            return;
        };
        self.registerJob(job, self.stress_handle.?, "memtest");
        self.print("Job {} started: memtest\n", .{job.id});
        self.print("Memory test started: {} operations on an isolated 256 KiB heap.\n", .{rounds});
    }

    fn commandMemstop(self: *Shell, _: []const []const u8) void {
        const handle = self.stress_handle orelse {
            self.write("No memory test is running.\n");
            return;
        };
        self.executor.cancel(handle) catch |err| {
            self.print("Memory test cancellation failed: {s}\n", .{@errorName(err)});
            return;
        };
        log.write(.info, "Memory test cancelled");
        self.write("Memory test cancelled; pages released.\n");
    }

    fn availableJob(self: *Shell) ?*Job {
        if (self.next_job_id == std.math.maxInt(u64)) {
            self.write("Job IDs exhausted.\n");
            return null;
        }
        for (&self.jobs) |*job| if (job.handle == null) return job;
        self.write("Job capacity reached (8). Use jobs and kill to free a slot.\n");
        return null;
    }

    fn registerJob(self: *Shell, job: *Job, handle: task.Waker, name: []const u8) void {
        job.* = .{ .owner = self, .id = self.next_job_id, .handle = handle, .name = name };
        log.print(.info, "Job {} started: {s}", .{ job.id, name });
        self.next_job_id += 1;
    }

    fn commandJobs(self: *Shell, _: []const []const u8) void {
        var infos: [task.capacity]task.Executor.TaskInfo = undefined;
        const snapshot = self.executor.snapshot(&infos);
        self.write("JOB  STATE    COMMAND\n");
        var count: usize = 0;
        for (self.jobs) |job| {
            const handle = job.handle orelse continue;
            for (snapshot) |info| {
                if (info.slot != handle.slot or info.generation != handle.generation) continue;
                self.print("{}  {s}  {s}", .{ job.id, @tagName(info.state), job.name });
                if (std.mem.eql(u8, job.name, "watch mem")) self.print(" ({} ms)", .{job.interval_ms});
                self.write("\n");
                count += 1;
                break;
            }
        }
        if (count == 0) self.write("No active jobs.\n");
    }

    fn decimal(text: []const u8) ?u64 {
        if (text.len == 0) return null;
        for (text) |ch| if (ch < '0' or ch > '9') return null;
        return std.fmt.parseInt(u64, text, 10) catch null;
    }

    fn commandKill(self: *Shell, args: []const []const u8) void {
        const id = decimal(args[0]) orelse {
            self.write("Job ID must be a positive decimal integer.\n");
            return;
        };
        for (&self.jobs) |*job| {
            const handle = job.handle orelse continue;
            if (job.id != id) continue;
            self.executor.cancel(handle) catch |err| {
                self.print("Job cancellation failed: {s}\n", .{@errorName(err)});
                return;
            };
            log.print(.info, "Job {} cancelled", .{id});
            self.print("Job {} cancelled.\n", .{id});
            return;
        }
        self.print("No active job with ID {}.\n", .{id});
    }

    fn commandWatch(self: *Shell, args: []const []const u8) void {
        if (!std.mem.eql(u8, args[0], "mem")) {
            self.write("Usage: watch mem [milliseconds]\n");
            return;
        }
        const interval = if (args.len == 2) decimal(args[1]) orelse 0 else 1000;
        if (interval < 10 or interval > 3_600_000) {
            self.write("Interval must be a decimal integer from 10 to 3600000 ms.\n");
            return;
        }
        const job = self.availableJob() orelse return;
        const handle = self.executor.spawnNamed("watch mem", job, watchPoll, watchCleanup) catch |err| {
            self.print("Watch could not start: {s}\n", .{@errorName(err)});
            return;
        };
        self.registerJob(job, handle, "watch mem");
        job.interval_ms = interval;
        self.print("Job {} started: watch mem ({} ms). Use kill {} to stop.\n", .{ job.id, interval, job.id });
    }

    fn watchPoll(context: *anyopaque, waker: task.Waker) task.Poll {
        const job: *Job = @ptrCast(@alignCast(context));
        const self = job.owner;
        if (job.sleep) |sleep| {
            if (!(sleep.poll(waker) catch |err| {
                self.watchError(job.id, err);
                return .complete;
            })) return .pending;
        }
        // Render a whole diagnostic block in one cooperative turn, preserving input.
        if (self.started) self.output.redraw(self.output.context, null, null);
        self.print("[Job {}: watch mem]\n", .{job.id});
        self.commandMem(&.{});
        if (self.started) self.redraw();
        job.sleep = task.sleep(job.interval_ms) catch |err| {
            self.watchError(job.id, err);
            return .complete;
        };
        const ready = job.sleep.?.poll(waker) catch |err| {
            self.watchError(job.id, err);
            return .complete;
        };
        return if (ready) .yield else .pending;
    }

    fn watchError(self: *Shell, id: u64, err: anyerror) void {
        log.print(.err, "Job {} stopped: {s}", .{ id, @errorName(err) });
        var buffer: [128]u8 = undefined;
        self.notify(std.fmt.bufPrint(&buffer, "Job {} stopped: {s}", .{ id, @errorName(err) }) catch "Watch failed");
    }

    fn watchCleanup(context: *anyopaque, _: task.Waker) void {
        const job: *Job = @ptrCast(@alignCast(context));
        // Executor teardown has already detached the timer registration.
        job.handle = null;
        job.sleep = null;
    }

    fn commandTasks(self: *Shell, _: []const []const u8) void {
        var buffer: [task.capacity]task.Executor.TaskInfo = undefined;
        const live = self.executor.snapshot(&buffer);
        self.print("{} live task(s)\nID:GEN  STATE    NAME\n", .{live.len});
        for (live) |info| self.print("{}:{}  {s}  {s}\n", .{ info.slot, info.generation, @tagName(info.state), info.name });
    }

    fn commandClear(self: *Shell, _: []const []const u8) void {
        self.output.clear(self.output.context);
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
        for (&self.jobs) |*job| {
            if (job.handle) |handle| self.executor.cancel(handle) catch unreachable;
        }
        keyboard.cancelRead(waker);
    }

    fn stressPoll(context: *anyopaque, _: task.Waker) task.Poll {
        const self: *Shell = @ptrCast(@alignCast(context));
        const done = self.stress.step() catch |err| {
            log.print(.err, "Memory test FAILED: {s}", .{@errorName(err)});
            var text: [128]u8 = undefined;
            self.notify(std.fmt.bufPrint(&text, "Memory test FAILED: {s}", .{@errorName(err)}) catch "Memory test FAILED");
            return .complete;
        };
        if (!done) return .yield;
        log.write(.info, "Memory test passed");
        self.notify("Memory test PASS: data, alignment, realloc, coalescing and OOM verified; releasing pages.");
        return .complete;
    }

    fn stressCleanup(context: *anyopaque, waker: task.Waker) void {
        const self: *Shell = @ptrCast(@alignCast(context));
        self.stress.deinit();
        self.stress_handle = null;
        for (&self.jobs) |*job| {
            if (job.handle) |handle| if (handle.eql(waker)) {
                job.handle = null;
                break;
            };
        }
    }
};
