//! Calibrated 100 Hz boot-CPU clock and bounded deadline subscriptions.
//! Time is delivered timer ticks, not wall time: long IRQ masking delays it.
const std = @import("std");
const apic = @import("apic.zig");
const irq = @import("interrputs.zig");

pub const tick_ms = apic.calibration_ms;
pub const capacity = 32;
pub const Instant = u64; // Milliseconds since init, at tick_ms resolution.
pub const Callback = *const fn (*anyopaque) void;
const Entry = struct {
    deadline: Instant = 0,
    context: *anyopaque = undefined,
    callback: ?Callback = null,
};
var entries: [capacity]Entry = @splat(.{});
var milliseconds: Instant = 0;
var initialized = false;
var calibrated_count: u32 = 0;

fn restore(enabled: bool) void {
    if (enabled) irq.enable() else irq.disable();
}

/// Call once after APIC init with IF clear. Owns the LAPIC timer until shutdown.
/// Calibration failures leave the LAPIC timer stopped and may be retried.
pub fn init() !void {
    std.debug.assert(!irq.enabled());
    if (initialized) return error.AlreadyInitialized;
    calibrated_count = try apic.calibrateTimer();
    milliseconds = 0;
    initialized = true;
    apic.start_periodic_timer(calibrated_count, tick);
}

pub fn countsPerTick() u32 {
    return calibrated_count;
}

pub fn now() Instant {
    const enabled = irq.enabled();
    irq.disable();
    defer restore(enabled);
    std.debug.assert(initialized);
    return milliseconds;
}

/// Round positive durations up and add a tick to cover the unknown current tick
/// phase. A zero delay is immediately ready. Overflow is an error, never a wrap.
pub fn deadlineAfter(duration_ms: u64) !Instant {
    const enabled = irq.enabled();
    irq.disable();
    defer restore(enabled);
    if (!initialized) return error.TimerNotInitialized;
    if (duration_ms == 0) return milliseconds;
    const ticks = (duration_ms - 1) / tick_ms + 2;
    const delay = try std.math.mul(u64, ticks, tick_ms);
    return std.math.add(u64, milliseconds, delay);
}

/// True if already due; otherwise atomically register/update one wait per context.
/// Callbacks run in IRQ context and may only signal/wake, never allocate or block.
/// Context must remain stable until fired/cancelled. Single CPU only.
pub fn waitUntil(deadline: Instant, context: *anyopaque, callback: Callback) !bool {
    const enabled = irq.enabled();
    irq.disable();
    defer restore(enabled);
    if (!initialized) return error.TimerNotInitialized;
    var free: ?*Entry = null;
    var existing: ?*Entry = null;
    for (&entries) |*entry| {
        if (entry.callback == null) {
            free = entry;
        } else if (entry.context == context) {
            existing = entry;
        }
    }
    if (deadline <= milliseconds) {
        if (existing) |entry| entry.callback = null;
        return true;
    }
    const entry = existing orelse free orelse return error.TimerCapacityExceeded;
    entry.* = .{ .deadline = deadline, .context = context, .callback = callback };
    return false;
}

pub fn cancel(context: *anyopaque) void {
    const enabled = irq.enabled();
    irq.disable();
    defer restore(enabled);
    for (&entries) |*entry| {
        if (entry.callback != null and entry.context == context) entry.callback = null;
    }
}

pub fn pendingCount() usize {
    const enabled = irq.enabled();
    irq.disable();
    defer restore(enabled);
    var count: usize = 0;
    for (entries) |entry| if (entry.callback != null) {
        count += 1;
    };
    return count;
}

fn tick() void {
    milliseconds +|= tick_ms;
    for (&entries) |*entry| {
        const callback = entry.callback orelse continue;
        if (entry.deadline > milliseconds) continue;
        const context = entry.context;
        entry.callback = null; // Remove before waking; no duplicate expiration.
        callback(context);
    }
}
