/*
 * linker_ddr.ld  ---  CoreMark DDR 运行版（给后续 Cache / 大程序 / 仿真用）
 *
 * 全部段放在 DDR 窗口 0x4000_0000 起。指令总线和数据总线都能访问 DDR，
 * 所以这里不需要区分 ROM/RAM。
 *
 * ★ 注意：DDR 是易失的 ★
 *   实板上电后 DDR 里什么都没有，必须先由 loader 把镜像搬进去再跳转。
 *   当前工程只有"片内 ROM 复制 245 字到 DDR"的自检 loader，容量远不够装
 *   CoreMark（约 20 KB+）。所以这个版本目前主要用于：
 *     - ModelSim 里由 TB 预载 DDR 模型；
 *     - 以后扩到 64 KiB 片内 RAM 或做 UART 下载 loader 之后上板。
 *   上板前请先完成这两件事之一，否则会跳到空内存。
 *
 * 用法：build.ps1 -Mode ddr
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    DDR (rwx) : ORIGIN = 0x40000000, LENGTH = 64K
}

_stack_bottom = ORIGIN(DDR) + LENGTH(DDR) - 8K;
_stack_top    = ORIGIN(DDR) + LENGTH(DDR);

SECTIONS
{
    .text : {
        . = ALIGN(4);
        KEEP(*(.text.start))
        *(.text .text.*)
        . = ALIGN(4);
        __text_end = .;
    } > DDR

    .sdata : {
        . = ALIGN(4);
        __sdata_start = .;
        PROVIDE(__global_pointer$ = . + 0x800);
        *(.sdata .sdata.*)
        *(.sdata2 .sdata2.*)
        . = ALIGN(4);
        __sdata_end = .;
    } > DDR

    .sbss (NOLOAD) : {
        . = ALIGN(4);
        *(.sbss .sbss.*)
        *(.sbss2 .sbss2.*)
        . = ALIGN(4);
        __sbss_end = .;
    } > DDR

    .data : {
        . = ALIGN(4);
        __data_start = .;
        *(.data .data.*)
        . = ALIGN(4);
        __data_end = .;
    } > DDR

    .rodata : {
        . = ALIGN(4);
        *(.rodata .rodata.*)
        *(.rodata1)
        . = ALIGN(4);
    } > DDR

    .bss (NOLOAD) : {
        . = ALIGN(4);
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > DDR

    __data_lma = LOADADDR(.data);

    /DISCARD/ : {
        *(.comment)
        *(.note .note.*)
        *(.eh_frame .eh_frame_hdr)
    }

    ASSERT(. <= _stack_bottom,
           "ERROR: DDR image runs into the reserved 8 KiB stack area. Increase LENGTH(DDR).")
}
