/*
 * CoreMark 片内 ROM/RAM 运行变体 —— 链接脚本
 * ---------------------------------------------------------------------------
 * 创建日期：2026-10-11
 *
 * 为什么需要它：
 *   现状是 CoreMark 通过 UART Loader 写进 DDR 后执行，而
 *   dual_sram_to_pango_ddr_bridge 一次只处理一笔单拍 DDR 事务、无突发、无 Cache，
 *   每条取指要等几十个周期才回来。实测分数只有 0.036 CoreMark/MHz，
 *   比从快内存取指的正常水平（1.5-2.5）慢约 50 倍。
 *
 *   把程序放进片内 ROM/RAM 后，取指变成 1 周期，预期提升 30-50 倍。
 *
 * 硬件约束（来自 AGENTS.md）：
 *   - 片内 ROM 只接**指令总线**，片内 RAM 只接**数据总线**
 *   - 两块存储器各 16 KiB，**同基址 0x0**（哈佛结构，两条独立总线）
 *   => 所以本脚本里 ROM 和 RAM 的 ORIGIN 都是 0，两段 LMA 重叠是**合法**的，
 *      链接时必须加 -Wl,--no-check-sections，否则 ld 会报 section 重叠。
 *   => 又因为数据总线读不到 ROM，**.rodata 绝对不能放 ROM**，只能放 RAM。
 *
 * 实测体积（团队 performance_60/program.elf，-Os）：
 *   .text   15292 B  -> ROM 16 KiB 的 93%（放得下，但很紧）
 *   .rodata  2748 B  -> RAM
 *   .data      16 B  -> RAM
 *   .bss     2068 B  -> RAM
 *   栈       4096 B  -> RAM
 *   RAM 合计约 8928 B -> 16 KiB 的 55%
 *
 * 用法：
 *   gcc ... -T tests/bsp_workflow/linker_onchip.ld -Wl,--no-check-sections ...
 *
 * ⚠️ 这会产生**新的程序镜像和新的位流哈希**，按团队门控规则属于"新候选"，
 *    必须重建验收，不要覆盖已实板验收的 Loader 位流。
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    /* 指令总线：片内 ROM，基址 0x0，16 KiB */
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 16K
    /* 数据总线：片内 RAM，基址也是 0x0（另一条总线，与 ROM 同址互不冲突） */
    RAM (rw)  : ORIGIN = 0x00000000, LENGTH = 16K
}

SECTIONS {
    /* ---- 代码：只进 ROM ---- */
    .text : {
        KEEP(*(.text.startup))
        *(.text .text.*)
    } > ROM

    /* ---- 常量/初值/变量：全部进 RAM（数据总线读不到 ROM）---- */
    .rodata : {
        *(.rodata .rodata.* .srodata .srodata.*)
    } > RAM

    .data : ALIGN(4) {
        __data_start = .;
        *(.data .data.* .sdata .sdata.*)
        . = ALIGN(4);
        __data_end = .;
    } > RAM
    __data_load_start = LOADADDR(.data);

    __global_pointer$ = __data_start + 0x800;

    .bss (NOLOAD) : ALIGN(4) {
        __bss_start = .;
        *(.bss .bss.* .sbss .sbss.*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > RAM

    /* ---- 栈：RAM 顶部 4 KiB ---- */
    __stack_bottom = ORIGIN(RAM) + 12K;
    __stack_top    = ORIGIN(RAM) + 16K;

    /* ---- 硬性边界检查：越界直接链接失败，不会悄悄跑错 ---- */
    ASSERT(. <= ORIGIN(ROM) + 16K, "text overflows on-chip ROM (16K)")
    ASSERT(__bss_end <= __stack_bottom, "data/bss overflows on-chip RAM")

    /DISCARD/ : {
        *(.comment)
        *(.eh_frame .eh_frame.*)
    }
}
