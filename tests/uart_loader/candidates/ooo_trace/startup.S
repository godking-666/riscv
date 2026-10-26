    /* GCC 15 separates Zicsr from RV32I; these explicit CSR instructions
       are already implemented in this CPU. C/libgcc remain -march=rv32i. */
    .option push
    .option arch, +zicsr
    .section .text.startup, "ax", @progbits
    .globl _start
_start:
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop
    la sp, __stack_top
    .globl loader_stack_ready
loader_stack_ready:
    csrw mie, zero
    csrci mstatus, 8
    la t0, loader_trap
    csrw mtvec, t0
    la t0, __bss_start
    la t1, __bss_end
1:  bgeu t0, t1, 2f
    sw zero, 0(t0)
    addi t0, t0, 4
    j 1b
2:  call main
3:  j 3b

    .section .text.trap, "ax", @progbits
    .balign 4
    .globl loader_trap
loader_trap:
    /* No C call or stack dependency in the fatal trap path. */
    csrr t1, mcause
    la t0, loader_trap_cause
    sw t1, 0(t0)
    csrr t1, mepc
    la t0, loader_trap_pc
    sw t1, 0(t0)
    csrr t1, mtval
    la t0, loader_trap_value
    sw t1, 0(t0)
4:  j 4b
    .option pop

    .option push
    .option arch, +zicsr
    .section .text.jump, "ax", @progbits
    .globl loader_enter_app
loader_enter_app:
    csrw mie, zero
    csrci mstatus, 8
    fence rw,rw
    /* ★ OoO 核集成版专用：必须清 D$ 并失效 I$。Loader 把应用镜像写进 DDR 时
       走的是 D$（写回缓存），若不清就直接跳转，取指会从 DDR 拿到空内容。
       用 .word 编码而不用助记符，避免 -march=rv32i 未启用 zifencei 时汇编报错。
       fence.i = 0x0000100f；他核 ooo_decode.v:118 译成 SYS_FENCEI -> cmo_req
       （ooo_core.v:644），在 soc_ooo 里连到 dcache.fl_req 与 icache.inv_req。 */
    .word 0x0000100f
    lui t0, 0x40000
    jalr zero, 0(t0)
    .option pop
