# Realgar

Bare-Metal x86_64 Long Mode Micro-Kernel Stub

A bootable, freestanding Multiboot/UEFI micro-kernel harness written in 100% pure Zig without external assembly files or NASM toolchains.

## Architecture

- Pure Zig Kernel Entry: Naked entry point `_start` directly initializes machine state with zero external assembly boilerplate.
- 4-Level Paging (PML4): Establishes identity-mapped physical memory using 2MB huge pages across PML4, PDPT, and Page Directory structures.
- 16550 UART Serial Console: Direct port I/O driver (`0x3F8` COM1) operating at 115200 baud (8N1) with FIFO buffering.
- GDT & IDT Descriptors: Full 64-bit segment descriptors (Kernel CS `0x08`, Kernel DS `0x10`) and 256-entry interrupt gate table.
- Compact Binary Footprint: Generates a freestanding 16 KB ELF binary ready for QEMU, Bochs, or physical multiboot bootloaders.

## Memory Map

```
0x0000_0000 - 0x000F_FFFF : Real Mode & BIOS Area (Identity Mapped)
0x0010_0000 - 0x0010_4000 : Realgar Micro-Kernel ELF (.multiboot, .text, .rodata)
0x0010_4000 - 0x0010_8000 : Static Kernel Stack (16 KB aligned)
0x0010_8000 - 0x0100_0000 : 16 MB Identity Mapped Physical Range
```

## Running with QEMU

```bash
# Launch kernel with QEMU serial output directed to stdio
qemu-system-x86_64 -kernel zig-out/bin/realgar.elf -serial stdio -display none
```

## Building and Testing

```bash
# Run unit tests on host
zig build test

# Compile freestanding x86_64 micro-kernel ELF
zig build -Doptimize=ReleaseSmall
```

## License

MIT License - Copyright (c) 2026 Jeong Hoon Kim
