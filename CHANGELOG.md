# Changelog

All notable changes to this project will be documented in this file.

## 0.1.0 - 2026-11-08

### Added
- Initial release of Realgar bare-metal x86_64 long mode micro-kernel stub.
- Multiboot 1 and Multiboot 2 header specification compliance.
- 4-level paging structure (PML4, PDPT, PD) with identity physical memory mapping.
- 16550 UART serial driver for COM1 (0x3F8) at 115200 8N1 baud rate.
- 64-bit Global Descriptor Table (GDT) and Interrupt Descriptor Table (IDT) for 256 gates.
- Direct freestanding compilation targeting `x86_64-freestanding-none` generating 16 KB ELF image.
