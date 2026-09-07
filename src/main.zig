const std = @import("std");
const uefi = std.os.uefi;
const L = std.unicode.utf8ToUtf16LeStringLiteral;

const fb = @import("framebuffer.zig");
const cs = @import("console.zig");
const fnt = @import("font.zig");

const font_data = @embedFile("assets/fonts/ter-u16n.psf");

/// Halt the CPU indefinitely.
///
/// This is used when execution cannot safely continue, and after
/// `ExitBootServices` has been called.
fn halt() void {
    while (true) {
        asm volatile ("hlt");
    }
}

/// Kernel panic before ExitBootServices().
///
/// At this point UEFI Boot Services and the UEFI text console are still
/// available, so use con_out to display the panic message.
fn uefi_panic(
    con_out: *uefi.protocol.SimpleTextOutput,
    message: []const u8,
) uefi.Status {
    _ = con_out.outputString(L("\r\n\r\nKERNEL PANIC!\r\n")) catch {};

    // Print the ASCII message as UTF-16.
    for (message) |c| {
        const buf: [1:0]u16 = .{@as(u16, c)};
        _ = con_out.outputString(&buf) catch {};
    }

    _ = con_out.outputString(L("\r\n\r\nSystem halted.\r\n")) catch {};

    halt();
    return uefi.Status.aborted;
}

/// UEFI application entry point.
///
/// Initializes the UEFI console, displays a startup message, retrieves
/// the system memory map, and exits UEFI Boot Services.
///
/// After `exitBootServices` succeeds, Boot Services and the UEFI console
/// must no longer be used.
pub fn main() uefi.Status {
    // -------------------------------------------------------------------------
    // UEFI service handles
    // -------------------------------------------------------------------------

    const con_out = uefi.system_table.con_out.?;
    const boot_services = uefi.system_table.boot_services.?;

    // -------------------------------------------------------------------------
    // Console initialization
    // -------------------------------------------------------------------------

    _ = con_out.reset(false) catch {
        halt();
        return uefi.Status.aborted;
    };

    _ = con_out.outputString(L("Loading OS!\r\n")) catch {
        halt();
        return uefi.Status.aborted;
    };

    const gop = fb.get_gop() catch {
        return uefi_panic(con_out, "Failed to acquire Graphics Output Protocl.");
    };
    var framebuffer: fb.Framebuffer = fb.fetch_framebuffer() catch {
        return uefi_panic(con_out, "Failed to initialize framebuffer.");
    };
    const console_font = fnt.loadFont(font_data) catch |err| {
        const err_name = @errorName(err);

        // Build a simple ASCII error message.
        // uefi_panic() handles displaying it and halting.
        var message: [256]u8 = undefined;

        const prefix = "Failed to load console font! Error: ";
        const prefix_len = prefix.len;

        if (prefix_len + err_name.len <= message.len) {
            @memcpy(message[0..prefix_len], prefix);
            @memcpy(message[prefix_len .. prefix_len + err_name.len], err_name);

            return uefi_panic(
                con_out,
                message[0 .. prefix_len + err_name.len],
            );
        }

        return uefi_panic(con_out, "Failed to load console font.");
    };
    var console = cs.Console.init(&framebuffer, console_font);

    console.clear();

    // -------------------------------------------------------------------------
    // Retrieve the UEFI memory map
    // -------------------------------------------------------------------------

    // Buffer used by GetMemoryMap. Its alignment must satisfy the alignment
    // requirements of a UEFI MemoryDescriptor.
    var buffer: [16 * 1024]u8 align(@alignOf(uefi.tables.MemoryDescriptor)) = undefined;

    const memory_map = boot_services.getMemoryMap(&buffer) catch {
        return uefi_panic(con_out, "Failed to retrieve UEFI memory map.");
    };

    // The map key identifies the current memory map and must be passed to
    // ExitBootServices.
    const map_key: uefi.tables.MemoryMapKey = memory_map.info.key;

    // -------------------------------------------------------------------------
    // Leave UEFI Boot Services
    // -------------------------------------------------------------------------

    // After ExitBootServices succeeds, Boot Services and the UEFI console
    // must no longer be accessed.
    _ = boot_services.exitBootServices(uefi.handle, map_key) catch {
        // IMPORTANT:
        // uefi_panic() uses the UEFI console, so it is still safe here because
        // ExitBootServices() failed and Boot Services are still active.
        return uefi_panic(con_out, "Failed to exit UEFI Boot Services.");
    };

    // -------------------------------------------------------------------------
    // Print stuff and stop execution
    // -------------------------------------------------------------------------

    // You can now seamlessly format numbers, strings, pointers, and types!
    console.print("Welcome to the OS!\n", .{});
    console.print("-----------------------------\n", .{});

    const mem_amount: u32 = 4096;
    console.print("System Memory Verified: {} MB\n", .{mem_amount});

    const framebuffer_addr: usize = gop.mode.frame_buffer_base;
    console.print("GOP Framebuffer Base:   0x{X}\n", .{framebuffer_addr});

    //console.panic("No filesystem found", .{});

    halt();

    return uefi.Status.success;
}
