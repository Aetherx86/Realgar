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

/// Physical address bits of a table or leaf entry (bits 12..51).
pub const ADDR_MASK: u64 = 0x000F_FFFF_FFFF_F000;
/// Highest physical address width the 4-level format can encode.
pub const MAX_PHYS_BITS: u6 = 52;
/// Base of the conventional higher-half kernel window (PML4 511, PDPT 510).
pub const KERNEL_VMA_BASE: u64 = 0xFFFF_FFFF_8000_0000;

pub const PageSize = enum {
    size_4k,
    size_2m,
    size_1g,

    pub fn bytes(self: PageSize) u64 {
        return switch (self) {
            .size_4k => PAGE_SIZE_4K,
            .size_2m => PAGE_SIZE_2M,
            .size_1g => PAGE_SIZE_1G,
        };
    }

    pub fn name(self: PageSize) []const u8 {
        return switch (self) {
            .size_4k => "4K",
            .size_2m => "2M",
            .size_1g => "1G",
        };
    }
};

/// True when bits 63..47 are all copies of bit 47.
pub fn isCanonical(vaddr: u64) bool {
    const top = vaddr >> 47;
    return top == 0 or top == 0x1FFFF;
}

pub const MapError = error{
    Misaligned,
    NonCanonical,
    PhysTooLarge,
    AlreadyMapped,
    OutOfTables,
    AddressOverflow,
};

pub const UnmapError = error{
    NotMapped,
    Misaligned,
    NonCanonical,
};

pub const Translation = struct {
    phys: u64,
    size: PageSize,
    /// Leaf entry flag bits (everything outside ADDR_MASK).
    flags: u64,
};

pub const RangeStats = struct {
    pages_4k: usize = 0,
    pages_2m: usize = 0,
    pages_1g: usize = 0,
};

/// Flags that callers may request on a leaf. HUGE_PAGE is managed internally,
/// and bit 7 of a 4 KiB entry is PAT, so it is never taken from the caller.
const LEAF_FLAG_MASK: u64 = PageFlags.WRITABLE | PageFlags.USER_ACCESSIBLE | PageFlags.WRITE_THROUGH |
    PageFlags.CACHE_DISABLE | PageFlags.GLOBAL | PageFlags.NO_EXECUTE;

/// A 4-level x86_64 address space built over a table backend.
///
/// `Backend` provides:
///   fn allocTable(self: *Backend) ?u64          physical address of a zeroed table
///   fn tableAt(self: *Backend, phys: u64) *PageTable
///
/// The kernel uses a pool whose physical and virtual addresses coincide; host
/// tests use a pool with synthetic physical addresses, so the exact same walk
/// code runs in both places.
pub fn AddressSpace(comptime Backend: type) type {
    return struct {
        const Self = @This();

        backend: *Backend,
        root: u64,

        pub fn init(backend: *Backend) MapError!Self {
            const root = backend.allocTable() orelse return error.OutOfTables;
            return .{ .backend = backend, .root = root };
        }

        fn table(self: *Self, phys: u64) *PageTable {
            return self.backend.tableAt(phys);
        }

        /// Returns the next-level table for `entry_index` of `t`, creating it if
        /// absent. Fails if the slot already holds a huge-page leaf.
        fn descend(self: *Self, t: *PageTable, entry_index: usize, user: bool) MapError!*PageTable {
            const e = t.entries[entry_index];
            if (e & PageFlags.PRESENT != 0) {
                if (e & PageFlags.HUGE_PAGE != 0) return error.AlreadyMapped;
                if (user and e & PageFlags.USER_ACCESSIBLE == 0) {
                    t.entries[entry_index] = e | PageFlags.USER_ACCESSIBLE;
                }
                return self.table(e & ADDR_MASK);
            }
            const phys = self.backend.allocTable() orelse return error.OutOfTables;
            var flags = PageFlags.PRESENT | PageFlags.WRITABLE;
            if (user) flags |= PageFlags.USER_ACCESSIBLE;
            t.entries[entry_index] = phys | flags;
            return self.table(phys);
        }

        fn checkArgs(virt: u64, phys: u64, size: PageSize) MapError!void {
            if (!isCanonical(virt)) return error.NonCanonical;
            const sz = size.bytes();
            if (virt % sz != 0 or phys % sz != 0) return error.Misaligned;
            if (phys >> MAX_PHYS_BITS != 0) return error.PhysTooLarge;
        }

        /// Maps one page of the given size. Never overwrites an existing mapping.
        pub fn map(self: *Self, virt: u64, phys: u64, size: PageSize, flags: u64) MapError!void {
            try checkArgs(virt, phys, size);
            const user = flags & PageFlags.USER_ACCESSIBLE != 0;
            const leaf_flags = (flags & LEAF_FLAG_MASK) | PageFlags.PRESENT;

            const pml4 = self.table(self.root);
            const pdpt = try self.descend(pml4, pml4Index(virt), user);
            if (size == .size_1g) {
                const i = pdptIndex(virt);
                if (pdpt.entries[i] & PageFlags.PRESENT != 0) return error.AlreadyMapped;
                pdpt.entries[i] = phys | leaf_flags | PageFlags.HUGE_PAGE;
                return;
            }
            const pd = try self.descend(pdpt, pdptIndex(virt), user);
            if (size == .size_2m) {
                const i = pdIndex(virt);
                if (pd.entries[i] & PageFlags.PRESENT != 0) return error.AlreadyMapped;
                pd.entries[i] = phys | leaf_flags | PageFlags.HUGE_PAGE;
                return;
            }
            const pt = try self.descend(pd, pdIndex(virt), user);
            const i = ptIndex(virt);
            if (pt.entries[i] & PageFlags.PRESENT != 0) return error.AlreadyMapped;
            pt.entries[i] = phys | leaf_flags;
        }

        /// Walks the tables and returns the physical address `virt` resolves to.
        pub fn translate(self: *Self, virt: u64) ?Translation {
            if (!isCanonical(virt)) return null;
            const pml4e = self.table(self.root).entries[pml4Index(virt)];
            if (pml4e & PageFlags.PRESENT == 0) return null;
            const pdpte = self.table(pml4e & ADDR_MASK).entries[pdptIndex(virt)];
            if (pdpte & PageFlags.PRESENT == 0) return null;
            if (pdpte & PageFlags.HUGE_PAGE != 0) {
                const base = pdpte & ADDR_MASK & ~(PAGE_SIZE_1G - 1);
                return .{ .phys = base + (virt & (PAGE_SIZE_1G - 1)), .size = .size_1g, .flags = pdpte & ~ADDR_MASK };
            }
            const pde = self.table(pdpte & ADDR_MASK).entries[pdIndex(virt)];
            if (pde & PageFlags.PRESENT == 0) return null;
            if (pde & PageFlags.HUGE_PAGE != 0) {
                const base = pde & ADDR_MASK & ~(PAGE_SIZE_2M - 1);
                return .{ .phys = base + (virt & (PAGE_SIZE_2M - 1)), .size = .size_2m, .flags = pde & ~ADDR_MASK };
            }
            const pte = self.table(pde & ADDR_MASK).entries[ptIndex(virt)];
            if (pte & PageFlags.PRESENT == 0) return null;
            return .{ .phys = (pte & ADDR_MASK) + pageOffset(virt), .size = .size_4k, .flags = pte & ~ADDR_MASK };
        }

        /// Removes the leaf that maps `virt`. `virt` must be the first byte of
        /// that leaf, so a 4 KiB unmap cannot silently drop a whole 2 MiB page.
        /// Intermediate tables are kept for reuse.
        pub fn unmap(self: *Self, virt: u64) UnmapError!Translation {
            if (!isCanonical(virt)) return error.NonCanonical;
            const tr = self.translate(virt) orelse return error.NotMapped;
            if (virt % tr.size.bytes() != 0) return error.Misaligned;
            const pml4e = self.table(self.root).entries[pml4Index(virt)];
            const pdpt = self.table(pml4e & ADDR_MASK);
            if (tr.size == .size_1g) {
                pdpt.entries[pdptIndex(virt)] = 0;
                return tr;
            }
            const pd = self.table(pdpt.entries[pdptIndex(virt)] & ADDR_MASK);
            if (tr.size == .size_2m) {
                pd.entries[pdIndex(virt)] = 0;
                return tr;
            }
            const pt = self.table(pd.entries[pdIndex(virt)] & ADDR_MASK);
            pt.entries[ptIndex(virt)] = 0;
            return tr;
        }

        /// Maps [virt, virt+len) to [phys, phys+len) using the largest page size
        /// both addresses and the remaining length allow (1 GiB pages only when
        /// `allow_1g`). On failure every page this call mapped is unmapped again.
        pub fn mapRange(self: *Self, virt: u64, phys: u64, len: u64, flags: u64, allow_1g: bool) MapError!RangeStats {
            if (virt % PAGE_SIZE_4K != 0 or phys % PAGE_SIZE_4K != 0 or len % PAGE_SIZE_4K != 0) return error.Misaligned;
            if (len == 0) return .{};
            const last_virt = std.math.add(u64, virt, len - 1) catch return error.AddressOverflow;
            _ = std.math.add(u64, phys, len - 1) catch return error.AddressOverflow;
            if (!isCanonical(virt) or !isCanonical(last_virt)) return error.NonCanonical;
            // A canonical range cannot straddle the non-canonical hole.
            if ((virt >> 47) != (last_virt >> 47)) return error.NonCanonical;

            var stats = RangeStats{};
            var off: u64 = 0;
            while (off < len) {
                const v = virt + off;
                const p = phys + off;
                const left = len - off;
                const size: PageSize = if (allow_1g and v % PAGE_SIZE_1G == 0 and p % PAGE_SIZE_1G == 0 and left >= PAGE_SIZE_1G)
                    .size_1g
                else if (v % PAGE_SIZE_2M == 0 and p % PAGE_SIZE_2M == 0 and left >= PAGE_SIZE_2M)
                    .size_2m
                else
                    .size_4k;
                self.map(v, p, size, flags) catch |err| {
                    self.rollback(virt, off);
                    return err;
                };
                switch (size) {
                    .size_4k => stats.pages_4k += 1,
                    .size_2m => stats.pages_2m += 1,
                    .size_1g => stats.pages_1g += 1,
                }
                off += size.bytes();
            }
            return stats;
        }

        fn rollback(self: *Self, virt: u64, mapped_len: u64) void {
            var off: u64 = 0;
            while (off < mapped_len) {
                const tr = self.unmap(virt + off) catch unreachable;
                off += tr.size.bytes();
            }
        }
    };
}

/// Fixed pool of page tables. `phys_base` is the physical address of the first
/// table; when the pool lives in identity-mapped memory, pass its own address.
pub fn TablePool(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        tables: [capacity]PageTable align(4096) = undefined,
        used: usize = 0,
        phys_base: u64 = 0,

        pub fn allocTable(self: *Self) ?u64 {
            if (self.used == capacity) return null;
            self.tables[self.used].clear();
            const phys = self.phys_base + @as(u64, self.used) * PAGE_SIZE_4K;
            self.used += 1;
            return phys;
        }

        pub fn tableAt(self: *Self, phys: u64) *PageTable {
            const idx = (phys - self.phys_base) / PAGE_SIZE_4K;
            std.debug.assert(idx < self.used);
            return &self.tables[@intCast(idx)];
        }
    };
}

pub const KernelLayout = struct {
    identity: RangeStats,
    higher_half: RangeStats,
};

/// Standard early-kernel layout: identity map [0, identity_len) and alias the
/// same physical range at KERNEL_VMA_BASE, both writable and kernel-only.
pub fn buildKernelLayout(comptime Backend: type, space: *AddressSpace(Backend), identity_len: u64, allow_1g: bool) MapError!KernelLayout {
    if (identity_len > std.math.maxInt(u64) - KERNEL_VMA_BASE + 1) return error.AddressOverflow;
    const flags = PageFlags.WRITABLE | PageFlags.GLOBAL;
    const id = try space.mapRange(0, 0, identity_len, flags, allow_1g);
    const hh = try space.mapRange(KERNEL_VMA_BASE, 0, identity_len, flags, allow_1g);
    return .{ .identity = id, .higher_half = hh };
}

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

const TestPool = TablePool(64);
const TestSpace = AddressSpace(TestPool);

fn newTestSpace(pool: *TestPool) !TestSpace {
    pool.* = .{ .phys_base = 0x7000_0000 };
    return TestSpace.init(pool);
}

test "canonical address check" {
    try std.testing.expect(isCanonical(0));
    try std.testing.expect(isCanonical(0x0000_7FFF_FFFF_FFFF));
    try std.testing.expect(!isCanonical(0x0000_8000_0000_0000));
    try std.testing.expect(!isCanonical(0xFFFF_7FFF_FFFF_FFFF));
    try std.testing.expect(isCanonical(0xFFFF_8000_0000_0000));
    try std.testing.expect(isCanonical(KERNEL_VMA_BASE));
}

test "map and translate 4K, 2M and 1G pages" {
    var pool: TestPool = undefined;
    var as = try newTestSpace(&pool);

    try as.map(0x40_1000, 0x9000, .size_4k, PageFlags.WRITABLE | PageFlags.NO_EXECUTE);
    const t4 = as.translate(0x40_1234).?;
    try std.testing.expectEqual(@as(u64, 0x9234), t4.phys);
    try std.testing.expectEqual(PageSize.size_4k, t4.size);
    try std.testing.expect(t4.flags & PageFlags.NO_EXECUTE != 0);
    try std.testing.expect(t4.flags & PageFlags.HUGE_PAGE == 0);

    try as.map(0x60_0000, 0x20_0000, .size_2m, 0);
    const t2 = as.translate(0x7F_FFFF).?;
    try std.testing.expectEqual(@as(u64, 0x3F_FFFF), t2.phys);
    try std.testing.expectEqual(PageSize.size_2m, t2.size);
    try std.testing.expect(t2.flags & PageFlags.WRITABLE == 0);

    try as.map(KERNEL_VMA_BASE & ~(PAGE_SIZE_1G - 1), 0x4000_0000, .size_1g, PageFlags.WRITABLE);
    const t1 = as.translate(KERNEL_VMA_BASE + 0x1234_5678).?;
    try std.testing.expectEqual(@as(u64, 0x4000_0000 + 0x1234_5678), t1.phys);
    try std.testing.expectEqual(PageSize.size_1g, t1.size);

    try std.testing.expect(as.translate(0x50_0000) == null);
    try std.testing.expect(as.translate(0x0000_8000_0000_0000) == null);
}

test "map rejects conflicts, misalignment and bad addresses" {
    var pool: TestPool = undefined;
    var as = try newTestSpace(&pool);

    try as.map(0x20_0000, 0x20_0000, .size_2m, PageFlags.WRITABLE);
    // A 4K page inside the existing 2M leaf.
    try std.testing.expectError(error.AlreadyMapped, as.map(0x20_1000, 0x1000, .size_4k, 0));
    // The same 2M slot again.
    try std.testing.expectError(error.AlreadyMapped, as.map(0x20_0000, 0x40_0000, .size_2m, 0));
    // A 1G page over a PDPT slot that already points to a PD.
    try std.testing.expectError(error.AlreadyMapped, as.map(0, 0, .size_1g, 0));

    try as.map(0x80_0000, 0x1000, .size_4k, 0);
    // A 2M page over a PD slot that already points to a PT.
    try std.testing.expectError(error.AlreadyMapped, as.map(0x80_0000, 0x40_0000, .size_2m, 0));

    try std.testing.expectError(error.Misaligned, as.map(0x1000, 0x1001, .size_4k, 0));
    try std.testing.expectError(error.Misaligned, as.map(0x1000, 0x20_0000, .size_2m, 0));
    try std.testing.expectError(error.NonCanonical, as.map(0x0000_8000_0000_0000, 0, .size_4k, 0));
    try std.testing.expectError(error.PhysTooLarge, as.map(0x1000, @as(u64, 1) << 52, .size_4k, 0));
}

test "caller cannot smuggle HUGE_PAGE into a 4K leaf" {
    var pool: TestPool = undefined;
    var as = try newTestSpace(&pool);
    try as.map(0x3000, 0x5000, .size_4k, PageFlags.HUGE_PAGE | PageFlags.WRITABLE | PageFlags.DIRTY);
    const t = as.translate(0x3000).?;
    try std.testing.expectEqual(PageSize.size_4k, t.size);
    try std.testing.expectEqual(PageFlags.PRESENT | PageFlags.WRITABLE, t.flags);
}

test "user mappings propagate the user bit to intermediate tables" {
    var pool: TestPool = undefined;
    var as = try newTestSpace(&pool);
    try as.map(0x1000, 0x1000, .size_4k, 0);
    const pml4e = pool.tableAt(as.root).entries[0];
    try std.testing.expect(pml4e & PageFlags.USER_ACCESSIBLE == 0);
    try as.map(0x2000, 0x2000, .size_4k, PageFlags.USER_ACCESSIBLE);
    try std.testing.expect(pool.tableAt(as.root).entries[0] & PageFlags.USER_ACCESSIBLE != 0);
    try std.testing.expect(as.translate(0x1000).?.flags & PageFlags.USER_ACCESSIBLE == 0);
    try std.testing.expect(as.translate(0x2000).?.flags & PageFlags.USER_ACCESSIBLE != 0);
}

test "unmap removes exactly one leaf and requires its first byte" {
    var pool: TestPool = undefined;
    var as = try newTestSpace(&pool);
    try as.map(0x20_0000, 0x40_0000, .size_2m, 0);
    try std.testing.expectError(error.Misaligned, as.unmap(0x20_1000));
    const tr = try as.unmap(0x20_0000);
    try std.testing.expectEqual(PageSize.size_2m, tr.size);
    try std.testing.expectEqual(@as(u64, 0x40_0000), tr.phys);
    try std.testing.expect(as.translate(0x20_0000) == null);
    try std.testing.expectError(error.NotMapped, as.unmap(0x20_0000));
    // The slot is reusable at a smaller size.
    try as.map(0x20_1000, 0x1000, .size_4k, 0);
    try std.testing.expectEqual(@as(u64, 0x1000), as.translate(0x20_1000).?.phys);
}

test "mapRange picks the largest page sizes" {
    var pool: TestPool = undefined;
    var as = try newTestSpace(&pool);
    // 4K-aligned start, crosses a 2M boundary: 4K pages up to 2M, then 2M pages, then a 4K tail.
    const virt: u64 = 0x1F_E000;
    const len: u64 = 0x2000 + 2 * PAGE_SIZE_2M + 0x3000;
    const s = try as.mapRange(virt, virt, len, PageFlags.WRITABLE, false);
    try std.testing.expectEqual(@as(usize, 2 + 3), s.pages_4k);
    try std.testing.expectEqual(@as(usize, 2), s.pages_2m);
    try std.testing.expectEqual(@as(usize, 0), s.pages_1g);
    var off: u64 = 0;
    while (off < len) : (off += 0x800) {
        try std.testing.expectEqual(virt + off, as.translate(virt + off).?.phys);
    }
    try std.testing.expect(as.translate(virt + len) == null);

    // Same virtual/physical 1G alignment allows 1G leaves when enabled.
    const s1 = try as.mapRange(0x80_0000_0000, 0x1_0000_0000, 2 * PAGE_SIZE_1G, 0, true);
    try std.testing.expectEqual(@as(usize, 2), s1.pages_1g);
    // Different relative alignment falls back to 2M.
    const s2 = try as.mapRange(0x100_0000_0000, 0x1_0020_0000, PAGE_SIZE_1G, 0, true);
    try std.testing.expectEqual(@as(usize, 0), s2.pages_1g);
    try std.testing.expectEqual(@as(usize, 512), s2.pages_2m);
}

test "mapRange rolls back on conflict and validates ranges" {
    var pool: TestPool = undefined;
    var as = try newTestSpace(&pool);
    try as.map(0x5000, 0xAA000, .size_4k, 0);
    try std.testing.expectError(error.AlreadyMapped, as.mapRange(0x1000, 0x1000, 0x8000, 0, false));
    // Nothing from the failed call remains; the pre-existing page is untouched.
    try std.testing.expect(as.translate(0x1000) == null);
    try std.testing.expect(as.translate(0x4000) == null);
    try std.testing.expectEqual(@as(u64, 0xAA000), as.translate(0x5000).?.phys);

    try std.testing.expectError(error.Misaligned, as.mapRange(0x1000, 0x1000, 0x800, 0, false));
    try std.testing.expectError(error.AddressOverflow, as.mapRange(0xFFFF_FFFF_FFFF_F000, 0, 0x2000, 0, false));
    // Range that runs from the lower half into the non-canonical hole.
    try std.testing.expectError(error.NonCanonical, as.mapRange(0x0000_7FFF_FFFF_F000, 0, 0x2000, 0, false));
    const empty = try as.mapRange(0x1000, 0x1000, 0, 0, false);
    try std.testing.expectEqual(@as(usize, 0), empty.pages_4k);
}

test "mapRange reports exhaustion of the table pool" {
    var pool: TablePool(3) = .{ .phys_base = 0x10_0000 };
    var as = try AddressSpace(TablePool(3)).init(&pool);
    // Needs PML4 + PDPT + PD + PT: the PT allocation fails.
    try std.testing.expectError(error.OutOfTables, as.mapRange(0x1000, 0x1000, 0x1000, 0, false));
    // 2M leaves need no PT and still fit.
    _ = try as.mapRange(0, 0, PAGE_SIZE_2M, 0, false);
}

test "kernel layout identity and higher-half views agree" {
    var pool: TestPool = undefined;
    var as = try newTestSpace(&pool);
    const layout = try buildKernelLayout(TestPool, &as, PAGE_SIZE_1G, false);
    try std.testing.expectEqual(@as(usize, 512), layout.identity.pages_2m);
    try std.testing.expectEqual(@as(usize, 512), layout.higher_half.pages_2m);
    // PML4 + (PDPT + PD) for each half.
    try std.testing.expectEqual(@as(usize, 5), pool.used);

    var prng = std.Random.DefaultPrng.init(0xA11A5);
    const rand = prng.random();
    for (0..2000) |_| {
        const p = rand.uintLessThan(u64, PAGE_SIZE_1G);
        const lo = as.translate(p).?;
        const hi = as.translate(KERNEL_VMA_BASE + p).?;
        try std.testing.expectEqual(p, lo.phys);
        try std.testing.expectEqual(p, hi.phys);
        try std.testing.expect(lo.flags & PageFlags.GLOBAL != 0);
        try std.testing.expect(lo.flags & PageFlags.USER_ACCESSIBLE == 0);
    }
    try std.testing.expect(as.translate(PAGE_SIZE_1G) == null);
    try std.testing.expect(as.translate(KERNEL_VMA_BASE + PAGE_SIZE_1G) == null);

    var pool2: TestPool = undefined;
    var as2 = try newTestSpace(&pool2);
    const l1 = try buildKernelLayout(TestPool, &as2, 2 * PAGE_SIZE_1G, true);
    // The higher-half window holds exactly 2 GiB, so both halves use 1G leaves.
    try std.testing.expectEqual(@as(usize, 2), l1.identity.pages_1g);
    try std.testing.expectEqual(@as(usize, 2), l1.higher_half.pages_1g);
    try std.testing.expectError(error.AddressOverflow, buildKernelLayout(TestPool, &as2, 4 * PAGE_SIZE_1G, true));
}

test "randomized map/unmap agrees with a reference model" {
    var pool: TablePool(256) = .{ .phys_base = 0x100_0000 };
    var as = try AddressSpace(TablePool(256)).init(&pool);
    // Model: 4K pages inside an 8 MiB window, keyed by page index.
    const PAGES = 2048;
    var model: [PAGES]?u64 = @splat(null);
    var prng = std.Random.DefaultPrng.init(0x7AB1E);
    const rand = prng.random();
    for (0..10000) |_| {
        const idx = rand.uintLessThan(usize, PAGES);
        const virt = 0xFFFF_8000_0000_0000 + @as(u64, idx) * PAGE_SIZE_4K;
        if (rand.boolean()) {
            const phys = rand.uintLessThan(u64, 1 << 30) & ~(PAGE_SIZE_4K - 1);
            if (as.map(virt, phys, .size_4k, PageFlags.WRITABLE)) {
                try std.testing.expect(model[idx] == null);
                model[idx] = phys;
            } else |err| {
                try std.testing.expectEqual(error.AlreadyMapped, err);
                try std.testing.expect(model[idx] != null);
            }
        } else {
            if (as.unmap(virt)) |tr| {
                try std.testing.expectEqual(model[idx].?, tr.phys);
                model[idx] = null;
            } else |err| {
                try std.testing.expectEqual(error.NotMapped, err);
                try std.testing.expect(model[idx] == null);
            }
        }
    }
    for (model, 0..) |m, idx| {
        const virt = 0xFFFF_8000_0000_0000 + @as(u64, idx) * PAGE_SIZE_4K + 0x123;
        if (m) |phys| {
            try std.testing.expectEqual(phys + 0x123, as.translate(virt).?.phys);
        } else {
            try std.testing.expect(as.translate(virt) == null);
        }
    }
}
