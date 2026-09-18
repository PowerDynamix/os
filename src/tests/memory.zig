const std = @import("std");
const uefi = std.os.uefi;
const kernel = @import("os_kernel");
const memory = kernel.memory;
const paging = memory.paging;
const serial = @import("serial.zig");
const runner = @import("test_runner.zig");
const scenario = @import("test_options").scenario;
const test_address = paging.base + (1 << 30);
var limited_frames: memory.frames.FrameAllocator = .{};

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
fn unexpectedFault(_: *const kernel.interrupts.InterruptFrame, _: u64) noreturn {
    serial.writeString("Unexpected double fault\n");
    runner.exitQemu(.Failed);
}
fn pageFault(frame: *const kernel.interrupts.InterruptFrame, code: u64, address: usize) noreturn {
    check(scenario.len != 0, "Unexpected page fault\n");
    check(address == test_address, "Wrong CR2\n");
    check(frame.cs == 8 and frame.rip != 0, "Wrong page-fault frame\n");
    const expected: u64 = if (std.mem.eql(u8, scenario, "nx")) 17 else if (std.mem.eql(u8, scenario, "readonly")) 3 else 2;
    check(code == expected, "Wrong page-fault error code\n");
    serial.writeString("CPU page protection and CR2 verified\n");
    runner.exitQemu(.Success);
}

fn descriptor(kind: uefi.tables.MemoryType, start: u64, pages: u64) uefi.tables.MemoryDescriptor {
    return .{ .type = kind, .physical_start = start, .virtual_start = 0, .number_of_pages = pages, .attribute = @bitCast(@as(u64, 8)) };
}

fn frameTests() !void {
    // Synthetic map with a reserved hole, page zero and a non-native descriptor stride.
    const Padded = extern struct { desc: uefi.tables.MemoryDescriptor, padding: [8]u8 = @splat(0) };
    var descriptors = [_]Padded{
        .{ .desc = descriptor(.conventional_memory, 0, 3) },
        .{ .desc = descriptor(.reserved_memory_type, 0x3000, 3) },
        .{ .desc = descriptor(.conventional_memory, 0x6000, 1) },
        .{ .desc = descriptor(.loader_data, 0x7000, 2) },
    };
    const map: uefi.tables.MemoryMapSlice = .{
        .ptr = @ptrCast(&descriptors),
        .info = .{ .key = @enumFromInt(0), .descriptor_size = @sizeOf(Padded), .descriptor_version = 1, .len = descriptors.len },
    };
    const physical = &memory.physical;
    try physical.init(map);
    check(physical.free_count == 3, "Frame filtering\n");
    const a = try physical.alloc();
    const b = try physical.alloc();
    const c = try physical.alloc();
    check(a == 0x1000 and b == 0x2000 and c == 0x6000, "Allocated reserved frame\n");
    if (physical.alloc()) |_| return error.ExpectedFrameOOM else |err| check(err == error.OutOfMemory, "Frame OOM\n");
    try physical.free(b);
    check(try physical.alloc() == b, "Frame reuse\n");
    try physical.free(b);
    if (physical.free(b)) |_| return error.ExpectedDoubleFree else |err| check(err == error.DoubleFree, "Double free\n");
    if (physical.free(0x3000)) |_| return error.FreedReservedFrame else |err| check(err == error.InvalidFrame, "Reserved frame\n");
    if (physical.free(a + 1)) |_| return error.FreedUnalignedFrame else |err| check(err == error.InvalidFrame, "Unaligned frame\n");
    serial.writeString("Frame filtering, exhaustion and reuse passed\n");
}

fn mappingTests() !void {
    const pager = &memory.virtual;
    const physical = &memory.physical;
    const baseline = physical.free_count;
    const a = try physical.alloc();
    const b = try physical.alloc();
    try pager.map(test_address, a, .{});
    const alias: *volatile u64 = @ptrFromInt(test_address);
    alias.* = 0x12345678;
    check(@as(*volatile u64, @ptrFromInt(a)).* == 0x12345678, "Physical alias\n");
    check(pager.translate(test_address + 123) == a + 123, "Translation offset\n");
    if (pager.map(test_address, b, .{})) |_| return error.ExpectedMapConflict else |err| check(err == error.AlreadyMapped, "Map conflict\n");
    check(try pager.unmap(test_address) == a, "Unmap physical address\n");
    check(pager.translate(test_address) == null, "Unmap translation\n");
    try pager.map(test_address, b, .{});
    alias.* = 0xabcdef;
    check(@as(*volatile u64, @ptrFromInt(b)).* == 0xabcdef, "Stale TLB\n");
    check(@as(*volatile u64, @ptrFromInt(a)).* == 0x12345678, "Old frame overwritten\n");
    _ = try pager.unmap(test_address);
    if (pager.unmap(test_address)) |_| return error.ExpectedMissingMap else |err| check(err == error.NotMapped, "Missing map\n");
    if (pager.map(0, a, .{})) |_| return error.ModifiedFirmwareMap else |err| check(err == error.InvalidVirtualAddress, "Protected firmware range\n");
    if (pager.map(test_address + 1, a, .{})) |_| return error.MappedUnaligned else |err| check(err == error.InvalidVirtualAddress, "Mapping alignment\n");
    try physical.free(a);
    try physical.free(b);
    check(physical.free_count == baseline, "Page table leak\n");
    // Deliberately provide only two table frames for a fresh three-table path.
    // The constrained allocator tracks real frames borrowed from the main one.
    const table_a = try physical.alloc();
    const table_b = try physical.alloc();
    var descriptors = [_]uefi.tables.MemoryDescriptor{
        descriptor(.conventional_memory, table_a, 1),
        descriptor(.conventional_memory, table_b, 1),
    };
    try limited_frames.init(.{
        .ptr = @ptrCast(&descriptors),
        .info = .{ .key = @enumFromInt(0), .descriptor_size = @sizeOf(uefi.tables.MemoryDescriptor), .descriptor_version = 1, .len = descriptors.len },
    });
    // A separate empty PML4 lets us exercise all three allocation levels.
    const temporary_root = try physical.alloc();
    @memset(@as(*[512]u64, @ptrFromInt(temporary_root)), 0);
    var constrained: paging.Paging = .{ .root = temporary_root, .frames = &limited_frames };
    if (constrained.map(test_address, a, .{})) |_| return error.ExpectedTableOOM else |err| check(err == error.OutOfMemory, "Table OOM\n");
    check(limited_frames.free_count == 2 and constrained.translate(test_address) == null, "Table OOM rollback\n");
    try physical.free(temporary_root);
    try physical.free(table_a);
    try physical.free(table_b);
    check(physical.free_count == baseline, "Table rollback leaked\n");
    serial.writeString("Mapping, aliasing, TLB invalidation and table reclamation passed\n");
}

fn heapTests() !void {
    const baseline = memory.physical.free_count;
    var heap = try memory.Heap.init(&memory.virtual, test_address + paging.page_size, 4 * paging.page_size);
    const allocator = heap.allocator();
    const first = try allocator.alloc(u8, 100);
    const second = try allocator.alignedAlloc(u8, .fromByteUnits(4096), 4096);
    const third = try allocator.alloc(u64, 73);
    check(@intFromPtr(second.ptr) % 4096 == 0, "Heap alignment\n");
    @memset(first, 0x5a);
    @memset(second, 0x3c);
    @memset(third, 0x9876);
    allocator.free(second);
    const grown = try allocator.realloc(first, 3000);
    for (grown[0..100]) |byte| check(byte == 0x5a, "Realloc lost data\n");
    check(allocator.resize(grown, 64), "Heap shrink\n");
    allocator.free(@as([]u8, grown[0..64]));
    allocator.free(third);
    check(heap.live_allocations == 0 and heap.freeBytes() == heap.size, "Heap coalescing\n");
    const full = try allocator.alloc(u8, heap.size - 16);
    if (allocator.alloc(u8, 1)) |_| return error.ExpectedHeapOOM else |err| check(err == error.OutOfMemory, "Heap OOM\n");
    allocator.free(full);
    const again = try allocator.alloc(u8, heap.size - 16);
    allocator.free(again);
    // Vary sizes and free order; verify live neighbors throughout.
    var slots: [32]?[]u8 = @splat(null);
    var state: u32 = 0x12345678;
    for (0..2000) |_| {
        state = state *% 1664525 +% 1013904223;
        const index = (state >> 16) % slots.len;
        if (slots[index]) |bytes| {
            for (bytes) |byte| check(byte == @as(u8, @intCast(index)), "Heap neighbor corrupted\n");
            allocator.free(bytes);
            slots[index] = null;
        } else {
            const len = 1 + ((state >> 8) % 512);
            const bytes = try allocator.alloc(u8, len);
            @memset(bytes, @intCast(index));
            slots[index] = bytes;
        }
    }
    for (slots, 0..) |slot, index| if (slot) |bytes| {
        for (bytes) |byte| check(byte == @as(u8, @intCast(index)), "Final heap content\n");
        allocator.free(bytes);
    };
    check(heap.freeBytes() == heap.size, "Fragmented heap did not coalesce\n");
    // A conflict halfway through initialization must release all earlier pages.
    const occupied = try memory.physical.alloc();
    const conflict_start = test_address + 16 * paging.page_size;
    try memory.virtual.map(conflict_start + paging.page_size, occupied, .{});
    const before_conflict = memory.physical.free_count;
    if (memory.Heap.init(&memory.virtual, conflict_start, 3 * paging.page_size)) |_| return error.ExpectedHeapConflict else |err| check(err == error.AlreadyMapped, "Heap conflict\n");
    check(memory.virtual.translate(conflict_start) == null and memory.physical.free_count == before_conflict, "Heap rollback leaked\n");
    _ = try memory.virtual.unmap(conflict_start + paging.page_size);
    try memory.physical.free(occupied);
    heap.deinit();
    check(memory.physical.free_count == baseline, "Heap deinit leak\n");
    serial.writeString("Heap alignment, realloc, coalescing, exhaustion and rollback passed\n");
}

fn allocatorDesignTests() !void {
    const allocator = memory.allocator();
    const baseline = memory.heap.freeBytes();
    var storage: [128]u8 = undefined;
    var bump = memory.BumpAllocator.init(&storage);
    const first = try bump.allocator().alloc(u8, storage.len);
    if (bump.allocator().alloc(u8, 1)) |_| return error.ExpectedBumpOOM else |err| check(err == error.OutOfMemory, "Bump OOM\n");
    bump.reset();
    const second = try bump.allocator().alloc(u8, storage.len);
    check(first.ptr == second.ptr, "Bump reset\n");
    var arena = memory.ArenaAllocator.init(allocator);
    const bytes = try arena.allocator().alloc(u8, 9000);
    @memset(bytes, 0x42);
    check(arena.reset(.free_all), "Arena reset\n");
    _ = try arena.allocator().create(u64);
    arena.deinit();
    var pool: memory.ObjectPool(u64) = .empty;
    const object = try pool.create(allocator);
    object.* = 123;
    pool.destroy(object);
    const reused = try pool.create(allocator);
    check(reused == object, "Pool reuse\n");
    pool.destroy(reused);
    pool.deinit(allocator);
    check(memory.heap.freeBytes() == baseline, "Allocator design leak\n");
    serial.writeString("Bump, arena and object-pool lifetimes passed\n");
}

pub fn main() uefi.Status {
    serial.initSerial();
    frameTests() catch |err| failed(err);
    const bs = uefi.system_table.boot_services.?;
    var buffer: [32 * 1024]u8 align(@alignOf(uefi.tables.MemoryDescriptor)) = undefined;
    const map = bs.getMemoryMap(&buffer) catch |err| failed(err);
    bs.exitBootServices(uefi.handle, map.info.key) catch |err| failed(err);
    kernel.interrupts.init_gdt();
    kernel.interrupts.init_idt_with_handlers(.{ .double_fault = unexpectedFault, .page_fault = pageFault });
    const old_root = paging.currentRoot();
    memory.init(map) catch |err| failed(err);
    check(paging.currentRoot() == memory.virtual.root and paging.currentRoot() != old_root, "CR3 not replaced\n");
    check(memory.virtual.translate(@intFromPtr(&buffer)) == @intFromPtr(&buffer), "Stack identity mapping\n");
    check(memory.virtual.translate(paging.base) == null and memory.virtual.translate(paging.base + paging.page_size + memory.heap_size) == null, "Heap guards\n");
    if (comptime scenario.len != 0) {
        const physical = memory.physical.alloc() catch |err| failed(err);
        if (comptime std.mem.eql(u8, scenario, "readonly")) {
            memory.virtual.map(test_address, physical, .{ .writable = false }) catch |err| failed(err);
        } else if (comptime std.mem.eql(u8, scenario, "nx")) {
            memory.virtual.map(test_address, physical, .{}) catch |err| failed(err);
            @as(*volatile u8, @ptrFromInt(test_address)).* = 0xc3; // RET, if NX fails.
            const function: *const fn () callconv(.c) void = @ptrFromInt(test_address);
            function();
            runner.exitQemu(.Failed);
        } else {
            memory.virtual.map(test_address, physical, .{}) catch |err| failed(err);
            @as(*volatile u8, @ptrFromInt(test_address)).* = 1; // Populate TLB.
            _ = memory.virtual.unmap(test_address) catch |err| failed(err);
        }
        @as(*volatile u8, @ptrFromInt(test_address)).* = 2;
        runner.exitQemu(.Failed);
    }
    mappingTests() catch |err| failed(err);
    heapTests() catch |err| failed(err);
    allocatorDesignTests() catch |err| failed(err);
    runner.exitQemu(.Success);
}
