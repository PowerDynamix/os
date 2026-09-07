const std = @import("std");

const TestCase = struct {
    name: []const u8,
    source: []const u8,
};
const tests = [_]TestCase{
    .{
        .name = "basic-boot",
        .source = "src/tests/basic_boot.zig",
    },
    .{
        .name = "serial-test",
        .source = "src/tests/serial_test.zig",
    },
};

pub fn build(b: *std.Build) void {
    // Config
    const target = b.standardTargetOptions(.{ .default_target = .{
        .cpu_arch = .x86_64,
        .os_tag = .uefi,
        .abi = .none,
    } });
    const optimize = b.standardOptimizeOption(.{});

    const kernel = b.addExecutable(.{
        .name = "BOOTX64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    kernel.subsystem = .efi_application;

    const install_step = b.addInstallArtifact(kernel, .{ .dest_dir = .{ .override = .bin } });

    // Run

    const cp_cmd = b.addSystemCommand(&.{ "cp", "zig-out/bin/BOOTX64.efi", "build/disk/EFI/BOOT/BOOTX64.EFI" });
    cp_cmd.step.dependOn(&install_step.step);

    const run_cmd = b.addSystemCommand(&.{ "qemu-system-x86_64", "-serial", "stdio", "-bios", "/usr/share/edk2-ovmf/x64/OVMF.4m.fd", "-drive", "format=raw,file=fat:rw:build/disk", "-display", "gtk" });
    run_cmd.step.dependOn(&cp_cmd.step);
    run_cmd.step.dependOn(&install_step.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&cp_cmd.step);
    run_step.dependOn(&run_cmd.step);

    // Tests
    const test_step = b.step("test", "Run each unit test in QEMU");

    for (tests) |t| {
        addQemuTest(
            b,
            test_step,
            t,
            target,
            optimize,
        );
    }
}

fn addQemuTest(
    b: *std.Build,
    test_step: *std.Build.Step,
    t: TestCase,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const test_efi = b.addExecutable(.{
        .name = t.name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(t.source),
            .target = target,
            .optimize = optimize,
        }),
    });

    test_efi.subsystem = .efi_application;

    test_efi.root_module.addImport("os_kernel", b.createModule(.{
        .root_source_file = b.path("./src/root.zig"),
    }));

    const install_step = b.addInstallArtifact(test_efi, .{ .dest_dir = .{ .override = .bin } });

    const efi_dir = b.fmt(
        "build/test-disk-{s}/EFI/BOOT",
        .{t.name},
    );

    const mkdir = b.addSystemCommand(&.{
        "mkdir",
        "-p",
        efi_dir,
    });

    mkdir.step.dependOn(&install_step.step);

    const copy = b.addSystemCommand(&.{
        "cp",
        b.fmt("zig-out/bin/{s}.efi", .{t.name}),
        b.fmt("{s}/BOOTX64.EFI", .{efi_dir}),
    });

    copy.step.dependOn(&install_step.step);
    copy.step.dependOn(&mkdir.step);

    const serial_log = b.fmt(
        "build/test-disk-{s}/serial-log.txt",
        .{t.name},
    );

    const qemu = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-serial",
        b.fmt("file:{s}", .{serial_log}),
        "-bios",
        "/usr/share/edk2-ovmf/x64/OVMF.4m.fd",
        "-drive",
        b.fmt(
            "format=raw,file=fat:rw:build/test-disk-{s}",
            .{t.name},
        ),
        "-display",
        "none",
        "-device",
        "isa-debug-exit,iobase=0xf4,iosize=0x04",
    });

    qemu.expectExitCode(33);

    qemu.step.dependOn(&install_step.step);
    qemu.step.dependOn(&copy.step);

    const step = b.step(
        b.fmt("test-{s}", .{t.name}),
        b.fmt("Run {s} in QEMU", .{t.name}),
    );

    step.dependOn(&qemu.step);

    // Make the aggregate `test` command run this test.
    test_step.dependOn(step);
}
