//! Copy the interrupt topology before leaving UEFI. No allocator or AML required.
//! Firmware tables and MMIO use the identity mappings inherited from UEFI.
const std = @import("std");
const uefi = std.os.uefi;

pub const IoApic = struct { address: u32, gsi_base: u32 };
pub const Route = struct { gsi: u32, active_low: bool = false, level: bool = false };
pub const Topology = struct {
    lapic_address: u64 = 0,
    io_apics: [8]IoApic = undefined,
    io_apic_count: usize = 0,
    legacy_pic: bool = false,
    isa: [16]Route = blk: {
        var routes: [16]Route = undefined;
        for (&routes, 0..) |*route, irq| route.* = .{ .gsi = irq };
        break :blk routes;
    },
};

fn read(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}
fn checksum(bytes: []const u8) bool {
    var sum: u8 = 0;
    for (bytes) |byte| sum +%= byte;
    return sum == 0;
}
fn table(address: u64) ![]const u8 {
    if (address == 0) return error.InvalidAcpiAddress;
    const ptr: [*]const u8 = @ptrFromInt(address);
    const length = read(u32, ptr[0..36], 4);
    if (length < 36 or length > 1024 * 1024) return error.InvalidAcpiLength;
    const bytes = ptr[0..length];
    if (!checksum(bytes)) return error.InvalidAcpiChecksum;
    return bytes;
}

/// Decode MADT entries, honoring ISA source overrides and a LAPIC address override.
/// Unknown records are skipped; malformed lengths and reserved flags are rejected.
pub fn parseMadt(bytes: []const u8) !Topology {
    if (bytes.len < 44 or !std.mem.eql(u8, bytes[0..4], "APIC")) return error.InvalidMadt;
    if (read(u32, bytes, 4) != bytes.len or !checksum(bytes)) return error.InvalidMadt;
    var result: Topology = .{};
    result.lapic_address = read(u32, bytes, 36);
    result.legacy_pic = read(u32, bytes, 40) & 1 != 0;
    var offset: usize = 44;
    while (offset < bytes.len) {
        if (bytes.len - offset < 2) return error.InvalidMadt;
        const length = bytes[offset + 1];
        if (length < 2 or length > bytes.len - offset) return error.InvalidMadt;
        const entry = bytes[offset..][0..length];
        switch (entry[0]) {
            1 => {
                if (length < 12) return error.InvalidMadt;
                if (result.io_apic_count == result.io_apics.len) return error.TooManyIoApics;
                const address = read(u32, entry, 4);
                if (address == 0 or address & 0xfff != 0) return error.InvalidAcpiAddress;
                result.io_apics[result.io_apic_count] = .{ .address = address, .gsi_base = read(u32, entry, 8) };
                result.io_apic_count += 1;
            },
            2 => {
                if (length < 10 or entry[2] != 0 or entry[3] >= 16) return error.InvalidMadt;
                const flags = read(u16, entry, 8);
                if (flags & 0xfff0 != 0 or flags & 3 == 2 or (flags >> 2) & 3 == 2) return error.InvalidMadt;
                result.isa[entry[3]] = .{
                    .gsi = read(u32, entry, 4),
                    .active_low = flags & 3 == 3,
                    .level = (flags >> 2) & 3 == 3,
                };
            },
            5 => {
                if (length < 12) return error.InvalidMadt;
                result.lapic_address = read(u64, entry, 4);
            },
            else => {},
        }
        offset += length;
    }
    if (result.io_apic_count == 0) return error.NoIoApic;
    if (result.lapic_address == 0 or result.lapic_address & 0xfff != 0) return error.InvalidAcpiAddress;
    return result;
}

pub fn discover() !Topology {
    const ct = uefi.tables.ConfigurationTable;
    var rsdp: ?[*]const u8 = null;
    for (uefi.system_table.configuration_table[0..uefi.system_table.number_of_table_entries]) |entry| {
        if (entry.vendor_guid.eql(ct.acpi_20_table_guid)) {
            rsdp = @ptrCast(entry.vendor_table);
            break;
        }
        if (entry.vendor_guid.eql(ct.acpi_10_table_guid)) rsdp = @ptrCast(entry.vendor_table);
    }
    const root = rsdp orelse return error.NoAcpi;
    if (!std.mem.eql(u8, root[0..8], "RSD PTR ") or !checksum(root[0..20])) return error.InvalidRsdp;
    var root_address: u64 = read(u32, root[0..20], 16);
    var stride: usize = 4;
    if (root[15] >= 2) {
        const length = read(u32, root[0..36], 20);
        if (length < 36 or length > 4096 or !checksum(root[0..length])) return error.InvalidRsdp;
        const xsdt = read(u64, root[0..36], 24);
        if (xsdt != 0) {
            root_address = xsdt;
            stride = 8;
        }
    }
    const directory = try table(root_address);
    const signature: []const u8 = if (stride == 8) "XSDT" else "RSDT";
    if (!std.mem.eql(u8, directory[0..4], signature) or (directory.len - 36) % stride != 0) return error.InvalidAcpiDirectory;
    var offset: usize = 36;
    while (offset < directory.len) : (offset += stride) {
        const address = if (stride == 8) read(u64, directory, offset) else read(u32, directory, offset);
        const bytes = try table(address);
        if (std.mem.eql(u8, bytes[0..4], "APIC")) return parseMadt(bytes);
    }
    return error.NoMadt;
}
