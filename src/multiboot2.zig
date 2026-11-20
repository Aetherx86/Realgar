//! Multiboot2 support: the header a kernel image embeds so a loader can find it,
//! and a bounds-checked parser for the boot information structure the loader
//! hands back. Every read goes through a byte slice with explicit length checks,
//! so a truncated or hostile structure produces an error instead of a wild read.

const std = @import("std");

/// Magic value at the start of the header embedded in the kernel image.
pub const HEADER_MAGIC: u32 = 0xE85250D6;
/// Value a compliant loader leaves in EAX when it jumps to the kernel.
pub const BOOTLOADER_MAGIC: u32 = 0x36D76289;
/// The header must lie entirely within this many bytes of the image start.
pub const HEADER_SEARCH_LIMIT: usize = 32768;
/// Header and every tag (header tags and boot information tags) are 8-byte aligned.
pub const ALIGN: usize = 8;

pub const ARCH_I386: u32 = 0;
pub const ARCH_MIPS32: u32 = 4;

/// Bit 0 of a header tag's flags marks it optional for the loader.
pub const HEADER_TAG_OPTIONAL: u16 = 1;

pub const HeaderTagType = enum(u16) {
    end = 0,
    information_request = 1,
    address = 2,
    entry_address = 3,
    console_flags = 4,
    framebuffer = 5,
    module_align = 6,
    efi_boot_services = 7,
    entry_address_efi32 = 8,
    entry_address_efi64 = 9,
    relocatable = 10,
    _,

    pub fn name(self: HeaderTagType) []const u8 {
        return switch (self) {
            .end => "end",
            .information_request => "information_request",
            .address => "address",
            .entry_address => "entry_address",
            .console_flags => "console_flags",
            .framebuffer => "framebuffer",
            .module_align => "module_align",
            .efi_boot_services => "efi_boot_services",
            .entry_address_efi32 => "entry_address_efi32",
            .entry_address_efi64 => "entry_address_efi64",
            .relocatable => "relocatable",
            _ => "unknown",
        };
    }
};

pub const InfoTagType = enum(u32) {
    end = 0,
    cmdline = 1,
    boot_loader_name = 2,
    module = 3,
    basic_meminfo = 4,
    bootdev = 5,
    mmap = 6,
    vbe = 7,
    framebuffer = 8,
    elf_sections = 9,
    apm = 10,
    efi32 = 11,
    efi64 = 12,
    smbios = 13,
    acpi_old = 14,
    acpi_new = 15,
    network = 16,
    efi_mmap = 17,
    efi_boot_services = 18,
    efi32_image_handle = 19,
    efi64_image_handle = 20,
    load_base_addr = 21,
    _,
};

pub fn headerChecksum(architecture: u32, header_length: u32) u32 {
    return 0 -% (HEADER_MAGIC +% architecture +% header_length);
}

/// Layout of the header Realgar embeds: fixed fields, an optional information
/// request tag asking for the memory map, command line, loader name and basic
/// memory info, then the mandatory end tag.
pub const KernelHeader = extern struct {
    magic: u32,
    architecture: u32,
    header_length: u32,
    checksum: u32,
    request_type: u16,
    request_flags: u16,
    request_size: u32,
    requests: [4]u32,
    end_type: u16,
    end_flags: u16,
    end_size: u32,

    pub fn make() KernelHeader {
        const length: u32 = @sizeOf(KernelHeader);
        return .{
            .magic = HEADER_MAGIC,
            .architecture = ARCH_I386,
            .header_length = length,
            .checksum = headerChecksum(ARCH_I386, length),
            .request_type = @backingInt(HeaderTagType.information_request),
            .request_flags = HEADER_TAG_OPTIONAL,
            .request_size = 8 + 4 * 4,
            .requests = .{
                @backingInt(InfoTagType.mmap),
                @backingInt(InfoTagType.cmdline),
                @backingInt(InfoTagType.boot_loader_name),
                @backingInt(InfoTagType.basic_meminfo),
            },
            .end_type = @backingInt(HeaderTagType.end),
            .end_flags = 0,
            .end_size = 8,
        };
    }
};

comptime {
    // The end tag must start on an 8-byte boundary.
    std.debug.assert(@offsetOf(KernelHeader, "end_type") % ALIGN == 0);
    std.debug.assert(@sizeOf(KernelHeader) == 48);
}

inline fn alignUp(v: usize, a: usize) usize {
    return (v + (a - 1)) & ~(a - 1);
}

inline fn readU16(bytes: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, bytes[off..][0..2], .little);
}

inline fn readU32(bytes: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, bytes[off..][0..4], .little);
}

inline fn readU64(bytes: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, bytes[off..][0..8], .little);
}

// ---------------------------------------------------------------------------
// Header validation (what a loader does when it scans a kernel image)
// ---------------------------------------------------------------------------

pub const HeaderError = error{
    Truncated,
    BadMagic,
    BadChecksum,
    BadLength,
    MisalignedHeader,
    TagTooSmall,
    TagOverflow,
    MissingEndTag,
    BadEndTag,
    TooManyTags,
};

pub const MAX_HEADER_TAGS: usize = 32;

pub const HeaderTag = struct {
    tag_type: u16,
    flags: u16,
    size: u32,
    offset: usize,
};

pub const HeaderSummary = struct {
    offset: usize,
    architecture: u32,
    header_length: u32,
    checksum: u32,
    tag_buf: [MAX_HEADER_TAGS]HeaderTag = undefined,
    tag_count: usize = 0,

    pub fn tags(self: *const HeaderSummary) []const HeaderTag {
        return self.tag_buf[0..self.tag_count];
    }

    /// Requested information tag types, if the header carries a request tag.
    pub fn requestedInfo(self: *const HeaderSummary, image: []const u8, out: []u32) usize {
        for (self.tags()) |t| {
            if (t.tag_type != @backingInt(HeaderTagType.information_request)) continue;
            const n = @min((t.size - 8) / 4, out.len);
            for (0..n) |i| out[i] = readU32(image, t.offset + 8 + i * 4);
            return n;
        }
        return 0;
    }
};

/// Validates a multiboot2 header at `offset` in `image`, walking every tag.
pub fn validateHeader(image: []const u8, offset: usize) HeaderError!HeaderSummary {
    if (offset % ALIGN != 0) return error.MisalignedHeader;
    if (offset > image.len or image.len - offset < 16) return error.Truncated;
    if (readU32(image, offset) != HEADER_MAGIC) return error.BadMagic;
    const arch = readU32(image, offset + 4);
    const length = readU32(image, offset + 8);
    const checksum = readU32(image, offset + 12);
    if (HEADER_MAGIC +% arch +% length +% checksum != 0) return error.BadChecksum;
    // Smallest valid header: 16 fixed bytes plus an 8-byte end tag.
    if (length < 24 or length % ALIGN != 0) return error.BadLength;
    if (length > image.len - offset) return error.Truncated;

    var summary = HeaderSummary{
        .offset = offset,
        .architecture = arch,
        .header_length = length,
        .checksum = checksum,
    };
    const end = offset + length;
    var pos = offset + 16;
    while (true) {
        if (end - pos < 8) return error.MissingEndTag;
        const tag_type = readU16(image, pos);
        const flags = readU16(image, pos + 2);
        const size = readU32(image, pos + 4);
        if (size < 8) return error.TagTooSmall;
        if (size > end - pos) return error.TagOverflow;
        if (summary.tag_count == MAX_HEADER_TAGS) return error.TooManyTags;
        summary.tag_buf[summary.tag_count] = .{ .tag_type = tag_type, .flags = flags, .size = size, .offset = pos };
        summary.tag_count += 1;
        if (tag_type == @backingInt(HeaderTagType.end)) {
            if (size != 8 or pos + 8 != end) return error.BadEndTag;
            return summary;
        }
        const next = alignUp(pos + size, ALIGN);
        if (next >= end) return error.MissingEndTag;
        pos = next;
    }
}

/// Finds the first valid multiboot2 header the way a loader would: 8-byte aligned
/// candidates fully inside the first 32 KiB of the image.
pub fn findHeader(image: []const u8) ?HeaderSummary {
    const limit = @min(image.len, HEADER_SEARCH_LIMIT);
    var off: usize = 0;
    while (off + 16 <= limit) : (off += ALIGN) {
        if (readU32(image, off) != HEADER_MAGIC) continue;
        const s = validateHeader(image, off) catch continue;
        if (s.offset + s.header_length <= limit) return s;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Boot information parsing (what the kernel does with the loader's structure)
// ---------------------------------------------------------------------------

pub const ParseError = error{
    Truncated,
    BadTotalSize,
    ReservedNonZero,
    TagTooSmall,
    TagOverflow,
    MissingEndTag,
    BadEndTag,
    UnterminatedString,
    BadTagLength,
    BadMmapEntrySize,
};

pub const MemoryKind = enum(u32) {
    available = 1,
    reserved = 2,
    acpi_reclaimable = 3,
    acpi_nvs = 4,
    bad = 5,
    _,

    pub fn name(self: MemoryKind) []const u8 {
        return switch (self) {
            .available => "available",
            .reserved => "reserved",
            .acpi_reclaimable => "acpi_reclaimable",
            .acpi_nvs => "acpi_nvs",
            .bad => "bad",
            _ => "unknown",
        };
    }
};

pub const MemoryRegion = struct {
    base: u64,
    length: u64,
    kind: MemoryKind,

    /// Exclusive end address, saturated at the top of the address space.
    pub fn end(self: MemoryRegion) u64 {
        return self.base +| self.length;
    }
};

pub const MemoryMap = struct {
    entry_size: u32,
    entry_version: u32,
    entries: []const u8,

    pub fn count(self: MemoryMap) usize {
        return self.entries.len / self.entry_size;
    }

    pub fn iterator(self: MemoryMap) Iterator {
        return .{ .map = self, .index = 0 };
    }

    pub const Iterator = struct {
        map: MemoryMap,
        index: usize,

        pub fn next(self: *Iterator) ?MemoryRegion {
            if (self.index >= self.map.count()) return null;
            const off = self.index * self.map.entry_size;
            self.index += 1;
            return .{
                .base = readU64(self.map.entries, off),
                .length = readU64(self.map.entries, off + 8),
                .kind = @fromBackingInt(@intCast(readU32(self.map.entries, off + 16))),
            };
        }
    };
};

pub const BasicMemInfo = struct {
    /// KiB of lower memory starting at address 0 (at most 640).
    mem_lower: u32,
    /// KiB of upper memory starting at 1 MiB.
    mem_upper: u32,
};

pub const Tag = struct {
    tag_type: u32,
    /// Bytes after the 8-byte tag header, exactly `size - 8` long.
    payload: []const u8,
};

pub const TagIterator = struct {
    bytes: []const u8,
    pos: usize,

    pub fn next(self: *TagIterator) ?Tag {
        if (self.pos + 8 > self.bytes.len) return null;
        const t = readU32(self.bytes, self.pos);
        if (t == @backingInt(InfoTagType.end)) return null;
        const size = readU32(self.bytes, self.pos + 4);
        const tag = Tag{ .tag_type = t, .payload = self.bytes[self.pos + 8 .. self.pos + size] };
        self.pos = alignUp(self.pos + size, ALIGN);
        return tag;
    }
};

/// Validated view of a multiboot2 boot information structure. `parse` checks
/// every tag once, so the accessors below never need to re-check bounds.
pub const BootInfo = struct {
    bytes: []const u8,

    /// Largest structure accepted from a raw pointer. Real loaders produce a
    /// few KiB; the cap keeps a corrupted total_size from spanning memory.
    pub const MAX_TOTAL_SIZE: u32 = 1 << 20;

    /// Builds a view from the physical address a loader passed in EBX.
    /// The caller must guarantee that address is mapped.
    pub fn fromAddress(addr: usize) ParseError!BootInfo {
        if (addr == 0 or addr % ALIGN != 0) return error.Truncated;
        const head: [*]const u8 = @ptrFromInt(addr);
        const total = std.mem.readInt(u32, head[0..4], .little);
        if (total < 16 or total > MAX_TOTAL_SIZE) return error.BadTotalSize;
        return parse(head[0..total]);
    }

    pub fn parse(buf: []const u8) ParseError!BootInfo {
        if (buf.len < 8) return error.Truncated;
        const total = readU32(buf, 0);
        if (total < 16 or total % ALIGN != 0) return error.BadTotalSize;
        if (total > buf.len) return error.Truncated;
        if (readU32(buf, 4) != 0) return error.ReservedNonZero;
        const bytes = buf[0..total];

        var pos: usize = 8;
        while (true) {
            if (total - pos < 8) return error.MissingEndTag;
            const t = readU32(bytes, pos);
            const size = readU32(bytes, pos + 4);
            if (size < 8) return error.TagTooSmall;
            if (size > total - pos) return error.TagOverflow;
            const payload = bytes[pos + 8 .. pos + size];
            if (t == @backingInt(InfoTagType.end)) {
                if (size != 8) return error.BadEndTag;
                return .{ .bytes = bytes };
            }
            try validateTag(@fromBackingInt(@intCast(t)), payload);
            const next = alignUp(pos + size, ALIGN);
            if (next >= total) return error.MissingEndTag;
            pos = next;
        }
    }

    fn validateTag(t: InfoTagType, payload: []const u8) ParseError!void {
        switch (t) {
            .cmdline, .boot_loader_name => {
                if (std.mem.indexOfScalar(u8, payload, 0) == null) return error.UnterminatedString;
            },
            .basic_meminfo => if (payload.len < 8) return error.BadTagLength,
            .mmap => {
                if (payload.len < 8) return error.BadTagLength;
                const entry_size = readU32(payload, 0);
                if (entry_size < 24 or entry_size % 8 != 0) return error.BadMmapEntrySize;
                if ((payload.len - 8) % entry_size != 0) return error.BadTagLength;
            },
            else => {},
        }
    }

    pub fn totalSize(self: BootInfo) usize {
        return self.bytes.len;
    }

    pub fn tags(self: BootInfo) TagIterator {
        return .{ .bytes = self.bytes, .pos = 8 };
    }

    pub fn findTag(self: BootInfo, t: InfoTagType) ?Tag {
        var it = self.tags();
        while (it.next()) |tag| {
            if (tag.tag_type == @backingInt(t)) return tag;
        }
        return null;
    }

    fn string(self: BootInfo, t: InfoTagType) ?[]const u8 {
        const tag = self.findTag(t) orelse return null;
        const nul = std.mem.indexOfScalar(u8, tag.payload, 0).?;
        return tag.payload[0..nul];
    }

    pub fn commandLine(self: BootInfo) ?[]const u8 {
        return self.string(.cmdline);
    }

    pub fn bootloaderName(self: BootInfo) ?[]const u8 {
        return self.string(.boot_loader_name);
    }

    pub fn basicMemInfo(self: BootInfo) ?BasicMemInfo {
        const tag = self.findTag(.basic_meminfo) orelse return null;
        return .{ .mem_lower = readU32(tag.payload, 0), .mem_upper = readU32(tag.payload, 4) };
    }

    pub fn memoryMap(self: BootInfo) ?MemoryMap {
        const tag = self.findTag(.mmap) orelse return null;
        return .{
            .entry_size = readU32(tag.payload, 0),
            .entry_version = readU32(tag.payload, 4),
            .entries = tag.payload[8..],
        };
    }
};

/// Writes boot information structures into a caller buffer. Used by tests and by
/// the host-side tooling to produce inputs identical to what a loader emits.
pub const InfoBuilder = struct {
    buf: []u8,
    len: usize,

    pub const Error = error{NoSpace};

    pub fn init(buf: []u8) Error!InfoBuilder {
        if (buf.len < 8) return error.NoSpace;
        @memset(buf, 0);
        return .{ .buf = buf, .len = 8 };
    }

    pub fn addTag(self: *InfoBuilder, t: u32, payload: []const u8) Error!void {
        const size = 8 + payload.len;
        const padded = alignUp(size, ALIGN);
        if (self.buf.len - self.len < padded) return error.NoSpace;
        std.mem.writeInt(u32, self.buf[self.len..][0..4], t, .little);
        std.mem.writeInt(u32, self.buf[self.len + 4 ..][0..4], @intCast(size), .little);
        @memcpy(self.buf[self.len + 8 ..][0..payload.len], payload);
        self.len += padded;
    }

    pub fn addString(self: *InfoBuilder, t: InfoTagType, s: []const u8) Error!void {
        var tmp: [256]u8 = undefined;
        if (s.len + 1 > tmp.len) return error.NoSpace;
        @memcpy(tmp[0..s.len], s);
        tmp[s.len] = 0;
        try self.addTag(@backingInt(t), tmp[0 .. s.len + 1]);
    }

    pub fn addBasicMemInfo(self: *InfoBuilder, lower_kib: u32, upper_kib: u32) Error!void {
        var p: [8]u8 = undefined;
        std.mem.writeInt(u32, p[0..4], lower_kib, .little);
        std.mem.writeInt(u32, p[4..8], upper_kib, .little);
        try self.addTag(@backingInt(InfoTagType.basic_meminfo), &p);
    }

    pub fn addMemoryMap(self: *InfoBuilder, regions: []const MemoryRegion) Error!void {
        var tmp: [8 + 24 * 32]u8 = undefined;
        if (regions.len > 32) return error.NoSpace;
        std.mem.writeInt(u32, tmp[0..4], 24, .little);
        std.mem.writeInt(u32, tmp[4..8], 0, .little);
        for (regions, 0..) |r, i| {
            const o = 8 + i * 24;
            std.mem.writeInt(u64, tmp[o..][0..8], r.base, .little);
            std.mem.writeInt(u64, tmp[o + 8 ..][0..8], r.length, .little);
            std.mem.writeInt(u32, tmp[o + 16 ..][0..4], @backingInt(r.kind), .little);
            std.mem.writeInt(u32, tmp[o + 20 ..][0..4], 0, .little);
        }
        try self.addTag(@backingInt(InfoTagType.mmap), tmp[0 .. 8 + regions.len * 24]);
    }

    /// Appends the end tag, writes total_size, and returns the finished bytes.
    pub fn finish(self: *InfoBuilder) Error![]u8 {
        try self.addTag(@backingInt(InfoTagType.end), &.{});
        std.mem.writeInt(u32, self.buf[0..4], @intCast(self.len), .little);
        return self.buf[0..self.len];
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "kernel header checksum and tag layout validate" {
    const hdr = KernelHeader.make();
    const bytes = std.mem.asBytes(&hdr);
    const s = try validateHeader(bytes, 0);
    try testing.expectEqual(@as(u32, 48), s.header_length);
    try testing.expectEqual(ARCH_I386, s.architecture);
    try testing.expectEqual(@as(usize, 2), s.tags().len);
    try testing.expectEqual(@as(u16, 1), s.tags()[0].tag_type);
    try testing.expectEqual(HEADER_TAG_OPTIONAL, s.tags()[0].flags);
    try testing.expectEqual(@as(u16, 0), s.tags()[1].tag_type);
    var req: [8]u32 = undefined;
    const n = s.requestedInfo(bytes, &req);
    try testing.expectEqualSlices(u32, &.{ 6, 1, 2, 4 }, req[0..n]);
    try testing.expectEqual(@as(u32, 0), hdr.magic +% hdr.architecture +% hdr.header_length +% hdr.checksum);
}

test "findHeader locates an aligned header and skips decoys" {
    var image: [4096]u8 = @splat(0);
    // Decoy: magic with wrong checksum at offset 64.
    std.mem.writeInt(u32, image[64..68], HEADER_MAGIC, .little);
    // Decoy: valid header at an unaligned offset is never considered.
    const hdr = KernelHeader.make();
    @memcpy(image[300..][0..48], std.mem.asBytes(&hdr));
    try testing.expect(findHeader(&image) == null);
    @memcpy(image[1024..][0..48], std.mem.asBytes(&hdr));
    const s = findHeader(&image).?;
    try testing.expectEqual(@as(usize, 1024), s.offset);
}

test "findHeader rejects a header that crosses the 32 KiB search limit" {
    var image: [HEADER_SEARCH_LIMIT + 64]u8 = @splat(0);
    const hdr = KernelHeader.make();
    @memcpy(image[HEADER_SEARCH_LIMIT - 24 ..][0..48], std.mem.asBytes(&hdr));
    try testing.expect(findHeader(&image) == null);
}

test "validateHeader rejects malformed tag chains" {
    var hdr = KernelHeader.make();
    const bytes = std.mem.asBytes(&hdr);

    // Tag size below 8.
    hdr.request_size = 4;
    try testing.expectError(error.TagTooSmall, validateHeader(bytes, 0));

    // Tag running past header_length.
    hdr = KernelHeader.make();
    hdr.request_size = 200;
    try testing.expectError(error.TagOverflow, validateHeader(bytes, 0));

    // End tag with wrong size.
    hdr = KernelHeader.make();
    hdr.end_size = 16;
    try testing.expectError(error.TagOverflow, validateHeader(bytes, 0));

    // Missing end tag: replace the end tag with an unknown tag.
    hdr = KernelHeader.make();
    hdr.end_type = 77;
    try testing.expectError(error.MissingEndTag, validateHeader(bytes, 0));

    // Length not a multiple of 8 (checksum fixed up so only length is wrong).
    hdr = KernelHeader.make();
    hdr.header_length = 44;
    hdr.checksum = headerChecksum(hdr.architecture, 44);
    try testing.expectError(error.BadLength, validateHeader(bytes, 0));

    // Checksum mismatch.
    hdr = KernelHeader.make();
    hdr.checksum +%= 1;
    try testing.expectError(error.BadChecksum, validateHeader(bytes, 0));

    // Truncated image.
    hdr = KernelHeader.make();
    try testing.expectError(error.Truncated, validateHeader(bytes[0..40], 0));
    try testing.expectError(error.MisalignedHeader, validateHeader(bytes, 4));
}

test "boot info round trip through builder and parser" {
    var buf: [1024]u8 align(8) = undefined;
    var b = try InfoBuilder.init(&buf);
    try b.addString(.cmdline, "console=ttyS0 quiet");
    try b.addString(.boot_loader_name, "GRUB 2.12");
    try b.addBasicMemInfo(639, 130048);
    try b.addMemoryMap(&.{
        .{ .base = 0, .length = 0x9FC00, .kind = .available },
        .{ .base = 0x9FC00, .length = 0x400, .kind = .reserved },
        .{ .base = 0x100000, .length = 0x7EE0000, .kind = .available },
        .{ .base = 0xFFFC0000, .length = 0x40000, .kind = .reserved },
    });
    const bytes = try b.finish();

    const info = try BootInfo.parse(bytes);
    try testing.expectEqual(bytes.len, info.totalSize());
    try testing.expectEqualStrings("console=ttyS0 quiet", info.commandLine().?);
    try testing.expectEqualStrings("GRUB 2.12", info.bootloaderName().?);
    const mi = info.basicMemInfo().?;
    try testing.expectEqual(@as(u32, 639), mi.mem_lower);
    try testing.expectEqual(@as(u32, 130048), mi.mem_upper);

    const mmap = info.memoryMap().?;
    try testing.expectEqual(@as(usize, 4), mmap.count());
    var it = mmap.iterator();
    var avail: u64 = 0;
    while (it.next()) |r| {
        if (r.kind == .available) avail += r.length;
    }
    try testing.expectEqual(@as(u64, 0x9FC00 + 0x7EE0000), avail);

    var tag_count: usize = 0;
    var ti = info.tags();
    while (ti.next()) |_| tag_count += 1;
    try testing.expectEqual(@as(usize, 4), tag_count);
}

test "boot info parser rejects hostile structures" {
    var buf: [256]u8 align(8) = undefined;
    var b = try InfoBuilder.init(&buf);
    try b.addString(.cmdline, "x");
    const good = try b.finish();
    _ = try BootInfo.parse(good);

    var work: [256]u8 align(8) = undefined;

    // total_size larger than the buffer.
    @memcpy(work[0..good.len], good);
    std.mem.writeInt(u32, work[0..4], @intCast(good.len + 8), .little);
    try testing.expectError(error.Truncated, BootInfo.parse(work[0..good.len]));

    // total_size not a multiple of 8 / too small.
    std.mem.writeInt(u32, work[0..4], 12, .little);
    try testing.expectError(error.BadTotalSize, BootInfo.parse(work[0..good.len]));

    // Reserved field non-zero.
    @memcpy(work[0..good.len], good);
    std.mem.writeInt(u32, work[4..8], 1, .little);
    try testing.expectError(error.ReservedNonZero, BootInfo.parse(work[0..good.len]));

    // Tag size too small (would loop forever if accepted).
    @memcpy(work[0..good.len], good);
    std.mem.writeInt(u32, work[12..16], 4, .little);
    try testing.expectError(error.TagTooSmall, BootInfo.parse(work[0..good.len]));

    // Tag size past the end.
    @memcpy(work[0..good.len], good);
    std.mem.writeInt(u32, work[12..16], 0x7FFF_FFFF, .little);
    try testing.expectError(error.TagOverflow, BootInfo.parse(work[0..good.len]));

    // String without its terminating NUL.
    @memcpy(work[0..good.len], good);
    work[17] = 'y';
    try testing.expectError(error.UnterminatedString, BootInfo.parse(work[0..good.len]));

    // End tag removed.
    @memcpy(work[0..good.len], good);
    std.mem.writeInt(u32, work[good.len - 8 ..][0..4], 99, .little);
    try testing.expectError(error.MissingEndTag, BootInfo.parse(work[0..good.len]));

    try testing.expectError(error.Truncated, BootInfo.parse(work[0..4]));
}

test "memory map entry size validation" {
    var buf: [256]u8 align(8) = undefined;
    var b = try InfoBuilder.init(&buf);
    // entry_size 20 is smaller than the 24-byte entry layout.
    var payload: [8 + 40]u8 = @splat(0);
    std.mem.writeInt(u32, payload[0..4], 20, .little);
    try b.addTag(@backingInt(InfoTagType.mmap), &payload);
    try testing.expectError(error.BadMmapEntrySize, BootInfo.parse(try b.finish()));

    // entry_size 32 with a trailing partial entry.
    b = try InfoBuilder.init(&buf);
    std.mem.writeInt(u32, payload[0..4], 32, .little);
    try b.addTag(@backingInt(InfoTagType.mmap), &payload);
    try testing.expectError(error.BadTagLength, BootInfo.parse(try b.finish()));

    // entry_size 40 (larger, forward compatible): one entry, fields still read.
    b = try InfoBuilder.init(&buf);
    std.mem.writeInt(u32, payload[0..4], 40, .little);
    std.mem.writeInt(u64, payload[8..16], 0x200000, .little);
    std.mem.writeInt(u64, payload[16..24], 0x1000, .little);
    std.mem.writeInt(u32, payload[24..28], 1, .little);
    try b.addTag(@backingInt(InfoTagType.mmap), &payload);
    const info = try BootInfo.parse(try b.finish());
    var it = info.memoryMap().?.iterator();
    const r = it.next().?;
    try testing.expectEqual(@as(u64, 0x200000), r.base);
    try testing.expectEqual(MemoryKind.available, r.kind);
    try testing.expect(it.next() == null);
}

test "parser never reads out of bounds on random mutations" {
    var buf: [512]u8 align(8) = undefined;
    var b = try InfoBuilder.init(&buf);
    try b.addString(.cmdline, "root=/dev/sda1");
    try b.addBasicMemInfo(640, 65536);
    try b.addMemoryMap(&.{
        .{ .base = 0, .length = 0x9F000, .kind = .available },
        .{ .base = 0x100000, .length = 0x1000000, .kind = .available },
    });
    const good = try b.finish();

    var prng = std.Random.DefaultPrng.init(0x5EA1_6A12);
    const rand = prng.random();
    var work: [512]u8 align(8) = undefined;
    var accepted: usize = 0;
    for (0..20000) |_| {
        @memcpy(work[0..good.len], good);
        const flips = rand.intRangeAtMost(usize, 1, 4);
        for (0..flips) |_| {
            work[rand.uintLessThan(usize, good.len)] = rand.int(u8);
        }
        const cut = if (rand.boolean()) good.len else rand.uintLessThan(usize, good.len + 1);
        const info = BootInfo.parse(work[0..cut]) catch continue;
        accepted += 1;
        // Every accessor must stay within the validated bytes.
        _ = info.commandLine();
        _ = info.bootloaderName();
        _ = info.basicMemInfo();
        if (info.memoryMap()) |m| {
            var it = m.iterator();
            while (it.next()) |r| _ = r.end();
        }
        var ti = info.tags();
        while (ti.next()) |t| try testing.expect(t.payload.len <= info.totalSize());
    }
    try testing.expect(accepted > 0);
}
