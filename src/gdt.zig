const std = @import("std");

pub const GdtEntry = packed struct(u64) {
    limit_low: u16,
    base_low: u16,
    base_mid: u8,
    access: u8,
    limit_high: u4,
    flags: u4,
    base_high: u8,

    pub const NULL: GdtEntry = @bitCast(@as(u64, 0));

    pub fn makeCodeSegment(dpl: u2) GdtEntry {
        const dpl_val: u8 = @as(u8, dpl) << 5;
        return GdtEntry{
            .limit_low = 0xFFFF,
            .base_low = 0,
            .base_mid = 0,
            // Present (0x80) | DPL | Non-system (0x10) | Executable (0x08) | Readable (0x02)
            .access = 0x9A | dpl_val,
            .limit_high = 0xF,
            // Long Mode 64-bit (0x2) | Granularity 4KB (0x8) -> 0xA
            .flags = 0xA,
            .base_high = 0,
        };
    }

    pub fn makeDataSegment(dpl: u2) GdtEntry {
        const dpl_val: u8 = @as(u8, dpl) << 5;
        return GdtEntry{
            .limit_low = 0xFFFF,
            .base_low = 0,
            .base_mid = 0,
            // Present (0x80) | DPL | Non-system (0x10) | Writable (0x02)
            .access = 0x92 | dpl_val,
            .limit_high = 0xF,
            // Granularity 4KB (0x8)
            .flags = 0x8,
            .base_high = 0,
        };
    }
};

pub const Gdtr = packed struct {
    limit: u16,
    base: u64,
};

pub const KERNEL_CS: u16 = 0x08;
pub const KERNEL_DS: u16 = 0x10;
pub const USER_CS: u16 = 0x18 | 3;
pub const USER_DS: u16 = 0x20 | 3;

pub const GdtTable = struct {
    entries: [5]GdtEntry,

    pub fn init() GdtTable {
        return .{
            .entries = [5]GdtEntry{
                GdtEntry.NULL, // 0x00: Null descriptor
                GdtEntry.makeCodeSegment(0), // 0x08: Kernel CS
                GdtEntry.makeDataSegment(0), // 0x10: Kernel DS
                GdtEntry.makeCodeSegment(3), // 0x18: User CS
                GdtEntry.makeDataSegment(3), // 0x20: User DS
            },
        };
    }

    pub fn getDescriptor(self: *const GdtTable) Gdtr {
        return .{
            .limit = @as(u16, @sizeOf([5]GdtEntry) - 1),
            .base = @intFromPtr(&self.entries),
        };
    }
};

test "GDT layout and selectors" {
    const gdt = GdtTable.init();
    try std.testing.expectEqual(@as(u64, 0), @as(u64, @bitCast(gdt.entries[0])));

    // Kernel Code: Executable, Readable, Present, Long Mode
    const kcs = gdt.entries[1];
    try std.testing.expect((kcs.access & 0x80) != 0); // Present
    try std.testing.expect((kcs.access & 0x08) != 0); // Executable
    try std.testing.expect((kcs.flags & 0x2) != 0); // Long mode (L-bit)

    // Kernel Data: Writable, Present, Not Executable
    const kds = gdt.entries[2];
    try std.testing.expect((kds.access & 0x80) != 0); // Present
    try std.testing.expect((kds.access & 0x08) == 0); // Not Executable
    try std.testing.expect((kds.access & 0x02) != 0); // Writable

    const desc = gdt.getDescriptor();
    try std.testing.expectEqual(@as(u16, 39), desc.limit); // 5 * 8 - 1 = 39
}
