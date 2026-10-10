/*
 * linker_onchip.ld  ---  CoreMark 片内运行版（推荐先跑这个）
 *
 * 目标硬件（board_top -> soc_ddr3_top -> soc_top）：
 *   0x0000_0000 - 0x0000_3FFF  16 KiB 片内 ROM  ——  只挂**指令总线**
 *   0x0000_0000 - 0x0000_3FFF  16 KiB 片内 RAM  ——  只挂**数据总线**
 *   0x1000_0000 - 0x1000_0FFF  simple_mmio（CYCLE / TEST_STATUS）
 *   0x1000_1000 - 0x1000_100F  uart_mmio
 *
 * 两条总线分离，所以 ROM 与 RAM 可以同基址 0x0：
 *   取指走 ROM，load/store 走 RAM。
 *
 * ★ 关键约束：数据总线读不到启动 ROM ★
 *   因此 .rodata（字符串常量、CRC 表、跳转表）**必须放在 RAM**，
 *   只有真正被"取指"的代码才能放 ROM。若把 .rodata 放进 ROM，
 *   load 会落到同地址的 RAM 上，读到的是完全无关的数据，
 *   表现为 CoreMark 的 CRC 校验失败或程序乱跑。
 *
 * 布局：
 *   ROM     : .text 全部（必须 <= 16 KiB，超出会链接报错）
 *   RAMDATA : .sdata/.sbss/.data/.rodata/.bss（必须 <= 10 KiB）
 *   STACK   : 6 KiB 独立栈区（0x2800 - 0x3FFF）
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    ROM     (rx)  : ORIGIN = 0x00000000, LENGTH = 16K
    RAMDATA (rwx) : ORIGIN = 0x00000000, LENGTH = 10K
    STACK   (rw)  : ORIGIN = 0x00002800, LENGTH = 6K
}

_stack_bottom = ORIGIN(STACK);
_stack_top    = ORIGIN(STACK) + LENGTH(STACK);

SECTIONS
{
    /* ---------------- 指令 ROM ---------------- */
    .text : {
        . = ALIGN(4);
        KEEP(*(.text.start))            /* 复位入口必须排在最前面 */
        *(.text .text.*)
        . = ALIGN(4);
        __text_end = .;
    } > ROM

    /* ---------------- 数据 RAM ---------------- */
    /* ROM 与 RAM 在硬件上是两块独立存储器、共用地址 0x0，所以它们的 VMA/LMA
     * 一定重叠。链接器默认会因此报
     *   "section .sdata LMA [...] overlaps section .text LMA [...]"
     * 这是本平台的正常现象，不是错误：真正需要防止的是"数据区撞到栈区"和
     * "代码超出 ROM"，这两条下面都有显式 ASSERT 兜底，所以可以安全地用
     * -Wl,--no-check-sections 关掉通用重叠检查（见 build.ps1）。
     * .sdata 与 .sbss 相邻放置，保证 __global_pointer$ 的 ±2 KiB 覆盖。 */
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
        *(.gnu.linkonce.d.*)
        . = ALIGN(4);
        __data_end = .;
    } > RAMDATA

    /* 只读数据放 RAM（数据总线读得到），不放 ROM */
    .rodata : {
        . = ALIGN(4);
        __rodata_start = .;
        *(.rodata .rodata.*)
        *(.rodata1)
        *(.srodata .srodata.*)
        *(.gnu.linkonce.r.*)
        . = ALIGN(4);
        __rodata_end = .;
    } > RAMDATA

    .init_array : {
        . = ALIGN(4);
        __init_array_start = .;
        KEEP(*(.init_array .init_array.*))
        __init_array_end = .;
        . = ALIGN(4);
    } > RAMDATA

    .bss (NOLOAD) : {
        . = ALIGN(4);
        __bss_start = .;
        *(.bss .bss.*)
        *(.gnu.linkonce.b.*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > RAMDATA

    __ram_data_end = .;

    /* 片内模式不需要搬运 .data（RAM 由 IP 初始化文件预置），这里仅为符号完整性 */
    __data_lma = LOADADDR(.data);

    /DISCARD/ : {
        *(.comment)
        *(.note .note.*)
        *(.eh_frame .eh_frame_hdr)
    }

    /* ---------------- 一致性检查 ---------------- */
    ASSERT(__text_end <= ORIGIN(ROM) + LENGTH(ROM),
           "ERROR: .text exceeds the 16 KiB on-chip ROM. Use -Os, shrink the printf, or expand the ROM IP (see README).")
    ASSERT(__ram_data_end <= ORIGIN(STACK),
           "ERROR: .sdata/.sbss/.data/.rodata/.bss exceed 10 KiB, they would collide with the stack region.")
    ASSERT((__sbss_end - __sdata_start) <= 0x1000,
           "ERROR: small-data (.sdata+.sbss) is larger than 4 KiB, gp-relative addressing may go out of range. Rebuild with -msmall-data-limit=0.")
}
