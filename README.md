# Realgar

Bare-Metal x86_64 Long Mode Micro-Kernel Stub

A freestanding x86_64 long-mode micro-kernel harness written in pure Zig without external assembly files or NASM toolchains. It carries multiboot1 and multiboot2 headers, but it has no 32-to-64-bit startup code yet, so a loader that enters in 32-bit protected mode (GRUB, QEMU `-kernel`) cannot start it directly.

## Architecture

- Pure Zig Kernel Entry: Naked entry point `_start` directly initializes machine state with zero external assembly boilerplate.
- 4-Level Paging (PML4): Establishes identity-mapped physical memory using 2MB huge pages across PML4, PDPT, and Page Directory structures.
- 16550 UART Serial Console: Direct port I/O driver (`0x3F8` COM1) operating at 115200 baud (8N1) with FIFO buffering.
- GDT & IDT Descriptors: Full 64-bit segment descriptors (Kernel CS `0x08`, Kernel DS `0x10`) and 256-entry interrupt gate table.
- Compact Binary Footprint: Generates a freestanding ELF64 image of about 21 KB (ReleaseSmall) carrying both a multiboot1 and a multiboot2 header.
- Multiboot2 Boot Information: Bounds-checked parser for the loader's boot information (memory map, command line, loader name, basic memory info).
- Physical Frame Allocator: Bitmap allocator over 4 KiB frames, built from the multiboot2 memory map.
- Page Table Builder: 4-level mapper with 4 KiB, 2 MiB and 1 GiB leaves, translation, unmapping, and an identity plus higher-half kernel layout.

## Memory Map

Physical layout of the ReleaseSmall kernel image as reported by `realgar inspect`:

```
0x0000_0000 - 0x000F_FFFF : Real Mode & BIOS Area (never handed out by the frame allocator)
0x0010_0000 - 0x0010_003C : .multiboot (multiboot2 header at 0x100000, multiboot1 header at 0x100030)
0x0010_1000 - 0x0010_2678 : .text (entry point 0x101000)
0x0010_3000 - 0x0010_35EC : .rodata
0x0010_4000 - 0x0012_E058 : .bss (GDT, IDT, 128 KiB frame bitmap, 8-table early page table pool)
```

The linker script exports `__kernel_start` and `__kernel_end` around this range so the kernel can keep it out of the free frame pool.

## Booting

There is no supported emulator command yet. QEMU's `-kernel` option only loads multiboot1 images in 32-bit mode and rejects ELF64 files, and GRUB also enters multiboot kernels in 32-bit protected mode. Booting needs a 32-to-64-bit trampoline, which is not implemented.

`_start` is 64-bit code and expects to be entered in long mode, with the multiboot2 magic in RDI and the boot information address in RSI (System V convention), for example from a 32-to-64-bit loader trampoline. Booting under an emulator is not covered by the automated tests; the boot-time logic is tested on the host instead (see below).

## Building and Testing

```bash
# Run unit tests on host
zig build test

# Compile freestanding x86_64 micro-kernel ELF
zig build -Doptimize=ReleaseSmall

# Check the linked kernel ELF for a multiboot2 header a loader would find and load
zig build inspect
```

## 0.2.0: Boot Information, Frame Allocator, Page Tables

### Multiboot2 header and boot information (`src/multiboot2.zig`)

- The kernel embeds a multiboot2 header (architecture i386, 48 bytes) with an optional information request tag asking for the memory map, command line, loader name and basic memory info, followed by the end tag. It sits in `.multiboot` next to the existing multiboot1 header.
- `validateHeader` and `findHeader` check a header the way a loader does: 8-byte alignment, fully inside the first 32 KiB, checksum, length, and a well-formed tag chain ending in an 8-byte end tag.
- `BootInfo.parse` validates the whole boot information structure once: total size, reserved field, every tag's size and alignment, NUL-terminated strings, and memory map entry size (at least 24 and a multiple of 8, with no trailing partial entry). Truncated, looping or oversized structures return an error instead of reading out of bounds. `BootInfo.fromAddress` caps the accepted size at 1 MiB.

### Physical frame allocator (`src/pmm.zig`)

- One bit per 4 KiB frame in caller-provided storage; `alloc`, `allocContiguous(count, align)`, `free` and `freeContiguous`.
- `fromMemoryMap` starts with every frame in use, frees whole frames inside available regions, then reserves every non-available region and every caller-supplied range (rounded outward). Overlapping firmware entries therefore resolve to "in use".
- `free` rejects misaligned addresses, untracked frames and double frees; `freeContiguous` validates the whole run before changing anything.

### Page table builder (`src/paging.zig`)

- `AddressSpace(Backend)` maps 4 KiB, 2 MiB and 1 GiB pages, translates virtual addresses by walking the tables, and unmaps single leaves. It refuses to overwrite an existing mapping, to place a huge page over an existing table, or to map non-canonical or misaligned addresses.
- `mapRange` picks the largest page size the alignment of both addresses and the remaining length allow, and unmaps everything it mapped if a later page fails.
- `buildKernelLayout` identity maps `[0, len)` and aliases the same range at `0xFFFF_FFFF_8000_0000`.
- `TablePool(n)` is a fixed pool of tables; the kernel uses one in `.bss`, the tests use one with synthetic physical addresses, so both run the same walk code.

### Kernel boot path (`src/kernel.zig`)

When entered with the multiboot2 magic, the kernel parses the boot information, prints the loader name, command line and memory map over COM1, builds the frame allocator (reserving the low 1 MiB, the kernel image and the boot information structure), and builds identity plus higher-half page tables for the first 1 GiB using 2 MiB pages, checking both views by translation. The new tables are not loaded into CR3. A wrong magic or a malformed structure is reported over serial and skipped.

### `realgar inspect`

Reports the ELF64 load segments of an image and the multiboot1 and multiboot2 headers a loader would find, including the physical address each header is loaded to.

```bash
zig build -Doptimize=ReleaseSmall
./zig-out/bin/realgar inspect zig-out/bin/realgar.elf
./zig-out/bin/realgar inspect zig-out/bin/realgar.elf --json
./zig-out/bin/realgar version
```

Text output for the current kernel image:

```
image size: 21056 bytes
elf: ELF64 type=2 machine=62 (x86_64) entry=0x101000
  load offset=0x1000 paddr=0x100000 vaddr=0x100000 filesz=0x3c memsz=0x3c R--
  load offset=0x2000 paddr=0x101000 vaddr=0x101000 filesz=0x1678 memsz=0x1678 R-X
  load offset=0x4000 paddr=0x103000 vaddr=0x103000 filesz=0x5ec memsz=0x5ec R--
  load offset=0x5000 paddr=0x104000 vaddr=0x104000 filesz=0x0 memsz=0x2a058 RW-
multiboot1: offset=0x1030 flags=0x00000003 checksum=0xe4524ffb paddr=0x100030
multiboot2: offset=0x1000 arch=0 length=48 checksum=0x17adaefa paddr=0x100000
  tag information_request type=1 flags=0x1 size=24 requests=6,1,2,4
  tag end type=0 flags=0x0 size=8
multiboot2 bootable: yes
```

Exit status is 0 when a multiboot2 header is present and, for ELF images, lies inside a loaded segment; 1 when it is not; 2 for usage or read errors. ELF parsing rejects program header tables and segments that point outside the file.

### Tests

`zig build test` runs 46 host tests, including randomized checks of the frame allocator and the page table mapper against reference models, random mutation of boot information structures and ELF headers, and an end-to-end test of the kernel boot path against the mock UART.

## License

MIT License - Copyright (c) 2026 Jeong Hoon Kim
