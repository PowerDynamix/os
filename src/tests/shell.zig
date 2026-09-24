const std = @import("std");
const uefi = std.os.uefi;
const kernel = @import("os_kernel");
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

const Capture = struct {
    bytes: [16384]u8 = undefined,
    len: usize = 0,
    input: [128]u8 = undefined,
    input_len: usize = 0,
    clears: usize = 0,
    fn output(self: *Capture) kernel.shell.Output {
        return .{ .context = self, .write = write, .redraw = redraw, .clear = clear };
    }
    fn write(ctx: *anyopaque, text: []const u8) void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        check(text.len <= self.bytes.len - self.len, "Capture overflow\n");
        @memcpy(self.bytes[self.len..][0..text.len], text);
        self.len += text.len;
    }
    fn redraw(ctx: *anyopaque, input: ?[]const u8, _: ?usize) void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        const text = input orelse "";
        @memcpy(self.input[0..text.len], text);
        self.input_len = text.len;
    }
    fn clear(ctx: *anyopaque) void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        self.clears += 1;
    }
    fn contains(self: *Capture, text: []const u8) bool {
        return std.mem.indexOf(u8, self.bytes[0..self.len], text) != null;
    }
};
fn feed(shell: *kernel.shell.Shell, text: []const u8) void {
    for (text) |ch| shell.feed(ch);
}
fn parked(_: *anyopaque, _: kernel.task.Waker) kernel.task.Poll {
    return .pending;
}

fn editingTests(shell: *kernel.shell.Shell, capture: *Capture) void {
    feed(shell, "\x08\x08helx\x08p\n");
    check(capture.contains("mem -") and shell.len == 0, "Help/backspace\n");
    feed(shell, "first second   \x17");
    check(std.mem.eql(u8, shell.line(), "first "), "Word erase\n");
    feed(shell, "\x15");
    check(shell.len == 0, "Line erase\n");
    feed(shell, "clear\x03");
    check(capture.clears == 0 and shell.len == 0, "Ctrl-C executed command\n");
    feed(shell, "    \n");
    check(!capture.contains("Unknown command"), "Empty input executed\n");
    feed(shell, "clear extra\n");
    check(capture.contains("Usage: clear") and capture.clears == 0, "Argument validation\n");
    feed(shell, "nonsense\n");
    check(capture.contains("Unknown command: nonsense"), "Unknown command\n");
    feed(shell, "  clear  \n");
    check(capture.clears == 1, "Trimmed clear\n");
    for (0..kernel.shell.line_capacity + 20) |_| shell.feed('x');
    check(shell.len == kernel.shell.line_capacity and capture.contains("Line full"), "Line overflow\n");
    shell.feed(8);
    shell.feed('y');
    check(shell.len == kernel.shell.line_capacity and shell.buffer[shell.len - 1] == 'y', "Full line recovery\n");
    feed(shell, "\x15he");
    shell.notify("background message");
    check(std.mem.eql(u8, shell.line(), "he") and std.mem.eql(u8, capture.input[0..capture.input_len], "he"), "Background output lost input\n");
    feed(shell, "lp\nmem\n");
    check(capture.contains("Managed RAM:") and capture.contains("allocations: 0"), "Memory statistics\n");
    const allocation = kernel.memory.allocator().alloc(u8, 123) catch |err| failed(err);
    feed(shell, "mem\n");
    check(capture.contains("allocations: 1"), "Memory statistics are not live\n");
    kernel.memory.allocator().free(allocation);
    serial.writeString("Shell editing, commands, bounds, notifications and memory statistics passed\n");
}

fn navigationTests() void {
    const key = kernel.keyboard.Key;
    var executor: kernel.task.Executor = .{};
    var capture: Capture = .{};
    var shell = kernel.shell.Shell.init(&executor, capture.output());
    shell.feed(key.up);
    shell.feed(key.left);
    check(shell.cursor == 0 and shell.len == 0, "Empty navigation\n");
    feed(&shell, "ac");
    shell.feed(key.left);
    shell.feed('b');
    check(std.mem.eql(u8, shell.line(), "abc") and shell.cursor == 2, "Middle insertion\n");
    shell.feed(8);
    shell.feed(key.delete);
    check(std.mem.eql(u8, shell.line(), "a"), "Middle deletion\n");
    shell.feed(key.home);
    shell.feed(8);
    shell.feed('x');
    shell.feed(key.end);
    shell.feed(key.right);
    shell.feed(key.delete);
    check(std.mem.eql(u8, shell.line(), "xa") and shell.cursor == 2, "Navigation bounds\n");
    feed(&shell, "\x15one two tail");
    for (0..4) |_| shell.feed(key.left);
    shell.feed(23);
    check(std.mem.eql(u8, shell.line(), "one tail") and shell.cursor == 4, "Word erase suffix\n");
    feed(&shell, "\x15help\nclear\nclear\n  \n");
    check(shell.history_count == 2, "History blank/duplicate filtering\n");
    feed(&shell, "draft");
    shell.feed(key.left);
    shell.feed(key.up);
    check(std.mem.eql(u8, shell.line(), "clear"), "Newest history\n");
    shell.feed(key.up);
    shell.feed(key.up);
    check(std.mem.eql(u8, shell.line(), "help"), "Oldest history bound\n");
    shell.feed('x');
    shell.feed(key.down);
    shell.feed(key.up);
    check(std.mem.eql(u8, shell.line(), "help"), "History edit mutated stored command\n");
    shell.feed(key.down);
    shell.feed(key.down);
    check(std.mem.eql(u8, shell.line(), "draft") and shell.cursor == 4, "Draft restoration\n");
    shell.notify("background");
    check(shell.cursor == 4, "Notification moved cursor\n");
    shell.feed(3);
    for (0..kernel.shell.history_capacity + 2) |i| {
        shell.feed(@as(u8, @intCast('a' + i)));
        shell.feed('\n');
    }
    for (0..kernel.shell.history_capacity + 2) |_| shell.feed(key.up);
    check(std.mem.eql(u8, shell.line(), "c"), "History ring eviction\n");
    shell.feed(21);
    for (0..kernel.shell.line_capacity) |_| shell.feed('x');
    shell.feed(key.home);
    shell.feed('y');
    check(shell.len == kernel.shell.line_capacity and shell.cursor == 0, "Full middle insert\n");
    shell.feed(key.delete);
    shell.feed('y');
    check(shell.len == kernel.shell.line_capacity and shell.buffer[0] == 'y', "Full middle recovery\n");
    serial.writeString("Cursor editing and history passed\n");
}

fn completionTests() void {
    var executor: kernel.task.Executor = .{};
    var capture: Capture = .{};
    var shell = kernel.shell.Shell.init(&executor, capture.output());
    feed(&shell, "he\t");
    check(std.mem.eql(u8, shell.line(), "help "), "Unique completion\n");
    feed(&shell, "memt\t\n");
    check(capture.contains("Usage: memtest [operations]") and shell.stress_handle == null, "Help argument completion\n");
    feed(&shell, "m\t");
    check(std.mem.eql(u8, shell.line(), "mem") and capture.contains("memstop"), "Common prefix completion\n");
    shell.feed('\t');
    check(std.mem.eql(u8, shell.line(), "mem"), "Ambiguous exact prefix\n");
    feed(&shell, "\x15unknown\t");
    check(std.mem.eql(u8, shell.line(), "unknown"), "No-match completion\n");
    feed(&shell, "\x15helx mem");
    shell.feed(kernel.keyboard.Key.home);
    for (0..3) |_| shell.feed(kernel.keyboard.Key.right);
    shell.feed('\t');
    check(std.mem.eql(u8, shell.line(), "help mem") and shell.cursor == 5, "Mid-token completion suffix\n");
    feed(&shell, "\x15memtest 12\t");
    check(std.mem.eql(u8, shell.line(), "memtest 12"), "Numeric argument completion\n");
    feed(&shell, "\x15");
    shell.feed('\t');
    check(shell.len == 0 and shell.cursor == 0, "Empty completion executed\n");
    for (0..125) |_| shell.feed(' ');
    feed(&shell, "he\t");
    check(shell.len == 127 and capture.contains("exceeds line capacity"), "Completion overflow\n");
    feed(&shell, "\x15help missing\nhelp mem extra\n");
    check(capture.contains("Unknown command: missing") and capture.contains("Usage: help [command]"), "Help argument errors\n");
    const frames = kernel.memory.physical.free_count;
    feed(&shell, "memtest 0\nmemtest -1\nmemtest abc\nmemtest 1000001\nmemtest 99999999999999999999999999999\nmemtest 1 2\n");
    check(shell.stress_handle == null and kernel.memory.physical.free_count == frames and capture.contains("Operations must be") and capture.contains("Usage: memtest [operations]"), "Invalid stress arguments allocated\n");
    feed(&shell, "  memtest   7  \n");
    check(shell.stress_handle != null and shell.stress.target_rounds == 7, "Custom stress count\n");
    var polls: usize = 0;
    while (executor.step()) : (polls += 1) check(polls < 50, "Custom stress count ignored\n");
    check(shell.stress_handle == null and capture.contains("Memory test PASS") and kernel.memory.physical.free_count == frames, "Custom stress completion cleanup\n");
    feed(&shell, "memtest 1000000\nmemstop\n");
    check(shell.stress_handle == null and kernel.memory.physical.free_count == frames, "Custom stress cancellation\n");
    serial.writeString("Command registry, arguments and completion passed\n");
}

fn jobTests() void {
    var executor: kernel.task.Executor = .{};
    var capture: Capture = .{};
    var shell = kernel.shell.Shell.init(&executor, capture.output());
    const frames = kernel.memory.physical.free_count;
    feed(&shell, "jobs\nkill\nkill nope\nkill 999\nwatch\nwatch clear\nwatch mem 0\nwatch mem -1\nwatch mem 3600001\nwatch mem 9999999999999999999999999\n");
    check(executor.activeCount() == 0 and capture.contains("No active jobs") and capture.contains("Usage: kill <id>") and capture.contains("Interval must be"), "Job argument validation\n");
    feed(&shell, "watch m\t");
    check(std.mem.eql(u8, shell.line(), "watch mem "), "Watch completion\n");
    feed(&shell, "10\njobs\n");
    check(capture.contains("1  ready  watch mem"), "Ready job listing\n");
    feed(&shell, "draft");
    shell.feed(kernel.keyboard.Key.left);
    check(executor.step() and !executor.step(), "Watch did not suspend\n");
    check(kernel.timer.pendingCount() == 1 and std.mem.eql(u8, shell.line(), "draft") and shell.cursor == 4, "Watch damaged input or missed timer\n");
    capture.len = 0;
    const deadline = kernel.timer.now() + 200;
    while (!capture.contains("[Job 1: watch mem]") and kernel.timer.now() < deadline) {
        irq.wait_for_interrupt();
        irq.disable();
        _ = executor.step();
    }
    check(capture.contains("[Job 1: watch mem]"), "Watch did not repeat on timer\n");
    feed(&shell, "\x15jobs\nkill 1\n");
    check(capture.contains("1  waiting  watch mem") and executor.activeCount() == 0 and kernel.timer.pendingCount() == 0, "Kill failed to detach sleep\n");
    feed(&shell, "watch mem\nkill 1\n");
    check(executor.activeCount() == 1 and capture.contains("No active job with ID 1"), "Stale ID cancelled reused slot\n");
    feed(&shell, "kill 2\nmemtest 100\njobs\n");
    check(capture.contains("3  ready  memtest"), "Stress missing from jobs\n");
    for (0..5) |_| _ = executor.step();
    feed(&shell, "kill 3\n");
    check(shell.stress_handle == null and kernel.memory.physical.free_count == frames, "Kill stress leaked pages\n");
    feed(&shell, "memtest 1\n");
    while (executor.step()) {}
    capture.len = 0;
    feed(&shell, "jobs\n");
    check(capture.contains("No active jobs"), "Completed job retained\n");
    for (0..kernel.shell.job_capacity) |_| feed(&shell, "watch mem\n");
    feed(&shell, "watch mem\nmemtest\n");
    check(executor.activeCount() == kernel.shell.job_capacity and capture.contains("Job capacity reached") and kernel.memory.physical.free_count == frames, "Job capacity rollback\n");
    // Shell teardown owns all jobs, including timer subscriptions.
    while (executor.step()) {}
    check(kernel.timer.pendingCount() == kernel.shell.job_capacity, "Concurrent watch sleeps\n");
    const handle = executor.spawnNamed("shell", &shell, kernel.shell.Shell.poll, kernel.shell.Shell.cleanup) catch |err| failed(err);
    executor.cancel(handle) catch |err| failed(err);
    check(executor.activeCount() == 0 and kernel.timer.pendingCount() == 0, "Shell teardown leaked watches\n");
    var dummy: u8 = 0;
    var handles: [kernel.task.capacity]kernel.task.Waker = undefined;
    for (&handles) |*entry| entry.* = executor.spawn(&dummy, parked, null) catch |err| failed(err);
    feed(&shell, "watch mem\n");
    check(capture.contains("Watch could not start: TaskCapacityExceeded"), "Watch spawn failure\n");
    for (handles) |entry| executor.cancel(entry) catch |err| failed(err);
    capture.len = 0;
    feed(&shell, "jobs\n");
    check(capture.contains("No active jobs"), "Failed watch left job entry\n");
    serial.writeString("Jobs, stale IDs, timed watches, cancellation and teardown passed\n");
}

var logged_irq = false;
fn logFromIrq(_: *anyopaque) void {
    kernel.log.write(.warn, "timer IRQ log");
    logged_irq = true;
}

fn earlyLogTests() void {
    var executor: kernel.task.Executor = .{};
    var capture: Capture = .{};
    var shell = kernel.shell.Shell.init(&executor, capture.output());
    feed(&shell, "dmesg\n");
    check(capture.contains("Kernel log is empty"), "Empty dmesg\n");
    kernel.log.write(.info, "early boot");
    var snapshot: kernel.log.Snapshot = undefined;
    kernel.log.snapshot(&snapshot);
    check(snapshot.count == 1 and snapshot.records[0].timestamp_ms == null and !irq.enabled(), "Early boot logging\n");
}

fn logTests() void {
    var snapshot: kernel.log.Snapshot = undefined;
    kernel.log.write(.debug, "multiline\nmessage\tend\n");
    var long: [kernel.log.message_capacity + 10]u8 = @splat('x');
    kernel.log.write(.warn, &long);
    kernel.log.print(.err, "formatted {s}", .{&long});
    irq.enable();
    kernel.log.print(.info, "value {}", .{@as(u32, 42)});
    kernel.log.snapshot(&snapshot);
    check(irq.enabled(), "Logging changed IF\n");
    irq.disable();
    check(snapshot.count == 5 and snapshot.records[1].timestamp_ms != null and std.mem.eql(u8, snapshot.records[1].text(), "multiline message end"), "Log formatting/time\n");
    check(snapshot.records[2].truncated and snapshot.records[3].truncated and snapshot.records[2].len == kernel.log.message_capacity, "Log truncation\n");
    check(std.mem.eql(u8, snapshot.records[4].text(), "value 42"), "Formatted log\n");
    var dummy: u8 = 0;
    const deadline = kernel.timer.deadlineAfter(10) catch |err| failed(err);
    _ = kernel.timer.waitUntil(deadline, &dummy, logFromIrq) catch |err| failed(err);
    while (!logged_irq) {
        irq.wait_for_interrupt();
        irq.disable();
    }
    check(snapshot.count == 5, "Snapshot mutated after write\n");
    var executor: kernel.task.Executor = .{};
    var capture: Capture = .{};
    var shell = kernel.shell.Shell.init(&executor, capture.output());
    feed(&shell, "dme\t\n");
    check(capture.contains("[boot] info: early boot") and capture.contains("warn: timer IRQ log") and capture.contains("[truncated]"), "Dmesg rendering/completion\n");
    kernel.log.snapshot(&snapshot);
    const before = snapshot.count;
    capture.len = 0;
    feed(&shell, "dmesg\n");
    kernel.log.snapshot(&snapshot);
    check(snapshot.count == before and snapshot.overwritten == 0, "Dmesg modified log\n");
    for (0..kernel.log.capacity + 3) |n| kernel.log.print(.info, "entry {}", .{n});
    kernel.log.snapshot(&snapshot);
    check(snapshot.count == kernel.log.capacity and snapshot.overwritten == before + 3 and std.mem.eql(u8, snapshot.records[0].text(), "entry 3") and std.mem.eql(u8, snapshot.records[kernel.log.capacity - 1].text(), "entry 66"), "Log ring ordering/eviction\n");
    capture.len = 0;
    feed(&shell, "dmesg\n");
    check(capture.contains("older log messages overwritten") and capture.contains("info: entry 66"), "Dmesg overwrite notice\n");
    serial.writeString("Kernel logging, early boot, IRQ writes, snapshots, truncation and dmesg passed\n");
}

fn framebufferTests() void {
    var pixels: [16 * 8]u32 = @splat(0);
    var glyphs: [256]u8 = @splat(0xff);
    var fb: kernel.framebuffer.Framebuffer = .{ .base = &pixels, .width = 16, .height = 8, .stride = 16 };
    var console = kernel.console.Console.init(&fb, .{ .width = 1, .height = 1, .char_size = 1, .header_size = 0, .glyphs = &glyphs });
    const output = kernel.shell.Output.framebuffer(&console);
    console.cursor_y = 3;
    pixels[0] = 0x1234;
    output.redraw(output.context, "abcdefghijklmnopqrstuvwxyz", 26);
    check(console.cursor_y == 3 and console.cursor_x < fb.width and pixels[0] == 0x1234, "Long line wrapped/damaged output\n");
    output.redraw(output.context, "abcdefghijklmnopqrstuvwxyz", 0);
    check(console.cursor_x == 5 and console.cursor_y == 3, "Home viewport\n");
    output.redraw(output.context, "abcdefghijklmnopqrstuvwxyz", 12);
    check(console.cursor_x < fb.width and console.cursor_y == 3, "Middle viewport\n");
    output.redraw(output.context, "a", 1);
    check(console.cursor_x == 6 and pixels[3 * 16 + 10] == 0, "Short line left stale glyphs\n");
    output.redraw(output.context, null, null);
    check(console.cursor_x == 0 and pixels[3 * 16] == 0, "Prompt hide left glyphs\n");
    output.clear(output.context);
    check(console.cursor_x == 0 and console.cursor_y == 0, "Clear did not reset cursor\n");
    for (pixels) |pixel| check(pixel == 0, "Clear left pixels\n");
    serial.writeString("Prompt viewport, row clearing and cursor reset passed\n");
}

fn readyController() void {
    for (0..100_000) |_| {
        if (kernel.io.inb(0x64) & 2 == 0) return;
        kernel.io.pause();
    }
    failed(error.ControllerTimeout);
}
fn inject(byte: u8) void {
    irq.disable();
    const before = @atomicLoad(u32, &kernel.keyboard.interrupt_count, .monotonic);
    readyController();
    kernel.io.outb(0x64, 0xd2);
    readyController();
    kernel.io.outb(0x60, byte);
    while (@atomicLoad(u32, &kernel.keyboard.interrupt_count, .monotonic) == before) {
        irq.wait_for_interrupt();
        irq.disable();
    }
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
    earlyLogTests();
    kernel.memory.init(map) catch |err| failed(err);
    kernel.apic.init(topology) catch |err| failed(err);
    kernel.keyboard.init() catch |err| failed(err);
    kernel.timer.init() catch |err| failed(err);
    logTests();
    framebufferTests();
    navigationTests();
    completionTests();
    jobTests();
    var executor: kernel.task.Executor = .{};
    var capture: Capture = .{};
    var shell = kernel.shell.Shell.init(&executor, capture.output());
    editingTests(&shell, &capture);
    var dummy: u8 = 0;
    const worker = executor.spawnNamed("worker", &dummy, parked, null) catch |err| failed(err);
    _ = executor.step();
    const handle = executor.spawnNamed("shell", &shell, kernel.shell.Shell.poll, kernel.shell.Shell.cleanup) catch |err| failed(err);
    var infos: [kernel.task.capacity]kernel.task.Executor.TaskInfo = undefined;
    const snapshot = executor.snapshot(&infos);
    check(snapshot.len == 2 and snapshot[0].state == .waiting and snapshot[1].state == .ready, "Task state snapshot\n");
    _ = executor.step();
    check(!executor.step(), "Shell busy-polled\n");
    // Type tasks through the actual PS/2 IRQ path.
    for ([_]u8{ 0x14, 0x1e, 0x1f, 0x25, 0x1f, 0x1c }) |scan| {
        inject(scan);
        while (executor.step()) {}
    }
    check(capture.contains("2 live task(s)") and capture.contains("waiting  worker") and capture.contains("running  shell"), "IRQ shell tasks command\n");
    // Recall tasks through real extended make/break IRQs, then execute it.
    for ([_]u8{ 0xe0, 0x48, 0xe0, 0xc8 }) |scan| {
        inject(scan);
        while (executor.step()) {}
    }
    check(std.mem.eql(u8, shell.line(), "tasks"), "IRQ history recall\n");
    inject(0x1c);
    while (executor.step()) {}
    // Type "he<Tab>mem<Enter>" through IRQ1 to exercise completion and arguments.
    for ([_]u8{ 0x23, 0x12, 0x0f, 0x32, 0x12, 0x32, 0x1c }) |scan| {
        inject(scan);
        while (executor.step()) {}
    }
    check(capture.contains("Usage: mem\n"), "IRQ Tab completion and help argument\n");
    executor.cancel(worker) catch |err| failed(err);
    check(executor.snapshot(&infos).len == 1, "Completed task still listed\n");
    const frames_before = kernel.memory.physical.free_count;
    feed(&shell, "memtest\nmemtest\n");
    check(shell.stress_handle != null and capture.contains("already running"), "Stress duplicate start\n");
    // Advance partway, then cancel while allocations are live.
    for (0..20) |_| _ = executor.step();
    feed(&shell, "memstop\n");
    check(shell.stress_handle == null and kernel.memory.physical.free_count == frames_before, "Stress command cancellation\n");
    feed(&shell, "memtest\n");
    while (executor.step()) {}
    check(shell.stress_handle == null and capture.contains("Memory test PASS") and kernel.memory.physical.free_count == frames_before, "Stress command completion\n");
    feed(&shell, "mem\n");
    check(capture.contains("Heap integrity: OK") and capture.contains("external fragmentation:"), "Diagnostic command output\n");
    feed(&shell, "memtest\n");
    executor.cancel(handle) catch |err| failed(err);
    check(shell.stress_handle == null and kernel.memory.physical.free_count == frames_before, "Shell cleanup left stress task alive\n");
    const replacement = executor.spawnNamed("new-shell", &shell, kernel.shell.Shell.poll, kernel.shell.Shell.cleanup) catch |err| failed(err);
    _ = executor.step();
    check(replacement.isActive() and !executor.step(), "Shell cancellation did not detach reader\n");
    executor.cancel(replacement) catch |err| failed(err);
    var handles: [kernel.task.capacity]kernel.task.Waker = undefined;
    for (&handles) |*entry| entry.* = executor.spawn(&dummy, parked, null) catch |err| failed(err);
    feed(&shell, "memtest\n");
    check(shell.stress_handle == null and kernel.memory.physical.free_count == frames_before and capture.contains("TaskCapacityExceeded"), "Stress spawn failure leaked pages\n");
    for (handles) |entry| executor.cancel(entry) catch |err| failed(err);
    check(kernel.memory.heap.live_allocations == 0, "Shell leaked memory\n");
    serial.writeString("Real keyboard shell command, task states and reader cleanup passed\n");
    runner.exitQemu(.Success);
}
