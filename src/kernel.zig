const std = @import("std");
const builtin = @import("builtin");
pub const uart = @import("uart.zig");
pub const gdt = @import("gdt.zig");
pub const idt = @import("idt.zig");
pub const paging = @import("paging.zig");
pub const multiboot2 = @import("multiboot2.zig");
pub const pmm = @import("pmm.zig");

const is_bare_metal = builtin.cpu.arch == .x86_64 and builtin.os.tag == .freestanding;

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

// Multiboot2 header in the same section; the loader scans the first 32 KiB of
// the image for it at 8-byte alignment.
export const multiboot2_header: multiboot2.KernelHeader align(8) linksection(section_multiboot) = multiboot2.KernelHeader.make();

// Global static kernel tables
var kernel_gdt: gdt.GdtTable = undefined;
var kernel_idt: idt.IdtTable = undefined;

// Static 16KB stack
var stack: [16384]u8 align(16) linksection(section_bss) = undefined;

/// Highest physical address the frame bitmap describes (4 GiB).
pub const MAX_TRACKED_BYTES: u64 = 4 * 1024 * 1024 * 1024;
/// Bytes identity mapped (and aliased at KERNEL_VMA_BASE) by the early page tables.
pub const EARLY_MAP_BYTES: u64 = paging.PAGE_SIZE_1G;

var frame_bitmap: [pmm.wordsForFrames(MAX_TRACKED_BYTES / pmm.FRAME_SIZE)]u64 = undefined;
var frame_allocator: pmm.BitmapAllocator = undefined;
const EarlyPool = paging.TablePool(8);
var early_tables: EarlyPool = .{};

pub const BootReport = struct {
    mmap_entries: usize,
    total_frames: u64,
    free_frames: u64,
    tables_used: usize,
    identity_2m_pages: usize,
    higher_half_2m_pages: usize,
    pml4_phys: u64,
};

fn writeRange(serial: *const uart.SerialPort, base: u64, end: u64) void {
    serial.writeHexU64(base);
    serial.writeString("-");
    serial.writeHexU64(end);
}

/// Consumes the multiboot2 boot information: prints the memory map, builds the
/// physical frame allocator from it, and builds identity plus higher-half page
/// tables in a static pool, checking both views by walking them. The tables are
/// not loaded into CR3 here. `kernel` is the physical range of the kernel image
/// (including .bss), which is never handed out as free memory.
pub fn bootstrap(serial: *const uart.SerialPort, magic: u64, info_addr: usize, kernel: pmm.Range) ?BootReport {
    if (magic != multiboot2.BOOTLOADER_MAGIC) {
        serial.writeString("[BOOT] No multiboot2 boot information (magic=");
        serial.writeHexU64(magic);
        serial.writeString(")\n");
        return null;
    }
    const info = multiboot2.BootInfo.fromAddress(info_addr) catch |err| {
        serial.writeString("[BOOT] Rejected multiboot2 boot information: ");
        serial.writeString(@errorName(err));
        serial.writeString("\n");
        return null;
    };
    if (info.bootloaderName()) |name| {
        serial.writeString("[BOOT] Loader: ");
        serial.writeString(name);
        serial.writeString("\n");
    }
    if (info.commandLine()) |cmdline| {
        serial.writeString("[BOOT] Command line: ");
        serial.writeString(cmdline);
        serial.writeString("\n");
    }
    const map = info.memoryMap() orelse {
        serial.writeString("[MEM] Loader supplied no memory map\n");
        return null;
    };
    var it = map.iterator();
    while (it.next()) |r| {
        serial.writeString("[MEM] ");
        writeRange(serial, r.base, r.end());
        serial.writeString(" ");
        serial.writeString(r.kind.name());
        serial.writeString("\n");
    }

    const reserved = [_]pmm.Range{
        .{ .base = 0, .length = 0x100000 }, // real-mode IVT, BIOS data, EBDA, VGA, option ROMs
        kernel,
        .{ .base = info_addr, .length = info.totalSize() },
    };
    frame_allocator = pmm.BitmapAllocator.fromMemoryMap(&frame_bitmap, map, &reserved);
    const st = frame_allocator.stats();
    serial.writeString("[MEM] Frames tracked: ");
    serial.writeDecU64(st.total_frames);
    serial.writeString(", free: ");
    serial.writeDecU64(st.free_frames);
    serial.writeString(" (");
    serial.writeDecU64(st.free_frames * pmm.FRAME_SIZE / 1024);
    serial.writeString(" KiB)\n");

    early_tables = .{ .phys_base = @intFromPtr(&early_tables.tables[0]) };
    var space = paging.AddressSpace(EarlyPool).init(&early_tables) catch unreachable;
    const layout = paging.buildKernelLayout(EarlyPool, &space, EARLY_MAP_BYTES, false) catch |err| {
        serial.writeString("[PAGING] Layout failed: ");
        serial.writeString(@errorName(err));
        serial.writeString("\n");
        return null;
    };
    const low = space.translate(kernel.base);
    const high = space.translate(paging.KERNEL_VMA_BASE + kernel.base);
    if (low == null or high == null or low.?.phys != kernel.base or high.?.phys != kernel.base) {
        serial.writeString("[PAGING] Translation check failed\n");
        return null;
    }
    serial.writeString("[PAGING] PML4 at ");
    serial.writeHexU64(space.root);
    serial.writeString(": identity and higher-half views of ");
    serial.writeDecU64(EARLY_MAP_BYTES / (1024 * 1024));
    serial.writeString(" MiB in ");
    serial.writeDecU64(early_tables.used);
    serial.writeString(" tables\n");

    return .{
        .mmap_entries = map.count(),
        .total_frames = st.total_frames,
        .free_frames = st.free_frames,
        .tables_used = early_tables.used,
        .identity_2m_pages = layout.identity.pages_2m,
        .higher_half_2m_pages = layout.higher_half.pages_2m,
        .pml4_phys = space.root,
    };
}

fn kernelImageRange() pmm.Range {
    if (!is_bare_metal) return .{ .base = 0, .length = 0 };
    const start = @intFromPtr(@extern(*const u8, .{ .name = "__kernel_start" }));
    const end = @intFromPtr(@extern(*const u8, .{ .name = "__kernel_end" }));
    return .{ .base = start, .length = end - start };
}

// The entry symbol is only exported for the freestanding kernel image. Hosted
// builds (unit tests, the CLI) get `_start` from the C runtime or std, and a
// second definition would collide at link time.
comptime {
    if (is_bare_metal) @export(&kernelEntry, .{ .name = "_start" });
}

/// Entry point, exported as `_start`. Follows the System V convention: a 64-bit
/// loader trampoline passes the multiboot2 magic in RDI and the boot
/// information address in RSI.
fn kernelEntry(mb_magic: u64, mb_info: u64) callconv(.c) noreturn {
    @setRuntimeSafety(false);

    // Initialize serial console early for crash reporting
    const serial = uart.SerialPort.init(uart.COM1_BASE);
    serial.writeString("\r\n=== Realgar Bare-Metal x86_64 Micro-Kernel ===\r\n");
    serial.writeString("[BOOT] Initializing Ring 0 Core Structures...\r\n");

    // Initialize GDT
    kernel_gdt = gdt.GdtTable.init();
    const gdtr = kernel_gdt.getDescriptor();
    if (is_bare_metal) {
        asm volatile ("lgdt (%[ptr])"
            :
            : [ptr] "r" (&gdtr),
        );
    }
    serial.writeString("[BOOT] GDT loaded (CS=0x08, DS=0x10)\r\n");

    // Initialize IDT
    kernel_idt = idt.IdtTable.init();
    const idtr = kernel_idt.getDescriptor();
    if (is_bare_metal) {
        asm volatile ("lidt (%[ptr])"
            :
            : [ptr] "r" (&idtr),
        );
    }
    serial.writeString("[BOOT] IDT loaded (256 exception/interrupt vectors)\r\n");

    _ = bootstrap(&serial, mb_magic, @intCast(mb_info), kernelImageRange());

    serial.writeString("[BOOT] Realgar micro-kernel initialization complete. Halting CPU.\r\n");

    while (true) {
        if (is_bare_metal) {
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

test "Multiboot2 header is embedded and valid" {
    const s = try multiboot2.validateHeader(std.mem.asBytes(&multiboot2_header), 0);
    try std.testing.expectEqual(@as(u32, 48), s.header_length);
}

test "bootstrap builds allocator and page tables from boot information" {
    var buf: [512]u8 align(8) = undefined;
    var b = try multiboot2.InfoBuilder.init(&buf);
    try b.addString(.boot_loader_name, "GRUB 2.12");
    try b.addString(.cmdline, "realgar.debug=1");
    try b.addMemoryMap(&.{
        .{ .base = 0, .length = 0x9FC00, .kind = .available },
        .{ .base = 0x9FC00, .length = 0x400, .kind = .reserved },
        .{ .base = 0xF0000, .length = 0x10000, .kind = .reserved },
        .{ .base = 0x100000, .length = 0x7F00000, .kind = .available }, // up to 128 MiB
        .{ .base = 0xFFFC0000, .length = 0x40000, .kind = .reserved },
    });
    const bytes = try b.finish();

    uart.resetMockTx();
    const serial = uart.SerialPort.init(uart.COM1_BASE);
    const kernel_range = pmm.Range{ .base = 0x100000, .length = 0x40000 };
    const report = bootstrap(&serial, multiboot2.BOOTLOADER_MAGIC, @intFromPtr(bytes.ptr), kernel_range).?;

    try std.testing.expectEqual(@as(usize, 5), report.mmap_entries);
    try std.testing.expectEqual(@as(u64, 0x8000), report.total_frames);
    // 1 MiB..128 MiB is 0x7F00 frames; the kernel takes 0x40 of them. The boot
    // information buffer lives in host memory far above 128 MiB, so it removes nothing.
    try std.testing.expectEqual(@as(u64, 0x7F00 - 0x40), report.free_frames);
    try std.testing.expectEqual(@as(usize, 512), report.identity_2m_pages);
    try std.testing.expectEqual(@as(usize, 512), report.higher_half_2m_pages);
    try std.testing.expectEqual(@as(usize, 5), report.tables_used);
    try std.testing.expectEqual(@as(?u64, 0x140000), frame_allocator.alloc());

    const out = uart.getMockTxOutput();
    try std.testing.expect(std.mem.indexOf(u8, out, "[BOOT] Loader: GRUB 2.12\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[BOOT] Command line: realgar.debug=1\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[MEM] 0x0000000000100000-0x0000000008000000 available\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[MEM] Frames tracked: 32768, free: 32448 (129792 KiB)\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "identity and higher-half views of 1024 MiB in 5 tables\r\n") != null);
}

test "bootstrap refuses a wrong magic or a corrupted structure" {
    uart.resetMockTx();
    const serial = uart.SerialPort.init(uart.COM1_BASE);
    try std.testing.expect(bootstrap(&serial, 0x2BADB002, 0, .{ .base = 0, .length = 0 }) == null);
    try std.testing.expect(std.mem.indexOf(u8, uart.getMockTxOutput(), "No multiboot2 boot information") != null);

    var buf: [64]u8 align(8) = undefined;
    var b = try multiboot2.InfoBuilder.init(&buf);
    try b.addString(.cmdline, "x");
    const bytes = try b.finish();
    std.mem.writeInt(u32, bytes[12..16], 3, .little); // tag size below 8
    uart.resetMockTx();
    try std.testing.expect(bootstrap(&serial, multiboot2.BOOTLOADER_MAGIC, @intFromPtr(bytes.ptr), .{ .base = 0, .length = 0 }) == null);
    try std.testing.expect(std.mem.indexOf(u8, uart.getMockTxOutput(), "Rejected multiboot2 boot information: TagTooSmall") != null);

    // A structure without a memory map is accepted but stops before the allocator.
    b = try multiboot2.InfoBuilder.init(&buf);
    try b.addString(.cmdline, "x");
    const no_map = try b.finish();
    uart.resetMockTx();
    try std.testing.expect(bootstrap(&serial, multiboot2.BOOTLOADER_MAGIC, @intFromPtr(no_map.ptr), .{ .base = 0, .length = 0 }) == null);
    try std.testing.expect(std.mem.indexOf(u8, uart.getMockTxOutput(), "no memory map") != null);
}
