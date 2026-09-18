//! Four-level x86_64 paging. Preserve firmware mappings and their cache flags;
//! own PML4 slot 256 for new supervisor mappings. Firmware table pages remain
//! reserved. Physical RAM/page-table pointers use UEFI's identity mapping.
const frames = @import("frames.zig");
pub const page_size = frames.page_size;
pub const base: usize = 0xffff800000000000;
pub const end: usize = base + (@as(usize, 1) << 39);
const address_mask: u64 = 0x000ffffffffff000;
const present: u64 = 1;
const huge: u64 = 1 << 7;
const nx: u64 = @as(u64, 1) << 63;
const Table = [512]u64;
pub const Flags = struct { writable: bool = true, executable: bool = false };

pub fn currentRoot() usize {
    return asm volatile ("movq %%cr3, %[value]"
        : [value] "=r" (-> usize),
    ) & address_mask;
}
fn table(address: usize) *Table {
    return @ptrFromInt(address & address_mask);
}
fn invalidate(address: usize) void {
    asm volatile ("invlpg (%[address])"
        :
        : [address] "r" (address),
        : .{ .memory = true });
}

pub const Paging = struct {
    frames: *frames.FrameAllocator,
    root: usize,

    /// Requires ExitBootServices and interrupts disabled. NX must be supported;
    /// five-level paging is deliberately rejected. Keep self and frames stable.
    pub fn init(allocator: *frames.FrameAllocator) !Paging {
        const cr4 = asm volatile ("movq %%cr4, %[value]"
            : [value] "=r" (-> usize),
        );
        if (cr4 & (1 << 12) != 0) return error.FiveLevelPagingUnsupported;
        var extended: u32 = undefined;
        asm volatile ("cpuid"
            : [eax] "={eax}" (extended),
            : [leaf] "{eax}" (@as(u32, 0x80000000)),
            : .{ .ebx = true, .ecx = true, .edx = true });
        if (extended < 0x80000001) return error.NoExecuteUnsupported;
        var features: u32 = undefined;
        asm volatile ("cpuid"
            : [edx] "={edx}" (features),
            : [leaf] "{eax}" (@as(u32, 0x80000001)),
            : .{ .eax = true, .ebx = true, .ecx = true });
        if (features & (1 << 20) == 0) return error.NoExecuteUnsupported;
        const old_root = currentRoot();
        if (table(old_root)[256] & present != 0) return error.VirtualRangeOccupied;
        const root = try allocator.alloc();
        table(root).* = table(old_root).*;
        // EFER.NXE allows bit 63 on leaf entries. Preserve all other EFER bits.
        asm volatile (
            \\ rdmsr
            \\ orl $0x800, %eax
            \\ wrmsr
            :
            : [msr] "{ecx}" (@as(u32, 0xc0000080)),
            : .{ .eax = true, .edx = true, .memory = true });
        asm volatile ("movq %[root], %%cr3"
            :
            : [root] "r" (root),
            : .{ .memory = true });
        // Respect read-only mappings even in supervisor mode.
        asm volatile (
            \\ movq %cr0, %rax
            \\ orq $0x10000, %rax
            \\ movq %rax, %cr0
            ::: .{ .rax = true, .memory = true });
        return .{ .frames = allocator, .root = root };
    }

    fn validate(address: usize) !void {
        if (address < base or address >= end or address % page_size != 0) return error.InvalidVirtualAddress;
    }

    /// Maps caller-owned RAM. Does not transfer frame ownership. On failure,
    /// newly allocated intermediate tables are returned to the frame allocator.
    pub fn map(self: *Paging, virtual: usize, physical: usize, flags: Flags) !void {
        try validate(virtual);
        if (physical == 0 or physical % page_size != 0 or physical >= frames.physical_limit) return error.InvalidPhysicalAddress;
        var created: [3]*u64 = undefined;
        var count: usize = 0;
        errdefer while (count > 0) {
            count -= 1;
            const entry = created[count];
            const frame = entry.* & address_mask;
            entry.* = 0;
            invalidate(virtual);
            self.frames.free(frame) catch unreachable;
        };
        var current = table(self.root);
        for ([_]u6{ 39, 30, 21 }) |shift| {
            const entry = &current[(virtual >> shift) & 511];
            if (entry.* & present == 0) {
                const frame = try self.frames.alloc();
                @memset(table(frame), 0);
                entry.* = frame | 3;
                created[count] = entry;
                count += 1;
            }
            if (entry.* & huge != 0) return error.HugePageConflict;
            current = table(entry.*);
        }
        const leaf = &current[(virtual >> 12) & 511];
        if (leaf.* & present != 0) return error.AlreadyMapped;
        leaf.* = physical | present | (if (flags.writable) @as(u64, 2) else 0) | (if (flags.executable) @as(u64, 0) else nx);
        invalidate(virtual);
    }

    /// Remove a mapping, reclaim empty page tables, and return its physical frame.
    /// The caller must free the returned frame if it owns it.
    pub fn unmap(self: *Paging, virtual: usize) !usize {
        try validate(virtual);
        var parents: [3]*u64 = undefined;
        var current = table(self.root);
        for ([_]u6{ 39, 30, 21 }, 0..) |shift, i| {
            parents[i] = &current[(virtual >> shift) & 511];
            if (parents[i].* & present == 0) return error.NotMapped;
            current = table(parents[i].*);
        }
        const leaf = &current[(virtual >> 12) & 511];
        if (leaf.* & present == 0) return error.NotMapped;
        const physical = leaf.* & address_mask;
        leaf.* = 0;
        invalidate(virtual);
        var depth: usize = 3;
        while (depth > 0) {
            for (current) |entry| if (entry & present != 0) return physical;
            depth -= 1;
            const parent = parents[depth];
            const frame = parent.* & address_mask;
            parent.* = 0;
            invalidate(virtual);
            try self.frames.free(frame);
            if (depth > 0) current = table(parents[depth - 1].*);
        }
        return physical;
    }

    /// Translate firmware huge pages as well as kernel 4 KiB pages.
    pub fn translate(self: *const Paging, virtual: usize) ?usize {
        const upper = virtual >> 47;
        if (upper != 0 and upper != 0x1ffff) return null;
        var current = table(self.root);
        for ([_]u6{ 39, 30, 21, 12 }) |shift| {
            const entry = current[(virtual >> shift) & 511];
            if (entry & present == 0) return null;
            if (shift == 12 or ((shift == 30 or shift == 21) and entry & huge != 0)) {
                const offset_mask = (@as(usize, 1) << shift) - 1;
                return (entry & address_mask & ~offset_mask) | (virtual & offset_mask);
            }
            current = table(entry);
        }
        unreachable;
    }
};
