//! PS/2 first-port keyboard, translated scan-code set 1, US layout.
//! IRQs only decode/enqueue bytes and wake a reader; tasks own console rendering.
const io = @import("io.zig");
const apic = @import("apic.zig");
const irq = @import("interrputs.zig");
const std = @import("std");
const task = @import("task.zig");

/// Non-ASCII navigation tokens in the byte queue; other values are ASCII.
pub const Key = struct {
    pub const left: u8 = 0x80;
    pub const right: u8 = 0x81;
    pub const up: u8 = 0x82;
    pub const down: u8 = 0x83;
    pub const home: u8 = 0x84;
    pub const end: u8 = 0x85;
    pub const delete: u8 = 0x86;
};

/// Stateful decoder also exercised independently of hardware by tests.
pub const Decoder = struct {
    left_shift: bool = false,
    right_shift: bool = false,
    caps: bool = false,
    caps_down: bool = false,
    left_ctrl: bool = false,
    right_ctrl: bool = false,
    extended: bool = false,
    pause_remaining: u3 = 0,

    pub fn feed(self: *Decoder, byte: u8) ?u8 {
        if (self.pause_remaining != 0) {
            self.pause_remaining -= 1;
            return null;
        }
        if (byte == 0xe1) {
            self.pause_remaining = 5; // Pause's remaining set-1 sequence.
            self.extended = false;
            return null;
        }
        if (byte == 0xe0) {
            self.extended = true;
            return null;
        }
        const extended = self.extended;
        self.extended = false;
        const released = byte & 0x80 != 0;
        const code = byte & 0x7f;
        if (extended) {
            // Ignore Print Screen's synthetic shift bytes.
            if (code == 0x1d) self.right_ctrl = !released;
            if (!released and code == 0x1c) return '\n';
            if (!released and code == 0x35) return '/';
            if (!released) return switch (code) {
                0x4b => Key.left,
                0x4d => Key.right,
                0x48 => Key.up,
                0x50 => Key.down,
                0x47 => Key.home,
                0x4f => Key.end,
                0x53 => Key.delete,
                else => null,
            };
            return null;
        }
        switch (code) {
            0x2a => self.left_shift = !released,
            0x36 => self.right_shift = !released,
            0x1d => self.left_ctrl = !released,
            0x3a => {
                if (!released and !self.caps_down) self.caps = !self.caps;
                self.caps_down = !released;
            },
            else => {},
        }
        if (released) return null;
        const shifted = self.left_shift or self.right_shift;
        var ch = unshifted[code];
        if (ch == 0) return null;
        if (ch >= 'a' and ch <= 'z') {
            if (self.left_ctrl or self.right_ctrl) return ch - 'a' + 1;
            if (shifted != self.caps) ch -= 'a' - 'A';
        } else if (shifted and shifted_chars[code] != 0) {
            ch = shifted_chars[code];
        }
        return ch;
    }
};

const unshifted = blk: {
    var map: [128]u8 = @splat(0);
    for ("1234567890-=", 0x02..) |ch, code| map[code] = ch;
    for ("qwertyuiop[]", 0x10..) |ch, code| map[code] = ch;
    for ("asdfghjkl;'`", 0x1e..) |ch, code| map[code] = ch;
    for ("zxcvbnm,./", 0x2c..) |ch, code| map[code] = ch;
    map[0x0e] = '\x08';
    map[0x0f] = '\t';
    map[0x1c] = '\n';
    map[0x2b] = '\\';
    map[0x37] = '*';
    map[0x39] = ' ';
    break :blk map;
};
const shifted_chars = blk: {
    var map: [128]u8 = @splat(0);
    for ("!@#$%^&*()_+", 0x02..) |ch, code| map[code] = ch;
    map[0x1a] = '{';
    map[0x1b] = '}';
    map[0x27] = ':';
    map[0x28] = '"';
    map[0x29] = '~';
    map[0x2b] = '|';
    map[0x33] = '<';
    map[0x34] = '>';
    map[0x35] = '?';
    break :blk map;
};

var decoder: Decoder = .{};
var queue: [128]u8 = undefined;
var head: u8 = 0;
var tail: u8 = 0;
pub var dropped: u32 = 0;
pub var interrupt_count: u32 = 0;
var reader: ?task.Waker = null;

fn enqueue(ch: u8) void {
    const h = @atomicLoad(u8, &head, .monotonic);
    const next = (h +% 1) & 127;
    if (next == @atomicLoad(u8, &tail, .acquire)) {
        _ = @atomicRmw(u32, &dropped, .Add, 1, .monotonic);
        return; // Drop newest input; never block inside an IRQ.
    }
    queue[h] = ch;
    @atomicStore(u8, &head, next, .release);
    if (reader) |waker| {
        waker.wake();
    }
}

/// Async single-consumer read: null means suspended until IRQ1 wakes the task.
/// Checking the queue and subscribing happen with IF clear, so input cannot
/// arrive between them. Do not mix another pop() consumer with an async reader.
pub fn pollRead(waker: task.Waker) !?u8 {
    const enabled = irq.enabled();
    irq.disable();
    defer if (enabled) irq.enable();
    if (!waker.isActive()) return error.InvalidTask;
    if (reader) |waiting| {
        if (!waiting.eql(waker) and waiting.isActive()) return error.ReaderBusy;
    }
    if (pop()) |ch| {
        reader = null;
        return ch;
    }
    reader = waker;
    return null;
}

/// Detach on task completion/cancellation before its executor storage expires.
pub fn cancelRead(waker: task.Waker) void {
    const enabled = irq.enabled();
    irq.disable();
    defer if (enabled) irq.enable();
    if (reader) |waiting| {
        if (waiting.eql(waker)) reader = null;
    }
}
pub fn pop() ?u8 {
    const t = @atomicLoad(u8, &tail, .monotonic);
    if (t == @atomicLoad(u8, &head, .acquire)) return null;
    const ch = queue[t];
    @atomicStore(u8, &tail, (t +% 1) & 127, .release);
    return ch;
}

fn handle_irq() void {
    _ = @atomicRmw(u32, &interrupt_count, .Add, 1, .monotonic);
    // Drain pending bytes before APIC EOI; discard AUX and parity/timeout data.
    // Bound the work so a malfunctioning controller cannot trap us in an IRQ.
    for (0..256) |_| {
        const status = io.inb(0x64);
        if (status & 1 == 0) break;
        const byte = io.inb(0x60);
        if (status & 0xe0 != 0) continue;
        if (decoder.feed(byte)) |ch| enqueue(ch);
    }
}

const poll_limit = 100_000;
fn wait_input() !void {
    for (0..poll_limit) |_| {
        if (io.inb(0x64) & 2 == 0) return;
        io.pause();
    }
    return error.Ps2Timeout;
}
fn command(value: u8) !void {
    try wait_input();
    io.outb(0x64, value);
}
fn data(value: u8) !void {
    try wait_input();
    io.outb(0x60, value);
}
fn response() !u8 {
    for (0..poll_limit) |_| {
        const status = io.inb(0x64);
        if (status & 1 != 0) {
            const byte = io.inb(0x60);
            if (status & 0xe0 != 0) continue;
            return byte;
        }
        io.pause();
    }
    return error.Ps2Timeout;
}
fn device_command(value: u8) !void {
    for (0..3) |_| {
        try data(value);
        const reply = try response();
        if (reply == 0xfa) return;
        if (reply != 0xfe) return error.Ps2UnexpectedResponse;
    }
    return error.Ps2ResendLimit;
}
fn configure(value: u8) !void {
    try command(0x60);
    try data(value);
}

/// Take ownership after ExitBootServices, with APIC ready and IF still clear.
/// The mouse port stays disabled. USB keyboards require a separate USB driver.
pub fn init() !void {
    std.debug.assert(!irq.enabled());
    decoder = .{};
    head = 0;
    tail = 0;
    dropped = 0;
    interrupt_count = 0;
    reader = null;
    try command(0xad); // Disable first port while clearing firmware input.
    try command(0xa7); // Disable auxiliary port.
    for (0..256) |_| {
        if (io.inb(0x64) & 1 == 0) break;
        _ = io.inb(0x60);
    }
    if (io.inb(0x64) & 1 != 0) return error.Ps2OutputStuck;
    try command(0x20);
    var config = try response();
    config &= ~@as(u8, 0x43); // IRQ1/IRQ12 off, translation off during commands.
    config |= 0x20; // Auxiliary clock disabled.
    try configure(config);
    try command(0xae);
    try device_command(0xf5); // Disable scanning.
    try device_command(0xf0);
    try device_command(0x02); // Keyboard emits set 2; controller translates to 1.
    try device_command(0xf4); // Enable scanning; consume ACK before IRQ enable.
    try apic.route_isa(1, apic.keyboard_vector, handle_irq);
    config = (config & ~@as(u8, 0x10)) | 0x41;
    try configure(config);
}
