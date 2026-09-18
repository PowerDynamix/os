//! Kernel allocation entry point. Initialize after ExitBootServices and the IDT,
//! before enabling hardware interrupts. Allocators are not IRQ-safe or SMP-safe.
const std = @import("std");
pub const frames = @import("memory/frames.zig");
pub const paging = @import("memory/paging.zig");
pub const Heap = @import("memory/heap.zig").Heap;

// These designs compose with the kernel heap and need no firmware/OS services.
/// Bounded bump allocation, with reset and last-allocation reclamation.
pub const BumpAllocator = std.heap.FixedBufferAllocator;
/// Group allocations by lifetime; deinit/reset releases backing heap blocks.
pub const ArenaAllocator = std.heap.ArenaAllocator;
/// Fixed-size object free list, backed by an arena. Pass allocator() to create/deinit.
pub const ObjectPool = std.heap.MemoryPool;

pub var physical: frames.FrameAllocator = .{};
pub var virtual: paging.Paging = undefined;
pub var heap: Heap = undefined;
var initialized = false;
pub const heap_size = 8 * 1024 * 1024;

pub fn init(map: std.os.uefi.tables.MemoryMapSlice) !void {
    if (initialized) return error.AlreadyInitialized;
    // Once paging is activated, initialization failure is fatal; callers must
    // not retry and overwrite allocator state backing the active tables.
    initialized = true;
    try physical.init(map);
    virtual = try paging.Paging.init(&physical);
    heap = try Heap.init(&virtual, paging.base + paging.page_size, heap_size);
}

pub fn allocator() std.mem.Allocator {
    std.debug.assert(initialized);
    return heap.allocator();
}
