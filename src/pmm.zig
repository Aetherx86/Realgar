//! Bitmap physical frame allocator. One bit per 4 KiB frame starting at
//! physical address 0; a set bit means the frame is in use. The bitmap storage
//! is supplied by the caller, so the allocator itself never allocates.
//!
//! Initialization from a firmware memory map is conservative: every frame
//! starts in use, available regions are released (rounded inward to whole
//! frames), and then every non-available region and every caller-supplied
//! reserved range is claimed again (rounded outward). Overlapping or
//! contradictory map entries therefore resolve to "in use".

const std = @import("std");
const multiboot2 = @import("multiboot2.zig");

pub const FRAME_SIZE: u64 = 4096;
const FRAME_SHIFT: u6 = 12;

pub const Error = error{
    Misaligned,
    OutOfRange,
    DoubleFree,
    InvalidCount,
};

pub const Range = struct {
    base: u64,
    length: u64,

    pub fn end(self: Range) u64 {
        return self.base +| self.length;
    }
};

pub fn wordsForFrames(frame_count: u64) usize {
    return @intCast((frame_count + 63) / 64);
}

pub const Stats = struct {
    total_frames: u64,
    free_frames: u64,

    pub fn usedFrames(self: Stats) u64 {
        return self.total_frames - self.free_frames;
    }
};

pub const BitmapAllocator = struct {
    words: []u64,
    frame_count: u64,
    free_frames: u64,
    /// Word index where the next single-frame search starts (next-fit).
    hint: usize,

    /// Creates an allocator tracking `frame_count` frames with every frame in use.
    /// `frame_count` is clamped to what the bitmap can describe.
    pub fn init(words: []u64, frame_count: u64) BitmapAllocator {
        @memset(words, std.math.maxInt(u64));
        const capacity = @as(u64, words.len) * 64;
        return .{
            .words = words,
            .frame_count = @min(frame_count, capacity),
            .free_frames = 0,
            .hint = 0,
        };
    }

    pub fn stats(self: *const BitmapAllocator) Stats {
        return .{ .total_frames = self.frame_count, .free_frames = self.free_frames };
    }

    inline fn isSet(self: *const BitmapAllocator, frame: u64) bool {
        const w = self.words[@intCast(frame / 64)];
        return (w >> @as(u6, @intCast(frame % 64))) & 1 != 0;
    }

    inline fn setBit(self: *BitmapAllocator, frame: u64) void {
        self.words[@intCast(frame / 64)] |= @as(u64, 1) << @as(u6, @intCast(frame % 64));
    }

    inline fn clearBit(self: *BitmapAllocator, frame: u64) void {
        self.words[@intCast(frame / 64)] &= ~(@as(u64, 1) << @as(u6, @intCast(frame % 64)));
    }

    /// Frames fully contained in [base, base+length), clamped to the tracked range.
    fn innerFrames(self: *const BitmapAllocator, base: u64, length: u64) [2]u64 {
        const end = base +| length;
        const first = std.math.divCeil(u64, base, FRAME_SIZE) catch unreachable;
        const last = @min(end / FRAME_SIZE, self.frame_count);
        return .{ @min(first, last), last };
    }

    /// Frames touched by [base, base+length), clamped to the tracked range.
    fn outerFrames(self: *const BitmapAllocator, base: u64, length: u64) [2]u64 {
        if (length == 0) return .{ 0, 0 };
        const end = base +| length;
        const first = @min(base / FRAME_SIZE, self.frame_count);
        const last = @min(std.math.divCeil(u64, end, FRAME_SIZE) catch unreachable, self.frame_count);
        return .{ first, @max(first, last) };
    }

    /// Marks every whole frame inside the range as free.
    pub fn addFreeRegion(self: *BitmapAllocator, base: u64, length: u64) void {
        const r = self.innerFrames(base, length);
        var f = r[0];
        while (f < r[1]) : (f += 1) {
            if (self.isSet(f)) {
                self.clearBit(f);
                self.free_frames += 1;
            }
        }
    }

    /// Marks every frame the range touches as in use.
    pub fn reserveRegion(self: *BitmapAllocator, base: u64, length: u64) void {
        const r = self.outerFrames(base, length);
        var f = r[0];
        while (f < r[1]) : (f += 1) {
            if (!self.isSet(f)) {
                self.setBit(f);
                self.free_frames -= 1;
            }
        }
    }

    pub fn isFree(self: *const BitmapAllocator, addr: u64) bool {
        const frame = addr / FRAME_SIZE;
        if (frame >= self.frame_count) return false;
        return !self.isSet(frame);
    }

    /// Allocates one frame and returns its physical address.
    pub fn alloc(self: *BitmapAllocator) ?u64 {
        if (self.free_frames == 0) return null;
        const nwords = wordsForFrames(self.frame_count);
        var i: usize = 0;
        while (i < nwords) : (i += 1) {
            const wi = (self.hint + i) % nwords;
            const w = self.words[wi];
            if (w == std.math.maxInt(u64)) continue;
            const bit: u64 = @ctz(~w);
            const frame = @as(u64, wi) * 64 + bit;
            // Bits past frame_count are never cleared, so this only guards the last word.
            if (frame >= self.frame_count) continue;
            self.setBit(frame);
            self.free_frames -= 1;
            self.hint = wi;
            return frame << FRAME_SHIFT;
        }
        return null;
    }

    /// Allocates `count` physically contiguous frames whose first frame index is a
    /// multiple of `align_frames` (a power of two). Returns the base address.
    pub fn allocContiguous(self: *BitmapAllocator, count: u64, align_frames: u64) ?u64 {
        if (count == 0 or align_frames == 0 or !std.math.isPowerOfTwo(align_frames)) return null;
        if (count > self.free_frames) return null;
        var start: u64 = 0;
        while (start + count <= self.frame_count) {
            var run: u64 = 0;
            while (run < count and !self.isSet(start + run)) : (run += 1) {}
            if (run == count) {
                var f = start;
                while (f < start + count) : (f += 1) self.setBit(f);
                self.free_frames -= count;
                return start << FRAME_SHIFT;
            }
            // Skip past the used frame that broke the run, then realign.
            const next = start + run + 1;
            start = std.mem.alignForward(u64, next, align_frames);
        }
        return null;
    }

    /// Returns one frame. Rejects unaligned, untracked and already-free addresses.
    pub fn free(self: *BitmapAllocator, addr: u64) Error!void {
        return self.freeContiguous(addr, 1);
    }

    /// Returns `count` frames starting at `addr`. Validates the whole run first,
    /// so a rejected call changes nothing.
    pub fn freeContiguous(self: *BitmapAllocator, addr: u64, count: u64) Error!void {
        if (count == 0) return error.InvalidCount;
        if (addr % FRAME_SIZE != 0) return error.Misaligned;
        const first = addr / FRAME_SIZE;
        if (first >= self.frame_count or count > self.frame_count - first) return error.OutOfRange;
        var f = first;
        while (f < first + count) : (f += 1) {
            if (!self.isSet(f)) return error.DoubleFree;
        }
        f = first;
        while (f < first + count) : (f += 1) self.clearBit(f);
        self.free_frames += count;
        self.hint = @intCast(first / 64);
    }

    /// Builds an allocator from a multiboot2 memory map. Frames above what the
    /// bitmap can describe are ignored. `reserved` ranges (kernel image, boot
    /// information, the bitmap itself, low memory) are never handed out.
    pub fn fromMemoryMap(words: []u64, map: multiboot2.MemoryMap, reserved: []const Range) BitmapAllocator {
        var highest: u64 = 0;
        var it = map.iterator();
        while (it.next()) |r| {
            if (r.kind == .available) highest = @max(highest, r.end());
        }
        var self = init(words, highest / FRAME_SIZE);
        it = map.iterator();
        while (it.next()) |r| {
            if (r.kind == .available) self.addFreeRegion(r.base, r.length);
        }
        it = map.iterator();
        while (it.next()) |r| {
            if (r.kind != .available) self.reserveRegion(r.base, r.length);
        }
        for (reserved) |r| self.reserveRegion(r.base, r.length);
        return self;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "init marks everything used and clamps to bitmap capacity" {
    var words: [2]u64 = undefined;
    var a = BitmapAllocator.init(&words, 1000);
    try testing.expectEqual(@as(u64, 128), a.frame_count);
    try testing.expectEqual(@as(u64, 0), a.free_frames);
    try testing.expect(a.alloc() == null);
}

test "free region rounding is inward and reservations are outward" {
    var words: [4]u64 = undefined;
    var a = BitmapAllocator.init(&words, 256);
    // [0x1800, 0x5800) contains whole frames 2,3,4.
    a.addFreeRegion(0x1800, 0x4000);
    try testing.expectEqual(@as(u64, 3), a.free_frames);
    try testing.expect(!a.isFree(0x1000));
    try testing.expect(a.isFree(0x2000));
    try testing.expect(a.isFree(0x4000));
    try testing.expect(!a.isFree(0x5000));
    // A single byte at 0x3FFF reserves frame 3.
    a.reserveRegion(0x3FFF, 1);
    try testing.expect(!a.isFree(0x3000));
    try testing.expectEqual(@as(u64, 2), a.free_frames);
    // Zero-length reservations are no-ops.
    a.reserveRegion(0x2000, 0);
    try testing.expect(a.isFree(0x2000));
}

test "alloc returns ascending frames and free makes them reusable" {
    var words: [1]u64 = undefined;
    var a = BitmapAllocator.init(&words, 64);
    a.addFreeRegion(0x10000, 4 * FRAME_SIZE);
    try testing.expectEqual(@as(?u64, 0x10000), a.alloc());
    try testing.expectEqual(@as(?u64, 0x11000), a.alloc());
    try testing.expectEqual(@as(?u64, 0x12000), a.alloc());
    try testing.expectEqual(@as(?u64, 0x13000), a.alloc());
    try testing.expect(a.alloc() == null);
    try a.free(0x11000);
    try testing.expectEqual(@as(?u64, 0x11000), a.alloc());
}

test "free rejects double frees, misalignment and untracked frames" {
    var words: [1]u64 = undefined;
    var a = BitmapAllocator.init(&words, 16);
    a.addFreeRegion(0, 16 * FRAME_SIZE);
    const f = a.alloc().?;
    try a.free(f);
    try testing.expectError(error.DoubleFree, a.free(f));
    try testing.expectError(error.Misaligned, a.free(f + 8));
    try testing.expectError(error.OutOfRange, a.free(16 * FRAME_SIZE));
    try testing.expectError(error.OutOfRange, a.freeContiguous(15 * FRAME_SIZE, 2));
    try testing.expectError(error.InvalidCount, a.freeContiguous(0, 0));
    try testing.expectEqual(@as(u64, 16), a.free_frames);
}

test "freeContiguous is all-or-nothing" {
    var words: [1]u64 = undefined;
    var a = BitmapAllocator.init(&words, 64);
    a.addFreeRegion(0, 64 * FRAME_SIZE);
    const base = a.allocContiguous(4, 1).?;
    try a.free(base + 2 * FRAME_SIZE);
    const before = a.free_frames;
    try testing.expectError(error.DoubleFree, a.freeContiguous(base, 4));
    try testing.expectEqual(before, a.free_frames);
    try testing.expect(!a.isFree(base));
}

test "allocContiguous honours alignment and skips holes" {
    var words: [8]u64 = undefined;
    var a = BitmapAllocator.init(&words, 512);
    a.addFreeRegion(0, 512 * FRAME_SIZE);
    a.reserveRegion(0, FRAME_SIZE); // frame 0 used
    a.reserveRegion(10 * FRAME_SIZE, FRAME_SIZE); // hole at frame 10

    // 8 frames: frames 1..8 fit with no alignment requirement.
    try testing.expectEqual(@as(?u64, FRAME_SIZE), a.allocContiguous(8, 1));
    // 16 frames aligned to 16: 0..15 is blocked, 16..31 is free.
    try testing.expectEqual(@as(?u64, 16 * FRAME_SIZE), a.allocContiguous(16, 16));
    // 2 MiB (512 frames) aligned run cannot fit any more.
    try testing.expect(a.allocContiguous(512, 512) == null);
    // Invalid parameters.
    try testing.expect(a.allocContiguous(0, 1) == null);
    try testing.expect(a.allocContiguous(1, 3) == null);
}

test "fromMemoryMap applies map, overlaps and reserved ranges" {
    var buf: [512]u8 align(8) = undefined;
    var b = try multiboot2.InfoBuilder.init(&buf);
    try b.addMemoryMap(&.{
        .{ .base = 0, .length = 0x9FC00, .kind = .available },
        .{ .base = 0x9FC00, .length = 0x60400, .kind = .reserved },
        .{ .base = 0x100000, .length = 0x700000, .kind = .available }, // 1 MiB .. 8 MiB
        // Firmware claims part of the available range as ACPI data: reserved wins.
        .{ .base = 0x400000, .length = 0x2000, .kind = .acpi_reclaimable },
        .{ .base = 0xFEC00000, .length = 0x1000, .kind = .reserved },
    });
    const info = try multiboot2.BootInfo.parse(try b.finish());

    var words: [wordsForFrames(0x800000 / FRAME_SIZE)]u64 = undefined;
    const kernel = Range{ .base = 0x100000, .length = 0x5000 };
    const low = Range{ .base = 0, .length = 0x100000 };
    var a = BitmapAllocator.fromMemoryMap(&words, info.memoryMap().?, &.{ low, kernel });

    try testing.expectEqual(@as(u64, 0x800), a.frame_count);
    // 0x700000 bytes = 1792 frames, minus 5 kernel frames, minus 2 ACPI frames.
    try testing.expectEqual(@as(u64, 1792 - 5 - 2), a.free_frames);
    try testing.expect(!a.isFree(0x0));
    try testing.expect(!a.isFree(0x104000));
    try testing.expect(a.isFree(0x105000));
    try testing.expect(!a.isFree(0x400000));
    try testing.expect(!a.isFree(0x401000));
    try testing.expect(a.isFree(0x402000));
    // The first allocation comes after the kernel image.
    try testing.expectEqual(@as(?u64, 0x105000), a.alloc());
}

test "fromMemoryMap ignores memory beyond bitmap capacity and saturates huge lengths" {
    var buf: [256]u8 align(8) = undefined;
    var b = try multiboot2.InfoBuilder.init(&buf);
    try b.addMemoryMap(&.{
        .{ .base = 0x100000, .length = std.math.maxInt(u64), .kind = .available },
    });
    const info = try multiboot2.BootInfo.parse(try b.finish());
    var words: [4]u64 = undefined; // 256 frames = 1 MiB
    const a = BitmapAllocator.fromMemoryMap(&words, info.memoryMap().?, &.{});
    try testing.expectEqual(@as(u64, 256), a.frame_count);
    // Everything tracked is below 1 MiB, which the map does not list as available.
    try testing.expectEqual(@as(u64, 0), a.free_frames);
}

test "randomized operations agree with a reference model" {
    const N = 300;
    var words: [wordsForFrames(N)]u64 = undefined;
    var a = BitmapAllocator.init(&words, N);
    var model: [N]bool = @splat(true); // true = used

    var prng = std.Random.DefaultPrng.init(0xF4A3E5);
    const rand = prng.random();
    var held: [N]u64 = undefined;
    var nheld: usize = 0;

    for (0..20000) |_| {
        switch (rand.uintLessThan(u8, 6)) {
            0 => {
                const base = rand.uintLessThan(u64, N * FRAME_SIZE);
                const len = rand.uintLessThan(u64, 16 * FRAME_SIZE);
                a.addFreeRegion(base, len);
                const first = std.math.divCeil(u64, base, FRAME_SIZE) catch unreachable;
                const last = @min((base + len) / FRAME_SIZE, N);
                var f = first;
                while (f < last) : (f += 1) model[@intCast(f)] = false;
                // Frames the model freed may have been held; drop them from the held list.
                var i: usize = 0;
                while (i < nheld) {
                    if (!model[@intCast(held[i] / FRAME_SIZE)]) {
                        held[i] = held[nheld - 1];
                        nheld -= 1;
                    } else i += 1;
                }
            },
            1 => {
                const base = rand.uintLessThan(u64, N * FRAME_SIZE);
                const len = rand.uintLessThan(u64, 4 * FRAME_SIZE);
                a.reserveRegion(base, len);
                if (len > 0) {
                    const first = base / FRAME_SIZE;
                    const last = @min(std.math.divCeil(u64, base + len, FRAME_SIZE) catch unreachable, N);
                    var f = first;
                    while (f < last) : (f += 1) model[@intCast(f)] = true;
                }
            },
            2, 3 => if (a.alloc()) |addr| {
                const f: usize = @intCast(addr / FRAME_SIZE);
                try testing.expect(!model[f]);
                model[f] = true;
                held[nheld] = addr;
                nheld += 1;
            } else {
                for (model) |used| try testing.expect(used);
            },
            4 => if (nheld > 0) {
                const i = rand.uintLessThan(usize, nheld);
                const addr = held[i];
                held[i] = held[nheld - 1];
                nheld -= 1;
                try a.free(addr);
                model[@intCast(addr / FRAME_SIZE)] = false;
            },
            else => {
                const count = rand.intRangeAtMost(u64, 1, 8);
                const al = @as(u64, 1) << rand.uintLessThan(u6, 4);
                if (a.allocContiguous(count, al)) |addr| {
                    const f = addr / FRAME_SIZE;
                    try testing.expect(f % al == 0);
                    var k: u64 = 0;
                    while (k < count) : (k += 1) {
                        try testing.expect(!model[@intCast(f + k)]);
                        model[@intCast(f + k)] = true;
                    }
                }
            },
        }
        var free_model: u64 = 0;
        for (model) |used| {
            if (!used) free_model += 1;
        }
        try testing.expectEqual(free_model, a.free_frames);
    }
    for (model, 0..) |used, f| try testing.expectEqual(!used, a.isFree(f * FRAME_SIZE));
}
