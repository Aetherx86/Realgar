# Changelog

All notable changes to this project will be documented in this file.

## [0.2.0] - 2026-11-20

### Added
- Multiboot2 header embedded in the kernel image, with an optional information request tag for the memory map, command line, loader name and basic memory info.
- Bounds-checked multiboot2 header validator and boot information parser (`src/multiboot2.zig`), hardened against truncated, looping and malformed structures.
- Bitmap physical frame allocator (`src/pmm.zig`) built from the multiboot2 memory map, with contiguous aligned allocation and double-free detection.
- 4-level page table mapper (`AddressSpace` in `src/paging.zig`) for 4 KiB, 2 MiB and 1 GiB pages with translate, unmap, rollback on partial failure, and an identity plus higher-half kernel layout builder.
- Kernel boot path that parses the boot information, prints the memory map over COM1, builds the frame allocator and early page tables, and verifies them by translation.
- `realgar inspect <image> [--json]` reporting ELF load segments and multiboot1/2 headers with their load addresses; `realgar version` and `realgar help`.
- `zig build inspect` step that validates the linked kernel ELF; CI runs it.
- Decimal formatter for the serial console.
- Randomized model-based tests for the allocator and the mapper, and random-mutation tests for the boot information and ELF parsers (46 tests in total).

### Changed
- `_start` takes the multiboot2 magic and boot information address (System V: RDI, RSI) and is exported only in the freestanding build, which fixes a duplicate `_start` link error when the tests are built for Linux.
- The linker script defines `__kernel_start` and `__kernel_end`.
- CI uses `mlugg/setup-zig` pinned to v2.2.1.

## 0.1.0 - 2026-11-08

### Added
- Initial release of Realgar bare-metal x86_64 long mode micro-kernel stub.
- Multiboot 1 and Multiboot 2 header specification compliance.
- 4-level paging structure (PML4, PDPT, PD) with identity physical memory mapping.
- 16550 UART serial driver for COM1 (0x3F8) at 115200 8N1 baud rate.
- 64-bit Global Descriptor Table (GDT) and Interrupt Descriptor Table (IDT) for 256 gates.
- Direct freestanding compilation targeting `x86_64-freestanding-none` generating 16 KB ELF image.
