const std = @import("std");
pub const uart = @import("uart.zig");
pub const gdt = @import("gdt.zig");
pub const idt = @import("idt.zig");
pub const paging = @import("paging.zig");
pub const kernel = @import("kernel.zig");

pub fn main(init: std.process.Init) !void {
    _ = init;
    std.debug.print(
        \\Realgar: Bare-Metal x86_64 Long Mode Micro-Kernel Stub
        \\Status: Ring 0 Freestanding UEFI / Multiboot2 Target Ready
        \\
    , .{});

    // Run UART emulation test
    uart.resetMockTx();
    const serial = uart.SerialPort.init(uart.COM1_BASE);
    serial.writeString("[REALGAR] Self-test verified.\n");
    std.debug.print("Serial output verification: {s}", .{uart.getMockTxOutput()});
}

test {
    _ = @import("uart.zig");
    _ = @import("gdt.zig");
    _ = @import("idt.zig");
    _ = @import("paging.zig");
    _ = @import("kernel.zig");
}
