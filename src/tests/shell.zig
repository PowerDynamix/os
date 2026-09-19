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
    fn redraw(ctx: *anyopaque, input: ?[]const u8) void {
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
    check(capture.contains("mem   -") and shell.len == 0, "Help/backspace\n");
    feed(shell, "first second   \x17");
    check(std.mem.eql(u8, shell.line(), "first "), "Word erase\n");
    feed(shell, "\x15");
    check(shell.len == 0, "Line erase\n");
    feed(shell, "clear\x03");
    check(capture.clears == 0 and shell.len == 0, "Ctrl-C executed command\n");
    feed(shell, "  \t \n");
    check(!capture.contains("Unknown command"), "Empty input executed\n");
    feed(shell, "clear extra\n");
    check(capture.contains("no arguments") and capture.clears == 0, "Argument validation\n");
    feed(shell, "nonsense\n");
    check(capture.contains("Unknown command: nonsense"), "Unknown command\n");
    feed(shell, "\t clear  \n");
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

fn framebufferTests() void {
    var pixels: [16 * 8]u32 = @splat(0);
    var glyphs: [256]u8 = @splat(0xff);
    var fb: kernel.framebuffer.Framebuffer = .{ .base = &pixels, .width = 16, .height = 8, .stride = 16 };
    var console = kernel.console.Console.init(&fb, .{ .width = 1, .height = 1, .char_size = 1, .header_size = 0, .glyphs = &glyphs });
    const output = kernel.shell.Output.framebuffer(&console);
    console.cursor_y = 3;
    pixels[0] = 0x1234;
    output.redraw(output.context, "abcdefghijklmnopqrstuvwxyz");
    check(console.cursor_y == 3 and console.cursor_x < fb.width and pixels[0] == 0x1234, "Long line wrapped/damaged output\n");
    output.redraw(output.context, "a");
    check(console.cursor_x == 5 and pixels[3 * 16 + 10] == 0, "Short line left stale glyphs\n");
    output.redraw(output.context, null);
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
    kernel.memory.init(map) catch |err| failed(err);
    kernel.apic.init(topology) catch |err| failed(err);
    kernel.keyboard.init() catch |err| failed(err);
    kernel.timer.init() catch |err| failed(err);
    framebufferTests();
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
