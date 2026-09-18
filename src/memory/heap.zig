//! Page-backed first-fit heap with splitting and address-ordered coalescing.
//! Single CPU, task context only: never call from an interrupt handler.
const std = @import("std");
const paging = @import("paging.zig");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const Block = struct { size: usize, next: ?*Block };
const Header = struct { start: usize, size: usize };
const unit: usize = @alignOf(Header);

pub const Heap = struct {
    pager: *paging.Paging,
    start: usize,
    size: usize,
    head: ?*Block,
    live_allocations: usize = 0,

    /// Commit a fixed page budget; callers select capacity. Leave guard pages on
    /// both sides. Mapping failure rolls back all frames and intermediate tables.
    pub fn init(pager: *paging.Paging, start: usize, size: usize) !Heap {
        if (size == 0 or size % paging.page_size != 0 or start % paging.page_size != 0 or
            start < paging.base + paging.page_size or start >= paging.end or
            size > paging.end - start - paging.page_size) return error.InvalidHeapRange;
        if (pager.translate(start - paging.page_size) != null or pager.translate(start + size) != null) return error.GuardPageMapped;
        var committed: usize = 0;
        errdefer {
            var offset: usize = 0;
            while (offset < committed) : (offset += paging.page_size) {
                const frame = pager.unmap(start + offset) catch unreachable;
                pager.frames.free(frame) catch unreachable;
            }
        }
        while (committed < size) : (committed += paging.page_size) {
            const physical = try pager.frames.alloc();
            pager.map(start + committed, physical, .{}) catch |err| {
                pager.frames.free(physical) catch unreachable;
                return err;
            };
            const bytes: [*]u8 = @ptrFromInt(start + committed);
            @memset(bytes[0..paging.page_size], 0);
        }
        const head: *Block = @ptrFromInt(start);
        head.* = .{ .size = size, .next = null };
        return .{ .pager = pager, .start = start, .size = size, .head = head };
    }

    /// All allocations (including arenas and pools) must be freed first.
    pub fn deinit(self: *Heap) void {
        std.debug.assert(self.live_allocations == 0);
        var offset: usize = 0;
        while (offset < self.size) : (offset += paging.page_size) {
            const frame = self.pager.unmap(self.start + offset) catch unreachable;
            self.pager.frames.free(frame) catch unreachable;
        }
        self.* = undefined;
    }

    /// The Heap object must stay at a stable address while this interface is used.
    pub fn allocator(self: *Heap) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    pub fn freeBytes(self: *const Heap) usize {
        var bytes: usize = 0;
        var current = self.head;
        while (current) |block| : (current = block.next) bytes += block.size;
        return bytes;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
        const self: *Heap = @ptrCast(@alignCast(ctx));
        const align_bytes = @max(unit, alignment.toByteUnits());
        var link = &self.head;
        while (link.*) |block| {
            const start = @intFromPtr(block);
            const unaligned = std.math.add(usize, start, @sizeOf(Header)) catch return null;
            const aligned = std.math.add(usize, unaligned, align_bytes - 1) catch return null;
            const user = aligned & ~(align_bytes - 1);
            const user_end = std.math.add(usize, user, len) catch return null;
            const padded = std.math.add(usize, user_end, unit - 1) catch return null;
            var consumed = (padded & ~(unit - 1)) - start;
            if (consumed > block.size) {
                link = &block.next;
                continue;
            }
            const next = block.next;
            if (block.size - consumed >= @sizeOf(Block)) {
                const tail: *Block = @ptrFromInt(start + consumed);
                tail.* = .{ .size = block.size - consumed, .next = next };
                link.* = tail;
            } else {
                consumed = block.size;
                link.* = next;
            }
            const header: *Header = @ptrFromInt(user - @sizeOf(Header));
            header.* = .{ .start = start, .size = consumed };
            self.live_allocations += 1;
            return @ptrFromInt(user);
        }
        return null;
    }

    fn resize(_: *anyopaque, memory: []u8, _: Alignment, new_len: usize, _: usize) bool {
        const header: *const Header = @ptrFromInt(@intFromPtr(memory.ptr) - @sizeOf(Header));
        // Keep the block on shrink; realloc may move when growth exceeds capacity.
        return new_len <= header.start + header.size - @intFromPtr(memory.ptr);
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
        return if (resize(ctx, memory, alignment, new_len, ra)) memory.ptr else null;
    }
    fn free(ctx: *anyopaque, memory: []u8, _: Alignment, _: usize) void {
        const self: *Heap = @ptrCast(@alignCast(ctx));
        const header: Header = @as(*const Header, @ptrFromInt(@intFromPtr(memory.ptr) - @sizeOf(Header))).*;
        std.debug.assert(header.start >= self.start and header.start + header.size <= self.start + self.size);
        var link = &self.head;
        var previous: ?*Block = null;
        while (link.*) |block| {
            if (@intFromPtr(block) >= header.start) break;
            previous = block;
            link = &block.next;
        }
        if (previous) |p| std.debug.assert(@intFromPtr(p) + p.size <= header.start);
        if (link.*) |next| std.debug.assert(header.start + header.size <= @intFromPtr(next));
        const block: *Block = @ptrFromInt(header.start);
        block.* = .{ .size = header.size, .next = link.* };
        link.* = block;
        if (block.next) |next| {
            if (header.start + block.size == @intFromPtr(next)) {
                block.size += next.size;
                block.next = next.next;
            }
        }
        if (previous) |p| {
            if (@intFromPtr(p) + p.size == header.start) {
                p.size += block.size;
                p.next = block.next;
            }
        }
        self.live_allocations -= 1;
    }
};
