const std = @import("std");
const builtin = @import("builtin");

pub const COM1_BASE: u16 = 0x3F8;

pub const Register = enum(u16) {
    data = 0,
    ier = 1,
    fcr = 2,
    lcr = 3,
    mcr = 4,
    lsr = 5,
    msr = 6,
    scr = 7,
};

pub const LsrFlags = struct {
    pub const DATA_READY: u8 = 1 << 0;
    pub const OVERRUN_ERROR: u8 = 1 << 1;
    pub const PARITY_ERROR: u8 = 1 << 2;
    pub const FRAMING_ERROR: u8 = 1 << 3;
    pub const BREAK_SIGNAL: u8 = 1 << 4;
    pub const TRANSMITTER_EMPTY: u8 = 1 << 5;
    pub const IMPENDING_TRANSMISSION: u8 = 1 << 6;
    pub const FIFO_ERROR: u8 = 1 << 7;
};

// Low-level port I/O
pub inline fn outb(port: u16, val: u8) void {
    if (builtin.cpu.arch == .x86_64 and builtin.os.tag == .freestanding) {
        asm volatile ("outb %[val], %[port]"
            :
            : [val] "{al}" (val),
              [port] "{dx}" (port),
        );
    } else {
        // Mock capture for unit testing
        mockOutb(port, val);
    }
}

pub inline fn inb(port: u16) u8 {
    if (builtin.cpu.arch == .x86_64 and builtin.os.tag == .freestanding) {
        return asm volatile ("inb %[port], %[ret]"
            : [ret] "={al}" (-> u8),
            : [port] "{dx}" (port),
        );
    } else {
        // Mock read for unit testing (transmitter always ready)
        if (port == COM1_BASE + @intFromEnum(Register.lsr)) {
            return LsrFlags.TRANSMITTER_EMPTY;
        }
        return 0;
    }
}

// Mock test ring buffer for host unit tests
var mock_tx_buffer: [1024]u8 = undefined;
var mock_tx_len: usize = 0;
var mock_dlab: bool = false;

fn mockOutb(port: u16, val: u8) void {
    if (port == COM1_BASE + @intFromEnum(Register.lcr)) {
        mock_dlab = (val & 0x80) != 0;
    } else if (port == COM1_BASE + @intFromEnum(Register.data)) {
        if (!mock_dlab and mock_tx_len < mock_tx_buffer.len) {
            mock_tx_buffer[mock_tx_len] = val;
            mock_tx_len += 1;
        }
    }
}

pub fn getMockTxOutput() []const u8 {
    return mock_tx_buffer[0..mock_tx_len];
}

pub fn resetMockTx() void {
    mock_tx_len = 0;
    mock_dlab = false;
}

pub const SerialPort = struct {
    base_port: u16,

    pub fn init(base: u16) SerialPort {
        const self = SerialPort{ .base_port = base };

        // Disable all interrupts
        outb(base + @intFromEnum(Register.ier), 0x00);

        // Enable DLAB (set baud rate divisor)
        outb(base + @intFromEnum(Register.lcr), 0x80);

        // Set divisor to 1 (115200 baud)
        outb(base + @intFromEnum(Register.data), 0x01); // Divisor Low Byte
        outb(base + @intFromEnum(Register.ier), 0x00); // Divisor High Byte

        // 8 bits, no parity, one stop bit (8N1)
        outb(base + @intFromEnum(Register.lcr), 0x03);

        // Enable FIFO, clear TX/RX, 14-byte threshold
        outb(base + @intFromEnum(Register.fcr), 0xC7);

        // RTS/DSR set
        outb(base + @intFromEnum(Register.mcr), 0x0B);

        return self;
    }

    pub fn isTransmitEmpty(self: *const SerialPort) bool {
        return (inb(self.base_port + @intFromEnum(Register.lsr)) & LsrFlags.TRANSMITTER_EMPTY) != 0;
    }

    pub fn writeByte(self: *const SerialPort, b: u8) void {
        while (!self.isTransmitEmpty()) {
            if (builtin.cpu.arch == .x86_64 and builtin.os.tag == .freestanding) {
                asm volatile ("pause");
            }
        }
        outb(self.base_port + @intFromEnum(Register.data), b);
    }

    pub fn writeString(self: *const SerialPort, str: []const u8) void {
        for (str) |c| {
            if (c == '\n') self.writeByte('\r');
            self.writeByte(c);
        }
    }

    pub fn writeHexU64(self: *const SerialPort, val: u64) void {
        const hex_chars = "0123456789ABCDEF";
        self.writeString("0x");
        var i: usize = 16;
        while (i > 0) : (i -= 1) {
            const shift: u6 = @as(u6, @intCast((i - 1) * 4));
            const nibble: usize = @as(usize, @intCast((val >> shift) & 0xF));
            self.writeByte(hex_chars[nibble]);
        }
    }
};

test "Serial port initialization and write" {
    resetMockTx();
    const serial = SerialPort.init(COM1_BASE);
    serial.writeString("Realgar Microkernel Boot\n");

    const out = getMockTxOutput();
    try std.testing.expectEqualStrings("Realgar Microkernel Boot\r\n", out);
}

test "Serial hex formatting" {
    resetMockTx();
    const serial = SerialPort.init(COM1_BASE);
    serial.writeHexU64(0xDEADBEEFCAFEBABE);

    const out = getMockTxOutput();
    try std.testing.expectEqualStrings("0xDEADBEEFCAFEBABE", out);
}
