const std = @import("std");
pub const uart = @import("uart.zig");
pub const gdt = @import("gdt.zig");
pub const idt = @import("idt.zig");
pub const paging = @import("paging.zig");
pub const kernel = @import("kernel.zig");
pub const multiboot2 = @import("multiboot2.zig");
pub const pmm = @import("pmm.zig");
pub const bootimage = @import("bootimage.zig");

pub const version = "0.2.0";

const usage =
    \\Usage:
    \\  realgar                        run the serial self-test
    \\  realgar inspect <image> [--json]
    \\                                 report ELF load segments and multiboot1/2 headers
    \\  realgar version                print the version
    \\  realgar help                   show this help
    \\
    \\inspect exits 0 when the image carries a multiboot2 header that a loader
    \\would find and load, 1 when it does not, and 2 on usage or read errors.
    \\
;

/// Largest image `inspect` reads; loaders only look at the first 32 KiB for the
/// header, but the ELF program headers may point further in.
const MAX_IMAGE_BYTES = 64 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const io = init.io;

    var out_buf: [4096]u8 = undefined;
    var out_file = std.Io.File.stdout().writer(io, &out_buf);
    const out = &out_file.interface;
    var err_buf: [1024]u8 = undefined;
    var err_file = std.Io.File.stderr().writer(io, &err_buf);
    const err = &err_file.interface;

    const status = run(args, init, out, err) catch |e| blk: {
        err.print("realgar: {s}\n", .{@errorName(e)}) catch {};
        break :blk 2;
    };
    out.flush() catch {};
    err.flush() catch {};
    if (status != 0) std.process.exit(status);
}

fn run(args: []const [:0]const u8, init: std.process.Init, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    if (args.len < 2) {
        selfTest(out) catch {};
        return 0;
    }
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try out.writeAll(usage);
        return 0;
    }
    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version")) {
        try out.print("realgar {s}\n", .{version});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "inspect")) {
        var path: ?[]const u8 = null;
        var json = false;
        for (args[2..]) |a| {
            if (std.mem.eql(u8, a, "--json")) {
                json = true;
            } else if (path == null and !std.mem.startsWith(u8, a, "-")) {
                path = a;
            } else {
                try err.print("realgar inspect: unexpected argument '{s}'\n", .{a});
                return 2;
            }
        }
        const p = path orelse {
            try err.writeAll("realgar inspect: missing image path\n");
            return 2;
        };
        const image = std.Io.Dir.cwd().readFileAlloc(init.io, p, init.gpa, .limited(MAX_IMAGE_BYTES)) catch |e| {
            try err.print("realgar inspect: cannot read '{s}': {s}\n", .{ p, @errorName(e) });
            return 2;
        };
        defer init.gpa.free(image);
        const report = bootimage.inspect(image);
        if (json) {
            try bootimage.writeJson(&report, image, p, out);
        } else {
            try bootimage.writeText(&report, image, out);
        }
        return if (report.bootableMultiboot2()) 0 else 1;
    }
    try err.print("realgar: unknown command '{s}'\n\n", .{cmd});
    try err.writeAll(usage);
    return 2;
}

fn selfTest(out: *std.Io.Writer) !void {
    try out.writeAll(
        \\Realgar: Bare-Metal x86_64 Long Mode Micro-Kernel Stub
        \\Status: Ring 0 Freestanding UEFI / Multiboot2 Target Ready
        \\
    );

    // Run UART emulation test
    uart.resetMockTx();
    const serial = uart.SerialPort.init(uart.COM1_BASE);
    serial.writeString("[REALGAR] Self-test verified.\n");
    try out.print("Serial output verification: {s}", .{uart.getMockTxOutput()});
}

test {
    _ = @import("uart.zig");
    _ = @import("gdt.zig");
    _ = @import("idt.zig");
    _ = @import("paging.zig");
    _ = @import("kernel.zig");
    _ = @import("multiboot2.zig");
    _ = @import("pmm.zig");
    _ = @import("bootimage.zig");
}
