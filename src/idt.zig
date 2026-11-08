const std = @import("std");

pub const IdtGate = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u3,
    reserved0: u5,
    gate_type: u4,
    zero: u1,
    dpl: u2,
    present: u1,
    offset_mid: u16,
    offset_high: u32,
    reserved1: u32,

    pub const NULL: IdtGate = IdtGate{
        .offset_low = 0,
        .selector = 0,
        .ist = 0,
        .reserved0 = 0,
        .gate_type = 0,
        .zero = 0,
        .dpl = 0,
        .present = 0,
        .offset_mid = 0,
        .offset_high = 0,
        .reserved1 = 0,
    };

    pub fn make(handler_addr: u64, selector: u16, is_trap: bool, dpl: u2) IdtGate {
        return IdtGate{
            .offset_low = @as(u16, @truncate(handler_addr)),
            .selector = selector,
            .ist = 0,
            .reserved0 = 0,
            .gate_type = if (is_trap) 0xF else 0xE, // 0xE = 64-bit Interrupt Gate, 0xF = Trap Gate
            .zero = 0,
            .dpl = dpl,
            .present = 1,
            .offset_mid = @as(u16, @truncate(handler_addr >> 16)),
            .offset_high = @as(u32, @truncate(handler_addr >> 32)),
            .reserved1 = 0,
        };
    }

    pub fn getHandlerAddress(self: *const IdtGate) u64 {
        const low = @as(u64, self.offset_low);
        const mid = @as(u64, self.offset_mid) << 16;
        const high = @as(u64, self.offset_high) << 32;
        return high | mid | low;
    }
};

pub const Idtr = packed struct {
    limit: u16,
    base: u64,
};

pub const NUM_IDT_ENTRIES: usize = 256;

pub const IdtTable = struct {
    entries: [NUM_IDT_ENTRIES]IdtGate,

    pub fn init() IdtTable {
        var table: IdtTable = undefined;
        var null_gate: IdtGate = undefined;
        @memset(std.mem.asBytes(&null_gate), 0);
        @memset(&table.entries, null_gate);
        return table;
    }

    pub fn setGate(self: *IdtTable, vector: u8, handler: u64, selector: u16, is_trap: bool, dpl: u2) void {
        self.entries[vector] = IdtGate.make(handler, selector, is_trap, dpl);
    }

    pub fn getDescriptor(self: *const IdtTable) Idtr {
        return .{
            .limit = @as(u16, @sizeOf([NUM_IDT_ENTRIES]IdtGate) - 1),
            .base = @intFromPtr(&self.entries),
        };
    }
};

test "IDT Gate address packing and reconstruction" {
    const target: u64 = 0xFFFFFFFF80102030;
    const gate = IdtGate.make(target, 0x08, false, 0);

    try std.testing.expectEqual(target, gate.getHandlerAddress());
    try std.testing.expectEqual(@as(u16, 0x08), gate.selector);
    try std.testing.expectEqual(@as(u1, 1), gate.present);
    try std.testing.expectEqual(@as(u4, 0xE), gate.gate_type);
}

test "IDT Table descriptor" {
    var table = IdtTable.init();
    table.setGate(14, 0x1000, 0x08, false, 0); // Page fault

    const desc = table.getDescriptor();
    try std.testing.expectEqual(@as(u16, 4095), desc.limit); // 256 * 16 - 1 = 4095
    try std.testing.expectEqual(@as(u64, 0x1000), table.entries[14].getHandlerAddress());
}
