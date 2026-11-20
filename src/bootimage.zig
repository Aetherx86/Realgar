//! Host-side inspection of a kernel image: ELF64 program headers plus the
//! multiboot1 and multiboot2 headers a loader would find, including the
//! physical address each header is loaded to. Used by `realgar inspect`.

const std = @import("std");
const multiboot2 = @import("multiboot2.zig");

pub const MB1_MAGIC: u32 = 0x1BADB002;
pub const MB1_SEARCH_LIMIT: usize = 8192;

pub const Mb1Header = struct {
    offset: usize,
    flags: u32,
    checksum: u32,
};

/// Finds a multiboot1 header: 4-byte aligned, fully inside the first 8 KiB,
/// with magic + flags + checksum == 0.
pub fn findMultiboot1(image: []const u8) ?Mb1Header {
    const limit = @min(image.len, MB1_SEARCH_LIMIT);
    var off: usize = 0;
    while (off + 12 <= limit) : (off += 4) {
        const magic = std.mem.readInt(u32, image[off..][0..4], .little);
        if (magic != MB1_MAGIC) continue;
        const flags = std.mem.readInt(u32, image[off + 4 ..][0..4], .little);
        const checksum = std.mem.readInt(u32, image[off + 8 ..][0..4], .little);
        if (magic +% flags +% checksum == 0) return .{ .offset = off, .flags = flags, .checksum = checksum };
    }
    return null;
}

pub const ElfError = error{
    NotElf,
    NotElf64,
    NotLittleEndian,
    Truncated,
    BadProgramHeaders,
    SegmentOutOfFile,
    TooManySegments,
};

pub const PT_LOAD: u32 = 1;
pub const EM_X86_64: u16 = 62;
pub const MAX_LOADS: usize = 32;

pub const Segment = struct {
    offset: u64,
    vaddr: u64,
    paddr: u64,
    filesz: u64,
    memsz: u64,
    flags: u32,
};

pub const ElfInfo = struct {
    elf_type: u16,
    machine: u16,
    entry: u64,
    load_buf: [MAX_LOADS]Segment = undefined,
    load_count: usize = 0,

    pub fn loads(self: *const ElfInfo) []const Segment {
        return self.load_buf[0..self.load_count];
    }

    /// Physical load address of a byte at file offset `off`, if a PT_LOAD covers it.
    pub fn fileOffsetToPhys(self: *const ElfInfo, off: u64) ?u64 {
        for (self.loads()) |s| {
            if (off >= s.offset and off - s.offset < s.filesz) return s.paddr + (off - s.offset);
        }
        return null;
    }
};

fn rd(comptime T: type, image: []const u8, off: usize) T {
    return std.mem.readInt(T, image[off..][0..@sizeOf(T)], .little);
}

pub fn parseElf64(image: []const u8) ElfError!ElfInfo {
    if (image.len < 4 or !std.mem.eql(u8, image[0..4], "\x7fELF")) return error.NotElf;
    if (image.len < 64) return error.Truncated;
    if (image[4] != 2) return error.NotElf64;
    if (image[5] != 1) return error.NotLittleEndian;
    var info = ElfInfo{
        .elf_type = rd(u16, image, 16),
        .machine = rd(u16, image, 18),
        .entry = rd(u64, image, 24),
    };
    const phoff = rd(u64, image, 32);
    const phentsize = rd(u16, image, 54);
    const phnum = rd(u16, image, 56);
    if (phnum == 0) return info;
    if (phentsize < 56) return error.BadProgramHeaders;
    const table_len = @as(u64, phentsize) * phnum;
    const table_end = std.math.add(u64, phoff, table_len) catch return error.BadProgramHeaders;
    if (table_end > image.len) return error.BadProgramHeaders;

    for (0..phnum) |i| {
        const p: usize = @intCast(phoff + @as(u64, i) * phentsize);
        if (rd(u32, image, p) != PT_LOAD) continue;
        const seg = Segment{
            .flags = rd(u32, image, p + 4),
            .offset = rd(u64, image, p + 8),
            .vaddr = rd(u64, image, p + 16),
            .paddr = rd(u64, image, p + 24),
            .filesz = rd(u64, image, p + 32),
            .memsz = rd(u64, image, p + 40),
        };
        const seg_end = std.math.add(u64, seg.offset, seg.filesz) catch return error.SegmentOutOfFile;
        if (seg_end > image.len) return error.SegmentOutOfFile;
        if (seg.memsz < seg.filesz) return error.BadProgramHeaders;
        if (info.load_count == MAX_LOADS) return error.TooManySegments;
        info.load_buf[info.load_count] = seg;
        info.load_count += 1;
    }
    return info;
}

pub const Report = struct {
    size: usize,
    elf: ?ElfInfo,
    elf_error: ?ElfError,
    mb1: ?Mb1Header,
    mb2: ?multiboot2.HeaderSummary,

    pub fn mb1Phys(self: *const Report) ?u64 {
        const h = self.mb1 orelse return null;
        const e = self.elf orelse return null;
        return e.fileOffsetToPhys(h.offset);
    }

    pub fn mb2Phys(self: *const Report) ?u64 {
        const h = self.mb2 orelse return null;
        const e = self.elf orelse return null;
        return e.fileOffsetToPhys(h.offset);
    }

    /// A loader can boot the image through multiboot2 and, for ELF images,
    /// the header bytes are part of a loaded segment.
    pub fn bootableMultiboot2(self: *const Report) bool {
        if (self.mb2 == null) return false;
        if (self.elf != null) return self.mb2Phys() != null;
        return self.elf_error.? == error.NotElf;
    }
};

pub fn inspect(image: []const u8) Report {
    var report = Report{
        .size = image.len,
        .elf = null,
        .elf_error = null,
        .mb1 = findMultiboot1(image),
        .mb2 = multiboot2.findHeader(image),
    };
    if (parseElf64(image)) |e| {
        report.elf = e;
    } else |err| {
        report.elf_error = err;
    }
    return report;
}

fn segmentFlags(flags: u32) [3]u8 {
    return .{
        if (flags & 4 != 0) 'R' else '-',
        if (flags & 2 != 0) 'W' else '-',
        if (flags & 1 != 0) 'X' else '-',
    };
}

pub fn writeText(report: *const Report, image: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("image size: {d} bytes\n", .{report.size});
    if (report.elf) |*e| {
        try w.print("elf: ELF64 type={d} machine={d}{s} entry=0x{x}\n", .{
            e.elf_type, e.machine, if (e.machine == EM_X86_64) " (x86_64)" else "", e.entry,
        });
        for (e.loads()) |s| {
            const f = segmentFlags(s.flags);
            try w.print("  load offset=0x{x} paddr=0x{x} vaddr=0x{x} filesz=0x{x} memsz=0x{x} {s}\n", .{
                s.offset, s.paddr, s.vaddr, s.filesz, s.memsz, &f,
            });
        }
    } else {
        try w.print("elf: {s}\n", .{@errorName(report.elf_error.?)});
    }
    if (report.mb1) |h| {
        try w.print("multiboot1: offset=0x{x} flags=0x{x:0>8} checksum=0x{x:0>8}", .{ h.offset, h.flags, h.checksum });
        if (report.mb1Phys()) |p| try w.print(" paddr=0x{x}", .{p});
        try w.writeAll("\n");
    } else {
        try w.writeAll("multiboot1: not found\n");
    }
    if (report.mb2) |*h| {
        try w.print("multiboot2: offset=0x{x} arch={d} length={d} checksum=0x{x:0>8}", .{ h.offset, h.architecture, h.header_length, h.checksum });
        if (report.mb2Phys()) |p| try w.print(" paddr=0x{x}", .{p});
        try w.writeAll("\n");
        for (h.tags()) |t| {
            const name = (@as(multiboot2.HeaderTagType, @fromBackingInt(@intCast(t.tag_type)))).name();
            try w.print("  tag {s} type={d} flags=0x{x} size={d}", .{ name, t.tag_type, t.flags, t.size });
            if (t.tag_type == @backingInt(multiboot2.HeaderTagType.information_request)) {
                var req: [16]u32 = undefined;
                const n = h.requestedInfo(image, &req);
                try w.writeAll(" requests=");
                for (req[0..n], 0..) |r, i| {
                    if (i != 0) try w.writeAll(",");
                    try w.print("{d}", .{r});
                }
            }
            try w.writeAll("\n");
        }
    } else {
        try w.writeAll("multiboot2: not found\n");
    }
    try w.print("multiboot2 bootable: {s}\n", .{if (report.bootableMultiboot2()) "yes" else "no"});
}

pub fn writeJson(report: *const Report, image: []const u8, path: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("{\"path\":");
    try std.json.Stringify.encodeJsonString(path, .{}, w);
    try w.print(",\"size\":{d},\"elf\":", .{report.size});
    if (report.elf) |*e| {
        try w.print("{{\"type\":{d},\"machine\":{d},\"entry\":{d},\"loads\":[", .{ e.elf_type, e.machine, e.entry });
        for (e.loads(), 0..) |s, i| {
            if (i != 0) try w.writeAll(",");
            const f = segmentFlags(s.flags);
            try w.print("{{\"offset\":{d},\"paddr\":{d},\"vaddr\":{d},\"filesz\":{d},\"memsz\":{d},\"flags\":\"{s}\"}}", .{
                s.offset, s.paddr, s.vaddr, s.filesz, s.memsz, &f,
            });
        }
        try w.writeAll("]}");
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"elf_error\":");
    if (report.elf_error) |err| try w.print("\"{s}\"", .{@errorName(err)}) else try w.writeAll("null");
    try w.writeAll(",\"multiboot1\":");
    if (report.mb1) |h| {
        try w.print("{{\"offset\":{d},\"flags\":{d},\"checksum\":{d},\"paddr\":", .{ h.offset, h.flags, h.checksum });
        if (report.mb1Phys()) |p| try w.print("{d}", .{p}) else try w.writeAll("null");
        try w.writeAll("}");
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"multiboot2\":");
    if (report.mb2) |*h| {
        try w.print("{{\"offset\":{d},\"architecture\":{d},\"length\":{d},\"checksum\":{d},\"paddr\":", .{ h.offset, h.architecture, h.header_length, h.checksum });
        if (report.mb2Phys()) |p| try w.print("{d}", .{p}) else try w.writeAll("null");
        try w.writeAll(",\"tags\":[");
        for (h.tags(), 0..) |t, i| {
            if (i != 0) try w.writeAll(",");
            const name = (@as(multiboot2.HeaderTagType, @fromBackingInt(@intCast(t.tag_type)))).name();
            try w.print("{{\"name\":\"{s}\",\"type\":{d},\"flags\":{d},\"size\":{d}", .{ name, t.tag_type, t.flags, t.size });
            if (t.tag_type == @backingInt(multiboot2.HeaderTagType.information_request)) {
                var req: [16]u32 = undefined;
                const n = h.requestedInfo(image, &req);
                try w.writeAll(",\"requests\":[");
                for (req[0..n], 0..) |r, j| {
                    if (j != 0) try w.writeAll(",");
                    try w.print("{d}", .{r});
                }
                try w.writeAll("]");
            }
            try w.writeAll("}");
        }
        try w.writeAll("]}");
    } else {
        try w.writeAll("null");
    }
    try w.print(",\"multiboot2_bootable\":{s}}}\n", .{if (report.bootableMultiboot2()) "true" else "false"});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Builds a minimal ELF64 x86_64 image with one PT_LOAD that covers a
/// multiboot2 header placed at file offset 0x1000, loaded at 1 MiB.
fn buildTestElf(buf: []u8) []u8 {
    @memset(buf, 0);
    @memcpy(buf[0..4], "\x7fELF");
    buf[4] = 2;
    buf[5] = 1;
    buf[6] = 1;
    std.mem.writeInt(u16, buf[16..18], 2, .little);
    std.mem.writeInt(u16, buf[18..20], EM_X86_64, .little);
    std.mem.writeInt(u64, buf[24..32], 0x101000, .little);
    std.mem.writeInt(u64, buf[32..40], 64, .little);
    std.mem.writeInt(u16, buf[52..54], 64, .little);
    std.mem.writeInt(u16, buf[54..56], 56, .little);
    std.mem.writeInt(u16, buf[56..58], 1, .little);
    const ph = buf[64..];
    std.mem.writeInt(u32, ph[0..4], PT_LOAD, .little);
    std.mem.writeInt(u32, ph[4..8], 5, .little);
    std.mem.writeInt(u64, ph[8..16], 0x1000, .little);
    std.mem.writeInt(u64, ph[16..24], 0x100000, .little);
    std.mem.writeInt(u64, ph[24..32], 0x100000, .little);
    std.mem.writeInt(u64, ph[32..40], 0x100, .little);
    std.mem.writeInt(u64, ph[40..48], 0x100, .little);
    const hdr = multiboot2.KernelHeader.make();
    @memcpy(buf[0x1010..][0..48], std.mem.asBytes(&hdr));
    // multiboot1 header right before it.
    std.mem.writeInt(u32, buf[0x1000..][0..4], MB1_MAGIC, .little);
    std.mem.writeInt(u32, buf[0x1004..][0..4], 3, .little);
    std.mem.writeInt(u32, buf[0x1008..][0..4], 0 -% (MB1_MAGIC +% 3), .little);
    return buf[0..0x1100];
}

test "inspect reports ELF loads and header physical addresses" {
    var buf: [0x1100]u8 = undefined;
    const image = buildTestElf(&buf);
    const r = inspect(image);
    try testing.expect(r.elf != null);
    try testing.expectEqual(@as(u64, 0x101000), r.elf.?.entry);
    try testing.expectEqual(@as(usize, 1), r.elf.?.loads().len);
    try testing.expectEqual(@as(usize, 0x1000), r.mb1.?.offset);
    try testing.expectEqual(@as(usize, 0x1010), r.mb2.?.offset);
    try testing.expectEqual(@as(?u64, 0x100000), r.mb1Phys());
    try testing.expectEqual(@as(?u64, 0x100010), r.mb2Phys());
    try testing.expect(r.bootableMultiboot2());
}

test "header outside every loaded segment is not bootable" {
    var buf: [0x1100]u8 = undefined;
    const image = buildTestElf(&buf);
    // Shrink the segment so the multiboot2 header is no longer loaded.
    std.mem.writeInt(u64, image[64 + 32 ..][0..8], 0x10, .little);
    const r = inspect(image);
    try testing.expect(r.mb2 != null);
    try testing.expect(r.mb2Phys() == null);
    try testing.expect(!r.bootableMultiboot2());
}

test "raw image without ELF wrapper is judged on the header alone" {
    var buf: [256]u8 = @splat(0);
    const hdr = multiboot2.KernelHeader.make();
    @memcpy(buf[8..][0..48], std.mem.asBytes(&hdr));
    const r = inspect(&buf);
    try testing.expectEqual(ElfError.NotElf, r.elf_error.?);
    try testing.expect(r.bootableMultiboot2());
}

test "hostile ELF headers are rejected without out-of-bounds reads" {
    var buf: [0x1100]u8 = undefined;
    const image = buildTestElf(&buf);

    var work: [0x1100]u8 = undefined;
    @memcpy(&work, image);
    std.mem.writeInt(u64, work[32..40], 0xFFFF_FFFF_FFFF_FFF0, .little); // phoff overflow
    try testing.expectError(error.BadProgramHeaders, parseElf64(&work));

    @memcpy(&work, image);
    std.mem.writeInt(u16, work[56..58], 0xFFFF, .little); // phnum past file end
    try testing.expectError(error.BadProgramHeaders, parseElf64(&work));

    @memcpy(&work, image);
    std.mem.writeInt(u16, work[54..56], 8, .little); // phentsize too small
    try testing.expectError(error.BadProgramHeaders, parseElf64(&work));

    @memcpy(&work, image);
    std.mem.writeInt(u64, work[64 + 32 ..][0..8], 0xFFFF_FFFF, .little); // filesz past end
    try testing.expectError(error.SegmentOutOfFile, parseElf64(&work));

    @memcpy(&work, image);
    std.mem.writeInt(u64, work[64 + 40 ..][0..8], 0x10, .little); // memsz < filesz
    try testing.expectError(error.BadProgramHeaders, parseElf64(&work));

    @memcpy(&work, image);
    work[4] = 1;
    try testing.expectError(error.NotElf64, parseElf64(&work));
    work[4] = 2;
    work[5] = 2;
    try testing.expectError(error.NotLittleEndian, parseElf64(&work));
    try testing.expectError(error.Truncated, parseElf64(image[0..20]));
    try testing.expectError(error.NotElf, parseElf64(image[0..2]));

    // Random corruption of the first 128 bytes never crashes.
    var prng = std.Random.DefaultPrng.init(0xE1F64);
    const rand = prng.random();
    for (0..5000) |_| {
        @memcpy(&work, image);
        for (0..3) |_| work[rand.uintLessThan(usize, 128)] = rand.int(u8);
        const r = inspect(&work);
        _ = r.mb2Phys();
        _ = r.bootableMultiboot2();
    }
}

test "text and JSON reports carry the same facts" {
    var buf: [0x1100]u8 = undefined;
    const image = buildTestElf(&buf);
    const r = inspect(image);

    var text_buf: [2048]u8 = undefined;
    var tw = std.Io.Writer.fixed(&text_buf);
    try writeText(&r, image, &tw);
    const text = tw.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "multiboot2: offset=0x1010 arch=0 length=48") != null);
    try testing.expect(std.mem.indexOf(u8, text, "paddr=0x100010") != null);
    try testing.expect(std.mem.indexOf(u8, text, "requests=6,1,2,4") != null);
    try testing.expect(std.mem.indexOf(u8, text, "multiboot2 bootable: yes") != null);

    var json_buf: [4096]u8 = undefined;
    var jw = std.Io.Writer.fixed(&json_buf);
    try writeJson(&r, image, "dir/k\"ernel.elf", &jw);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, jw.buffered(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqualStrings("dir/k\"ernel.elf", root.get("path").?.string);
    const mb2 = root.get("multiboot2").?.object;
    try testing.expectEqual(@as(i64, 0x1010), mb2.get("offset").?.integer);
    try testing.expectEqual(@as(i64, 0x100010), mb2.get("paddr").?.integer);
    try testing.expectEqual(@as(usize, 2), mb2.get("tags").?.array.items.len);
    try testing.expect(root.get("multiboot2_bootable").?.bool);
    try testing.expect(root.get("elf_error").? == .null);
}
