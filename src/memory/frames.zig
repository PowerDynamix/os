//! Physical 4 KiB frames. Only conventional UEFI RAM is reclaimable for now;
//! loader, boot-service, ACPI and runtime pages stay reserved. Single CPU only.
const std = @import("std");
pub const page_size = 4096;
pub const physical_limit: usize = 64 * 1024 * 1024 * 1024;
const frame_count = physical_limit / page_size;
const Region = struct { first: usize, end: usize };

pub const FrameAllocator = struct {
    // A set bit is unavailable (reserved or allocated).
    used: [frame_count / 64]u64 = undefined,
    regions: [256]Region = undefined,
    region_count: usize = 0,
    free_count: usize = 0,
    total_count: usize = 0,
    hint: usize = 0,

    /// Storage must outlive every allocated frame. Do not reinitialize a live allocator.
    pub fn init(self: *FrameAllocator, map: std.os.uefi.tables.MemoryMapSlice) !void {
        @memset(&self.used, std.math.maxInt(u64));
        self.region_count = 0;
        self.free_count = 0;
        self.hint = 0;
        var it = map.iterator();
        while (it.next()) |desc| {
            if (desc.type != .conventional_memory or desc.attribute.memory_runtime or
                desc.attribute.ro or desc.attribute.wp or desc.attribute.rp) continue;
            if (desc.physical_start % page_size != 0) return error.InvalidMemoryMap;
            const first = @max(1, @min(frame_count, desc.physical_start / page_size));
            const end = @min(frame_count, std.math.add(u64, desc.physical_start / page_size, desc.number_of_pages) catch return error.InvalidMemoryMap);
            if (first >= end) continue;
            if (self.region_count == self.regions.len) return error.TooManyRegions;
            for (self.regions[0..self.region_count]) |r| {
                if (first < r.end and end > r.first) return error.InvalidMemoryMap;
            }
            self.regions[self.region_count] = .{ .first = first, .end = end };
            self.region_count += 1;
            for (first..end) |index| self.used[index / 64] &= ~(@as(u64, 1) << @intCast(index % 64));
            self.free_count += end - first;
        }
        self.total_count = self.free_count;
        if (self.free_count == 0) return error.OutOfMemory;
    }

    pub fn alloc(self: *FrameAllocator) error{OutOfMemory}!usize {
        if (self.free_count == 0) return error.OutOfMemory;
        var word = self.hint;
        while (self.used[word] == std.math.maxInt(u64)) word = (word + 1) % self.used.len;
        const bit: u6 = @intCast(@ctz(~self.used[word]));
        self.used[word] |= @as(u64, 1) << bit;
        self.hint = word;
        self.free_count -= 1;
        return (word * 64 + bit) * page_size;
    }

    /// Reject reserved addresses and double frees. Call only after removing aliases
    /// owned by the caller; permanent identity mappings are retained by the kernel.
    pub fn free(self: *FrameAllocator, address: usize) !void {
        if (address % page_size != 0) return error.InvalidFrame;
        const index = address / page_size;
        for (self.regions[0..self.region_count]) |r| {
            if (index >= r.first and index < r.end) {
                const mask = @as(u64, 1) << @intCast(index % 64);
                if (self.used[index / 64] & mask == 0) return error.DoubleFree;
                self.used[index / 64] &= ~mask;
                self.free_count += 1;
                self.hint = @min(self.hint, index / 64);
                return;
            }
        }
        return error.InvalidFrame;
    }
};
