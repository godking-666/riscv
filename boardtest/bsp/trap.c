/*
 * trap.c  ---  异常/中断处理（C 侧）
 *
 * 规则很简单但很关键：
 *   中断（mcause 最高位为 1）：mepc 指向**还没执行**的那条指令，处理完必须
 *                              原样返回 mepc，让被打断的指令继续跑。
 *   异常（同步）：故障指令不能重试，返回 mepc + 4 跳过它，程序才能继续。
 *                本工程用 -march=rv32i_zicsr（没有 C 压缩扩展），指令定长 4 字节，
 *                 所以 mepc+4 就是下一条指令。
 *
 * 处理函数里**不打印任何东西**：如果 UART 本身没映射，打印会再次触发异常，
 * 变成无限递归。所有信息都记在全局变量里，交给主流程打印。
 */
#include "boardtest.h"
#include "soc_mmio.h"

volatile uint32_t g_trap_count = 0;
volatile uint32_t g_trap_cause = 0;
volatile uint32_t g_trap_epc   = 0;
volatile uint32_t g_trap_tval  = 0;
volatile uint32_t g_irq_count  = 0;
volatile uint32_t g_irq_byte   = 0;

void bt_trap_reset(void)
{
    g_trap_count = 0;
    g_trap_cause = 0;
    g_trap_epc   = 0;
    g_trap_tval  = 0;
}

int bt_trap_fired(void) { return g_trap_count != 0; }

uint32_t bt_trap_handler(uint32_t cause, uint32_t epc, uint32_t tval)
{
    if (cause & 0x80000000u) {                 /* ---- 中断 ---- */
        uint32_t code = cause & 0x7FFFFFFFu;
        g_irq_count++;
        if (code == 11) {                      /* external = UART RX（板级就是它） */
            if (UART_STATUS & UART_ST_RX_NOT_EMPTY)
                g_irq_byte = (uint32_t)(UART_RX_DATA & 0xFFu);
        }
        return epc;                            /* 回到被打断的指令 */
    }

    /* ---- 同步异常 ---- */
    g_trap_count++;
    g_trap_cause = cause;
    g_trap_epc   = epc;
    g_trap_tval  = tval;
    return epc + 4;                            /* 跳过故障指令 */
}
