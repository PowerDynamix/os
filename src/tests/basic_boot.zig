const std = @import("std");
const uefi = std.os.uefi;

const fb = @import("os_kernel").framebuffer;
const test_runner = @import("test_runner.zig");

const serial = @import("serial.zig");

/// Basic boot test.
///
/// Success means:
///   1. UEFI gave us a system table.
///   2. Boot Services are available.
///   3. Graphics Output Protocol can be acquired.
///   4. A framebuffer can be initialized.
///   5. The UEFI memory map can be retrieved.
///   6. ExitBootServices succeeds.
///   7. We reach the post-ExitBootServices point.
///
/// Failure means QEMU exits with a non-zero status.
pub fn main() uefi.Status {
    // -------------------------------------------------------------------------
    // UEFI services
    // -------------------------------------------------------------------------
    serial.initSerial();

    const boot_services = uefi.system_table.boot_services orelse {
        test_runner.exitQemu(test_runner.QemuExitCode.Failed);
    };

    // -------------------------------------------------------------------------
    // Test GOP
    // -------------------------------------------------------------------------

    _ = fb.get_gop() catch {
        test_runner.exitQemu(test_runner.QemuExitCode.Failed);
    };

    // -------------------------------------------------------------------------
    // Test framebuffer initialization
    // -------------------------------------------------------------------------

    _ = fb.fetch_framebuffer() catch {
        test_runner.exitQemu(test_runner.QemuExitCode.Failed);
    };

    // -------------------------------------------------------------------------
    // Test memory map
    // -------------------------------------------------------------------------

    var buffer: [16 * 1024]u8 align(@alignOf(uefi.tables.MemoryDescriptor)) = undefined;

    const memory_map = boot_services.getMemoryMap(&buffer) catch {
        test_runner.exitQemu(test_runner.QemuExitCode.Failed);
    };

    const map_key = memory_map.info.key;

    // -------------------------------------------------------------------------
    // Exit UEFI Boot Services
    // -------------------------------------------------------------------------

    boot_services.exitBootServices(uefi.handle, map_key) catch {
        test_runner.exitQemu(test_runner.QemuExitCode.Failed);
    };

    serial.writeString("Exited boot services!\r\n");

    // -------------------------------------------------------------------------
    // If we get here, basic boot succeeded.
    // -------------------------------------------------------------------------
    test_runner.exitQemu(test_runner.QemuExitCode.Success);
}
