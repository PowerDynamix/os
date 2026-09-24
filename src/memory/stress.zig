//! Incremental deterministic allocator exercise on an exclusively owned heap.
const std = @import("std");
const Heap = @import("heap.zig").Heap;
const paging = @import("paging.zig");

pub const Stress = struct {
    pub const heap_size = 256 * 1024;
    pub const address = paging.base + (2 << 30) + paging.page_size;
    pub const rounds = 2048;
    heap: Heap,
    slots: [32]?[]align(64) u8 = @splat(null),
    state: u32 = 0x12345678,
    iterations: usize = 0,
    target_rounds: usize = rounds,
    draining: usize = 0,
    done: bool = false,

    pub fn init(pager: *paging.Paging) !Stress {
        return .{ .heap = try Heap.init(pager, address, heap_size) };
    }

    fn pattern(slot: usize, offset: usize) u8 {
        return @truncate(slot * 37 + offset * 13);
    }
    fn verify(bytes: []const u8, slot: usize) !void {
        for (bytes, 0..) |byte, offset| if (byte != pattern(slot, offset)) return error.DataCorruption;
    }
    fn fill(bytes: []u8, slot: usize) void {
        for (bytes, 0..) |*byte, offset| byte.* = pattern(slot, offset);
    }

    /// One bounded operation per task poll. true means verified completion.
    pub fn step(self: *Stress) !bool {
        if (self.done) return true;
        const allocator = self.heap.allocator();
        if (self.iterations < self.target_rounds) {
            self.state = self.state *% 1664525 +% 1013904223;
            const index = (self.state >> 16) % self.slots.len;
            const len = 1 + ((self.state >> 8) % 4096);
            if (self.slots[index]) |bytes| {
                try verify(bytes, index);
                if (self.state & 3 == 0) {
                    const resized = try allocator.realloc(bytes, len);
                    self.slots[index] = resized;
                    try verify(resized[0..@min(bytes.len, len)], index);
                    fill(resized, index);
                } else {
                    allocator.free(bytes);
                    self.slots[index] = null;
                }
            } else {
                const bytes = try allocator.alignedAlloc(u8, .fromByteUnits(64), len);
                self.slots[index] = bytes;
                if (@intFromPtr(bytes.ptr) % 64 != 0) return error.BadAlignment;
                fill(bytes, index);
            }
            self.iterations += 1;
            if (self.iterations % 32 == 0) _ = try self.heap.inspect();
            return false;
        }
        if (self.draining < self.slots.len) {
            const index = self.draining;
            if (self.slots[index]) |bytes| {
                try verify(bytes, index);
                allocator.free(bytes);
                self.slots[index] = null;
            }
            self.draining += 1;
            return false;
        }
        // A request larger than usable capacity must fail without altering storage.
        if (allocator.alloc(u8, heap_size)) |bytes| {
            allocator.free(bytes);
            return error.ExpectedOutOfMemory;
        } else |err| if (err != error.OutOfMemory) return err;
        const stats = try self.heap.inspect();
        if (stats.free_bytes != heap_size or stats.free_blocks != 1 or stats.largest_free_block != heap_size or
            self.heap.live_allocations != 0 or self.heap.requested_bytes != 0 or self.heap.allocations != self.heap.frees) return error.LeakedAllocation;
        self.done = true;
        return true;
    }

    /// Cancellation/error cleanup never trusts the free list or allocation headers.
    pub fn deinit(self: *Stress) void {
        self.heap.discard();
        self.* = undefined;
    }
};
