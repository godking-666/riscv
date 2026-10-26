/*
 * start.S  ---  CoreMark 的裸机启动代码
 *
 * 复位后 CPU 从 RESET_PC = 0x0000_0000 取指，也就是片内指令 ROM 的第一条指令，
 * 本文件必须排在 .text 最前面（链接脚本用 KEEP(*(.text.start)) 保证）。
 *
 * 做的事情：
 *   1. 关掉中断（mie=0），CoreMark 不需要中断
 *   2. 设置 mtvec 指向 cm_trap_entry，任何异常都能打印 mcause/mepc/mtval 再停住
 *   3. 设置 gp（全局指针），让链接器放松优化生效
 *   4. 设置 sp 到 RAM 顶部的独立栈区
 *   5. 清 .bss
 *   6. 按需把 .data 从 LMA 拷到 VMA（片内模式 LMA==VMA，是自拷贝；
 *      该开关主要为以后 DDR 模式预留）
 *   7. 调 main()，返回后原地停住
 *
 * 注意本硬件的关键约束：片内 ROM 只在指令总线上，数据总线读不到 ROM。
 * 所以链接脚本把 .rodata 也放在 RAM 里，而不是 ROM。
 */

#define CM_COPY_DATA   0       /* 片内模式：RAM 由 IP 初始化文件预置，无需搬运 */
#define CM_STACK_PAINT 1       /* 启动时给栈区填 0xA5，便于事后看栈用量 */

    .section .text.start, "ax", @progbits
    .globl  _start
    .type   _start, @function
_start:
    /* 1. 关中断（mstatus.MIE / mie 全部清零） */
    csrw    mie, zero
    csrci   mstatus, 8

    /* 2. 异常入口 */
    la      t0, cm_trap_entry
    csrw    mtvec, t0

    /* 3. gp：gp 相对寻址要求 gp 在 .sdata/.sbss 附近，且设置时不能放松 */
    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop

    /* 4. 栈顶 */
    la      sp, _stack_top

    /* 4b. 可选：给栈区填 0xA5（检查栈用量时很有用） */
#if CM_STACK_PAINT
    la      t0, _stack_bottom
    la      t1, _stack_top
    li      t2, 0xA5A5A5A5
1:  bgeu    t0, t1, 2f
    sw      t2, 0(t0)
    addi    t0, t0, 4
    j       1b
2:
#endif

    /* 5. 清 .bss */
    la      t0, __bss_start
    la      t1, __bss_end
3:  bgeu    t0, t1, 4f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       3b
4:

    /* 6. 按需搬运 .data */
#if CM_COPY_DATA
    la      t0, __data_start
    la      t1, __data_end
    la      t2, __data_lma
5:  bgeu    t0, t1, 6f
    lw      t3, 0(t2)
    sw      t3, 0(t0)
    addi    t0, t0, 4
    addi    t2, t2, 4
    j       5b
6:
#endif

    /* 7. main() */
    call    main

#ifdef CM_RETURN_TO_LOADER
    /* 跑完直接跳回 ROM 里的 UART Loader（地址 0x0），这样同一份位流可以
       连续下载多个应用，不必按 KEY0 或重烧位流。
       本核有 D$（写回）：Loader 自己会在跳转到新应用之前发 fence.i，
       所以这里不需要额外清缓存。 */
    lui     t0, 0x0
    jalr    zero, 0(t0)
#else
    /* main 返回：停在这里，等待复位或调试器 */
7:  j       7b
#endif

    .size   _start, . - _start

/* ------------------------------------------------------------------ */
/* 异常入口：把 mcause / mepc / mtval 交给 C 代码打印后停住             */
/* ------------------------------------------------------------------ */
    .globl  cm_trap_entry
    .type   cm_trap_entry, @function
cm_trap_entry:
    csrr    a0, mcause
    csrr    a1, mepc
    csrr    a2, mtval
    call    cm_trap_report
#ifdef CM_RETURN_TO_LOADER
    /* 崩溃后也跳回 Loader，这样调试迭代不需要每次按 KEY0 / 重烧位流。
       注意：cm_trap_report 已经用 UART 把 mcause/mepc/mtval 打出来了。 */
    lui     t0, 0x0
    jalr    zero, 0(t0)
#else
8:  j       8b
#endif
    .size   cm_trap_entry, . - cm_trap_entry
