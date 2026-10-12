/*
 * boardtest.h  ---  上板自检小程序共享声明
 *
 * 设计目标：在没有串口、没有调试器的情况下也能从 3 个 LED 判断板子是否正常；
 *           串口接好后能打印出每一项测试的细节，用于定位故障。
 *
 * 结果如何读到：
 *   K17（核心板 LED）  RUN≈1Hz 慢闪 → PASS 常亮 → 全部通过
 *                      PASS 常亮前若变 4Hz 快闪 = FAIL
 *   J16（LED3）        常亮/闪烁 = core_clk 在跑（硬件心跳，与软件无关）
 *   M17（LED4）        常亮 = DDR 初始化完成且 PLL 锁定（硬件，与软件无关）
 *   串口 115200 8N1    每项测试一行，失败项带 mtval / 期望值等细节
 */
#ifndef BOARDTEST_H
#define BOARDTEST_H

#include <stdint.h>

/* 测试结果 */
#define BT_PASS 1
#define BT_FAIL 2
#define BT_SKIP 3

typedef int (*bt_fn)(void);

typedef struct {
    const char *name;
    bt_fn       fn;
} bt_case;

/* 每一项测试的细节文字，由被测函数用 bt_note() 填，主流程在状态后面打印 */
extern char g_bt_detail[112];

/* UART 是否存在（main 探测后置位）。为 0 时 bt_putc 直接丢弃，避免每次写都触发异常 */
extern int g_console_ok;

/* ---- console.c ---- */
void     bt_putc(char c);
void     bt_puts(const char *s);
int      bt_printf(const char *fmt, ...);
void     bt_note(const char *fmt, ...);
uint32_t bt_cycle(void);
uint8_t  bt_uart_status(void);
int      bt_uart_tx_ready(void);
int      bt_uart_getc(void);          /* 非阻塞，无数据返回 -1 */

/* ---- trap.c ---- */
extern volatile uint32_t g_trap_count;
extern volatile uint32_t g_trap_cause;
extern volatile uint32_t g_trap_epc;
extern volatile uint32_t g_trap_tval;
extern volatile uint32_t g_irq_count;
extern volatile uint32_t g_irq_byte;

uint32_t bt_trap_handler(uint32_t cause, uint32_t epc, uint32_t tval);
void     bt_trap_reset(void);
int      bt_trap_fired(void);

/* 让 C 代码能读写 CSR */
#define CSR_READ(csr, dst)  __asm__ volatile("csrr %0, " #csr : "=r"(dst))
#define CSR_WRITE(csr, src) __asm__ volatile("csrw " #csr ", %0" :: "r"(src))
#define CSR_SET(csr, src)   __asm__ volatile("csrs " #csr ", %0" :: "r"(src))
#define CSR_CLR(csr, src)   __asm__ volatile("csrc " #csr ", %0" :: "r"(src))

/* 中断相关的位（与 csr_defs.vh 一致） */
#define MIE_MEIE (1u << 11)   /* 外部中断使能 */
#define MSTATUS_MIE (1u << 3) /* 全局中断使能 */

/* ---- tests.c ---- */
extern const bt_case bt_cases[];
extern const int     bt_case_count;

#endif /* BOARDTEST_H */
