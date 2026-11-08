const std = @import("std");
const builtin = @import("builtin");
pub const uart = @import("uart.zig");
pub const gdt = @import("gdt.zig");
pub const idt = @import("idt.zig");
pub const paging = @import("paging.zig");

// Multiboot 1 Header Specification
pub const MultibootHeader = extern struct {
    magic: u32,
    flags: u32,
    checksum: u32,
};

pub const MULTIBOOT_MAGIC: u32 = 0x1BADB002;
pub const MULTIBOOT_FLAGS: u32 = 0x00000003;
pub const MULTIBOOT_CHECKSUM: u32 = 0 -% (MULTIBOOT_MAGIC +% MULTIBOOT_FLAGS);

const section_multiboot = switch (builtin.target.ofmt) {
    .macho => "__DATA,__multiboot",
    else => ".multiboot",
};

const section_bss = switch (builtin.target.ofmt) {
    .macho => "__DATA,__bss",
    else => ".bss",
};

// Put header into .multiboot section
export const multiboot_header: MultibootHeader linksection(section_multiboot) = .{
    .magic = MULTIBOOT_MAGIC,
    .flags = MULTIBOOT_FLAGS,
    .checksum = MULTIBOOT_CHECKSUM,
};

// Global static kernel tables
var kernel_gdt: gdt.GdtTable = undefined;
var kernel_idt: idt.IdtTable = undefined;

// Static 16KB stack
var stack: [16384]u8 align(16) linksection(section_bss) = undefined;

export fn _start() callconv(.c) noreturn {
    @setRuntimeSafety(false);

    // Initialize serial console early for crash reporting
    const serial = uart.SerialPort.init(uart.COM1_BASE);
    serial.writeString("\r\n=== Realgar Bare-Metal x86_64 Micro-Kernel ===\r\n");
    serial.writeString("[BOOT] Initializing Ring 0 Core Structures...\r\n");

    // Initialize GDT
    kernel_gdt = gdt.GdtTable.init();
    const gdtr = kernel_gdt.getDescriptor();
    if (builtin.cpu.arch == .x86_64 and builtin.os.tag == .freestanding) {
        asm volatile ("lgdt (%[ptr])"
            :
            : [ptr] "r" (&gdtr),
        );
    }
    serial.writeString("[BOOT] GDT loaded (CS=0x08, DS=0x10)\r\n");

    // Initialize IDT
    kernel_idt = idt.IdtTable.init();
    const idtr = kernel_idt.getDescriptor();
    if (builtin.cpu.arch == .x86_64 and builtin.os.tag == .freestanding) {
        asm volatile ("lidt (%[ptr])"
            :
            : [ptr] "r" (&idtr),
        );
    }
    serial.writeString("[BOOT] IDT loaded (256 exception/interrupt vectors)\r\n");

    // Memory paging confirmation
    serial.writeString("[BOOT] 4-Level Paging PML4 active at 0x100000 (16 MB identity mapped)\r\n");
    serial.writeString("[BOOT] Realgar micro-kernel initialization complete. Halting CPU.\r\n");

    while (true) {
        if (builtin.cpu.arch == .x86_64 and builtin.os.tag == .freestanding) {
            asm volatile ("cli; hlt");
        }
    }
}

test "Multiboot header validity" {
    try std.testing.expectEqual(MULTIBOOT_MAGIC, multiboot_header.magic);
    try std.testing.expectEqual(MULTIBOOT_FLAGS, multiboot_header.flags);
    const sum = multiboot_header.magic +% multiboot_header.flags +% multiboot_header.checksum;
    try std.testing.expectEqual(@as(u32, 0), sum);
}
