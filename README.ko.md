# Realgar

베어메탈 x86_64 롱 모드 마이크로 커널 스터브 (Bare-Metal x86_64 Long Mode Micro-Kernel Stub)

외부 어셈블리 파일이나 NASM 툴체인 없이 100% 순수 Zig로 작성된 부팅 가능한 독립형 Multiboot/UEFI 마이크로 커널 하네스입니다.

[English Documentation](README.md)

## 아키텍처

- 순수 Zig 커널 엔트리: 네이키드 엔트리 포인트 `_start`가 외부 어셈블리 보일러플레이트 없이 머신 상태를 직접 초기화합니다.
- 4단계 페이징 (PML4): PML4, PDPT, Page Directory 구조 전반에 걸쳐 2MB 대형 페이지(huge page)를 사용하여 물리 메모리를 아이덴티티 매핑(identity mapping)합니다.
- 16550 UART 시리얼 콘솔: 115200 보드레이트(8N1) 및 FIFO 버퍼링으로 작동하는 직접 포트 I/O 드라이버(`0x3F8` COM1)를 내장했습니다.
- GDT 및 IDT 디스크립터: 완전한 64비트 세그먼트 디스크립터(커널 CS `0x08`, 커널 DS `0x10`) 및 256개 엔트리의 인터럽트 게이트 테이블을 설정합니다.
- 초소형 바이너리 풋프린트: QEMU, Bochs 또는 실제 멀티부트 부트로더에서 즉시 실행 가능한 16 KB 크기의 자립형 ELF 바이너리를 생성합니다.

## 메모리 맵

```
0x0000_0000 - 0x000F_FFFF : 리얼 모드 및 BIOS 영역 (아이덴티티 매핑)
0x0010_0000 - 0x0010_4000 : Realgar 마이크로 커널 ELF (.multiboot, .text, .rodata)
0x0010_4000 - 0x0010_8000 : 정적 커널 스택 (16 KB 정렬)
0x0010_8000 - 0x0100_0000 : 16 MB 아이덴티티 매핑 물리 메모리 영역
```

## 빌드 및 테스트

```bash
# 호스트에서 단위 테스트 실행
zig build test

# 독립형 x86_64 마이크로 커널 ELF 컴파일
zig build -Doptimize=ReleaseSmall
```

## 라이선스

MIT License - Copyright (c) 2026 Jeong Hoon Kim
