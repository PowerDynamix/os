//! Bounded boot-CPU kernel log. Safe in task and maskable IRQ context, not NMI/SMP.
//! Recording never allocates or renders; dmesg prints a snapshot after restoring IF.
const std = @import("std");
const irq = @import("interrputs.zig");
const timer = @import("timer.zig");

pub const capacity = 64;
pub const message_capacity = 192;
pub const Level = enum { debug, info, warn, err };
pub const Record = struct {
    timestamp_ms: ?u64 = null,
    level: Level = .info,
    bytes: [message_capacity]u8 = @splat(0),
    len: usize = 0,
    truncated: bool = false,

    pub fn text(self: *const Record) []const u8 {
        return self.bytes[0..self.len];
    }
};
pub const Snapshot = struct {
    records: [capacity]Record = undefined,
    count: usize = 0,
    overwritten: u64 = 0,
};
var records: [capacity]Record = @splat(.{});
var next: usize = 0;
var count: usize = 0;
var overwritten: u64 = 0;

pub fn write(level: Level, text: []const u8) void {
    append(level, text, false);
}

pub fn print(level: Level, comptime format: []const u8, args: anytype) void {
    var buffer: [message_capacity]u8 = @splat(' ');
    const text = std.fmt.bufPrint(&buffer, format, args) catch {
        append(level, &buffer, true);
        return;
    };
    append(level, text, false);
}

fn append(level: Level, text: []const u8, truncated: bool) void {
    const enabled = irq.enabled();
    irq.disable();
    defer if (enabled) irq.enable();
    const trimmed = std.mem.trimEnd(u8, text, "\r\n");
    const record = &records[next];
    record.timestamp_ms = timer.nowIfInitialized();
    record.level = level;
    record.len = @min(trimmed.len, message_capacity);
    record.truncated = truncated or trimmed.len > message_capacity;
    // Each record occupies one logical line, including arbitrary driver messages.
    for (trimmed[0..record.len], record.bytes[0..record.len]) |byte, *dest| {
        dest.* = if (byte >= 32 and byte <= 126) byte else ' ';
    }
    next = (next + 1) % capacity;
    if (count < capacity) count += 1 else overwritten +|= 1;
}

/// Caller owns the snapshot; later writes cannot change it. No callbacks under IF=0.
pub fn snapshot(out: *Snapshot) void {
    const enabled = irq.enabled();
    irq.disable();
    defer if (enabled) irq.enable();
    out.count = count;
    out.overwritten = overwritten;
    const oldest = (next + capacity - count) % capacity;
    for (0..count) |i| out.records[i] = records[(oldest + i) % capacity];
}
