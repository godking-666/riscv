/*
 * linker_onchip.ld  ---  上板自检（boardtest）的链接脚本
 *
 * 目标硬件：
 *   0x0000_0000 - 0x0000_3FFF  16 KiB 片内 ROM  —— 只挂指令总线（只放代码）
 *   0x0000_0000 - 0x0000_3FFF  16 KiB 片内 RAM  —— 只挂数据总线
 *   0x1000_0000  simple_mmio   0x1000_1000  uart_mmio   0x4000_0000  DDR
 *
 * ★ 数据总线读不到 ROM ★
 *   .rodata 这类会被 load 读取的数据必须放 RAM，只有代码能放 ROM。
 *   放错会让程序读到同地址 RAM 上的无关数据。
 *
 * 分区（片内 RAM 共 16 KiB，特意切出一块"自检专用区"）：
 *   RAMDATA  0x0000-0x17FF  6 KiB   程序自己的 .sdata/.data/.rodata/.bss
 *                                   （中文测试名和注释模板占了不少，UTF-8 一个汉字 3 字节）
 *   RAMTEST  0x1800-0x27FF  4 KiB   自检专用，程序不申请任何变量，整片随便写
 *   STACK    0x2800-0x3FFF  6 KiB   栈（启动时填 0xA5，可事后看用量）
 *
 *   RAMTEST 与 STACK 分开的意义：跑 walking-1 / 全 0 / 全 1 时不会踩到
 *   程序变量和栈；下面还有 ASSERT 保证 RAMDATA 不会长进 RAMTEST。
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    ROM     (rx)  : ORIGIN = 0x00000000, LENGTH = 16K
    RAMDATA (rwx) : ORIGIN = 0x00000000, LENGTH = 0x1800
    RAMTEST (rw)  : ORIGIN = 0x00001800, LENGTH = 0x1000
    STACK   (rw)  : ORIGIN = 0x00002800, LENGTH = 6K
}

_stack_bottom = ORIGIN(STACK);
_stack_top    = ORIGIN(STACK) + LENGTH(STACK);

/* 供 tests.c 引用：自检专用区的起止 */
PROVIDE(__ramtest_start = ORIGIN(RAMTEST));
PROVIDE(__ramtest_end   = ORIGIN(RAMTEST) + LENGTH(RAMTEST));

SECTIONS
{
    /* ---------------- 指令 ROM ---------------- */
    .text : {
        . = ALIGN(4);
        KEEP(*(.text.start))
        *(.text .text.*)
        . = ALIGN(4);
        __text_end = .;
    } > ROM

    /* ---------------- 程序数据（RAM 低 4 KiB） ---------------- */
    .sdata : {
        . = ALIGN(4);
        __sdata_start = .;
        PROVIDE(__global_pointer$ = . + 0x800);
        *(.sdata .sdata.*)
        *(.sdata2 .sdata2.*)
        . = ALIGN(4);
        __sdata_end = .;
    } > RAMDATA

    .sbss (NOLOAD) : {
        . = ALIGN(4);
        __sbss_start = .;
        *(.sbss .sbss.*)
        *(.sbss2 .sbss2.*)
        . = ALIGN(4);
        __sbss_end = .;
    } > RAMDATA

    .data : {
        . = ALIGN(4);
        __data_start = .;
        *(.data .data.*)
        . = ALIGN(4);
        __data_end = .;
    } > RAMDATA

    .rodata : {
        . = ALIGN(4);
        __rodata_start = .;
        *(.rodata .rodata.*)
        *(.rodata1)
        *(.srodata .srodata.*)
        . = ALIGN(4);
        __rodata_end = .;
    } > RAMDATA

    .bss (NOLOAD) : {
        . = ALIGN(4);
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > RAMDATA

    __ram_data_end = .;
    __data_lma = LOADADDR(.data);

    /DISCARD/ : {
        *(.comment)
        *(.note .note.*)
        *(.eh_frame .eh_frame_hdr)
    }

    ASSERT(__text_end <= ORIGIN(ROM) + LENGTH(ROM),
           "ERROR: .text exceeds the 16 KiB on-chip ROM.")
    ASSERT(__ram_data_end <= ORIGIN(RAMTEST),
           "ERROR: program data grew into the RAM test region; shrink it or move RAMTEST up.")
    ASSERT((__sbss_end - __sdata_start) <= 0x1000,
           "ERROR: small-data is larger than 4 KiB, gp-relative addressing may go out of range.")
}
