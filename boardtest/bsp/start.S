/*
 * start.S  ---  上板自检的启动代码与异常向量
 *
 * 与 CoreMark 版的区别：这里的异常向量会**返回**（mret），
 * 因为自检程序要故意制造异常再继续跑。
 *
 * 复位流程：
 *   1. 关中断（mie = 0, mstatus.MIE = 0）
 *   2. mtvec -> bt_trap_entry
 *   3. 设 gp（链接器放松优化）、sp（独立栈区 0x2800..0x3FFF）
 *   4. 用 0xA5 预填栈区（事后可看栈用了多少）
 *   5. 清 .bss
 *   6. 调 main()，返回后原地停住
 *
 * 硬件约束提醒：片内 ROM 只挂指令总线，数据总线读不到 ROM，
 * 所以 .rodata 也放在 RAM 里（见 linker_onchip.ld）。
 */

    .section .text.start, "ax", @progbits
    .globl  _start
    .type   _start, @function
_start:
    csrw    mie, zero
    csrci   mstatus, 8

    la      t0, bt_trap_entry
    csrw    mtvec, t0

    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop

    la      sp, _stack_top

    /* 给栈区填 0xA5，便于事后判断最大栈深度 */
    la      t0, _stack_bottom
    la      t1, _stack_top
    li      t2, 0xA5A5A5A5
1:  bgeu    t0, t1, 2f
    sw      t2, 0(t0)
    addi    t0, t0, 4
    j       1b
2:

    /* 清 .bss */
    la      t0, __bss_start
    la      t1, __bss_end
3:  bgeu    t0, t1, 4f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       3b
4:

    call    main
5:  j       5b

/* ------------------------------------------------------------------ */
/* 异常 / 中断入口                                                     */
/*                                                                     */
/* 保存所有可能被 C 处理函数破坏的寄存器，把 mcause/mepc/mtval 传给   */
/* bt_trap_handler()，用返回值更新 mepc，然后 mret。                    */
/*   - 同步异常：处理函数返回 mepc+4，跳过故障指令                     */
/*   - 中断    ：处理函数返回 mepc，继续执行被打断的指令                */
/* ------------------------------------------------------------------ */
    .globl  bt_trap_entry
    .type   bt_trap_entry, @function
bt_trap_entry:
    addi    sp, sp, -64
    sw      ra,  0(sp)
    sw      t0,  4(sp)
    sw      t1,  8(sp)
    sw      t2, 12(sp)
    sw      a0, 16(sp)
    sw      a1, 20(sp)
    sw      a2, 24(sp)
    sw      a3, 28(sp)
    sw      a4, 32(sp)
    sw      a5, 36(sp)
    sw      a6, 40(sp)
    sw      a7, 44(sp)
    sw      t3, 48(sp)
    sw      t4, 52(sp)
    sw      t5, 56(sp)
    sw      t6, 60(sp)

    csrr    a0, mcause
    csrr    a1, mepc
    csrr    a2, mtval
    call    bt_trap_handler        /* 返回新的 mepc 在 a0 */
    csrw    mepc, a0

    lw      ra,  0(sp)
    lw      t0,  4(sp)
    lw      t1,  8(sp)
    lw      t2, 12(sp)
    lw      a0, 16(sp)
    lw      a1, 20(sp)
    lw      a2, 24(sp)
    lw      a3, 28(sp)
    lw      a4, 32(sp)
    lw      a5, 36(sp)
    lw      a6, 40(sp)
    lw      a7, 44(sp)
    lw      t3, 48(sp)
    lw      t4, 52(sp)
    lw      t5, 56(sp)
    lw      t6, 60(sp)
    addi    sp, sp, 64
    mret

    .size   bt_trap_entry, . - bt_trap_entry
