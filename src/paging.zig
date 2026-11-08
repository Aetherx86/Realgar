const std = @import("std");

pub const PAGE_SIZE_4K: u64 = 4096;
pub const PAGE_SIZE_2M: u64 = 2 * 1024 * 1024;
pub const PAGE_SIZE_1G: u64 = 1024 * 1024 * 1024;

pub const PageFlags = struct {
    pub const PRESENT: u64 = 1 << 0;
    pub const WRITABLE: u64 = 1 << 1;
    pub const USER_ACCESSIBLE: u64 = 1 << 2;
    pub const WRITE_THROUGH: u64 = 1 << 3;
    pub const CACHE_DISABLE: u64 = 1 << 4;
    pub const ACCESSED: u64 = 1 << 5;
    pub const DIRTY: u64 = 1 << 6;
    pub const HUGE_PAGE: u64 = 1 << 7;
    pub const GLOBAL: u64 = 1 << 8;
    pub const NO_EXECUTE: u64 = 1 << 63;
};

pub inline fn pml4Index(vaddr: u64) usize {
    return @as(usize, @intCast((vaddr >> 39) & 0x1FF));
}

pub inline fn pdptIndex(vaddr: u64) usize {
    return @as(usize, @intCast((vaddr >> 30) & 0x1FF));
}

pub inline fn pdIndex(vaddr: u64) usize {
    return @as(usize, @intCast((vaddr >> 21) & 0x1FF));
}

pub inline fn ptIndex(vaddr: u64) usize {
    return @as(usize, @intCast((vaddr >> 12) & 0x1FF));
}

pub inline fn pageOffset(vaddr: u64) usize {
    return @as(usize, @intCast(vaddr & 0xFFF));
}

pub const PageTable = struct {
    entries: [512]u64 align(4096),

    pub fn init() PageTable {
        var table: PageTable = undefined;
        @memset(&table.entries, 0);
        return table;
    }

    pub fn clear(self: *PageTable) void {
        @memset(&self.entries, 0);
    }

    pub fn setEntry(self: *PageTable, index: usize, phys_addr: u64, flags: u64) void {
        std.debug.assert(index < 512);
        self.entries[index] = (phys_addr & 0x000F_FFFF_FFFF_F000) | (flags & 0xFFF0_0000_0000_0FFF);
    }

    pub fn getEntry(self: *const PageTable, index: usize) u64 {
        std.debug.assert(index < 512);
        return self.entries[index];
    }
};

pub const IdentityPagingContext = struct {
    pml4: PageTable,
    pdpt: PageTable,
    pd: PageTable,

    pub fn initIdentity(pml4_phys: u64, pdpt_phys: u64, pd_phys: u64, num_2mb_pages: usize) IdentityPagingContext {
        _ = pml4_phys;
        var ctx = IdentityPagingContext{
            .pml4 = PageTable.init(),
            .pdpt = PageTable.init(),
            .pd = PageTable.init(),
        };

        // PML4[0] points to PDPT
        ctx.pml4.setEntry(0, pdpt_phys, PageFlags.PRESENT | PageFlags.WRITABLE);

        // PDPT[0] points to PD
        ctx.pdpt.setEntry(0, pd_phys, PageFlags.PRESENT | PageFlags.WRITABLE);

        // Map first N 2MB huge pages
        const pages = if (num_2mb_pages > 512) 512 else num_2mb_pages;
        for (0..pages) |i| {
            const phys = @as(u64, i) * PAGE_SIZE_2M;
            ctx.pd.setEntry(i, phys, PageFlags.PRESENT | PageFlags.WRITABLE | PageFlags.HUGE_PAGE);
        }

        return ctx;
    }
};

test "Virtual address decomposition" {
    // Canonical higher-half kernel address
    const kernel_base: u64 = 0xFFFFFFFF80000000;
    try std.testing.expectEqual(@as(usize, 511), pml4Index(kernel_base));
    try std.testing.expectEqual(@as(usize, 510), pdptIndex(kernel_base));
    try std.testing.expectEqual(@as(usize, 0), pdIndex(kernel_base));
    try std.testing.expectEqual(@as(usize, 0), ptIndex(kernel_base));

    // Low address: 1MB boundary
    const one_mb: u64 = 0x100000;
    try std.testing.expectEqual(@as(usize, 0), pml4Index(one_mb));
    try std.testing.expectEqual(@as(usize, 0), pdptIndex(one_mb));
    try std.testing.expectEqual(@as(usize, 0), pdIndex(one_mb));
    try std.testing.expectEqual(@as(usize, 256), ptIndex(one_mb)); // 0x100000 / 4096 = 256
    try std.testing.expectEqual(@as(usize, 0), pageOffset(one_mb));
}

test "Identity paging context setup" {
    const ctx = IdentityPagingContext.initIdentity(0x10000, 0x11000, 0x12000, 8); // 8 * 2MB = 16MB

    // Verify PML4[0] -> PDPT
    const pml4_0 = ctx.pml4.getEntry(0);
    try std.testing.expect((pml4_0 & PageFlags.PRESENT) != 0);
    try std.testing.expect((pml4_0 & PageFlags.WRITABLE) != 0);
    try std.testing.expectEqual(@as(u64, 0x11000), pml4_0 & 0x000F_FFFF_FFFF_F000);

    // Verify PDPT[0] -> PD
    const pdpt_0 = ctx.pdpt.getEntry(0);
    try std.testing.expect((pdpt_0 & PageFlags.PRESENT) != 0);
    try std.testing.expectEqual(@as(u64, 0x12000), pdpt_0 & 0x000F_FFFF_FFFF_F000);

    // Verify first 8 PD entries (2MB huge pages)
    for (0..8) |i| {
        const pd_entry = ctx.pd.getEntry(i);
        try std.testing.expect((pd_entry & PageFlags.PRESENT) != 0);
        try std.testing.expect((pd_entry & PageFlags.HUGE_PAGE) != 0);
        const expected_phys = @as(u64, i) * PAGE_SIZE_2M;
        try std.testing.expectEqual(expected_phys, pd_entry & 0x000F_FFFF_FFFF_F000);
    }
}
