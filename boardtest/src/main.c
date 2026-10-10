/*
 * main.c  ---  上板自检主流程
 *
 * 流程：
 *   1. 先把 TEST_STATUS 置成 RUN —— 这样即使串口不通，K17 也会开始慢闪，
 *      说明 CPU 已经跑到这里了（这本身就是最有价值的一条信息）。
 *   2. 探测 UART 是否存在。不存在就完全静默，只靠 LED 出结果，
 *      避免每次 putc 都触发一次访问异常。
 *   3. 依次跑 bt_cases 里的测试，每项打印一行 + 细节。
 *   4. 汇总后把 TEST_STATUS 置成 PASS 或 FAIL，K17 由慢闪转为常亮或 4 Hz 快闪。
 *   5. 进入空循环停住（等待复位或重新下载）。
 */
#include "boardtest.h"
#include "soc_mmio.h"

/* g_console_ok 定义在 console.c，bt_putc 会检查它 */

/* 只读一次 UART STATUS，不打印、不依赖 g_console_ok，用来判断 UART 是否接入 */
static int probe_uart(void)
{
    uint8_t st;
    bt_trap_reset();
    st = UART_STATUS;
    if (bt_trap_fired())
        return 0;                          /* 未映射 -> 访问异常 */
    return (st & UART_ST_TX_READY) ? 1 : 0;
}

int main(void)
{
    int i, pass = 0, fail = 0, skip = 0;

    MMIO_TEST_STATUS = TEST_RUN;           /* K17 开始慢闪：CPU 活着且已进入 main */
    g_console_ok = probe_uart();

    bt_printf("\r\n");
    bt_printf("=== myriscv board bring-up test v1.0 ===\r\n");
    bt_printf("core_clk   : %u Hz (board_top.CORE_CLK_HZ)\r\n", (uint32_t)SOC_CPU_HZ);
    bt_printf("ROM/RAM    : 16 KiB / 16 KiB on-chip\r\n");
    bt_printf("UART       : %s\r\n", g_console_ok ? "present (115200 8N1)"
                                                    : "NOT PRESENT - LED only");
    bt_printf("LED map    : J16=clk alive  M17=ddr ready  K17=test status\r\n");
    bt_printf("             K17 slow blink=RUN   steady=PASS   4Hz=FAIL\r\n");
    bt_printf("\r\n");

    for (i = 0; i < bt_case_count; i++) {
        int r;
        g_bt_detail[0] = '\0';
        bt_printf("[%2d] %s -> ", i + 1, bt_cases[i].name);
        r = bt_cases[i].fn();
        if (r == BT_PASS) {
            bt_printf("PASS  ");
            pass++;
        } else if (r == BT_FAIL) {
            bt_printf("FAIL  ");
            fail++;
        } else {
            bt_printf("SKIP  ");
            skip++;
        }
        if (g_bt_detail[0])
            bt_printf("%s", g_bt_detail);
        bt_printf("\r\n");
    }

    bt_printf("\r\n");
    bt_printf("SUMMARY: %d PASS / %d FAIL / %d SKIP  (total %d)\r\n",
              pass, fail, skip, bt_case_count);

    if (fail == 0) {
        MMIO_TEST_STATUS = TEST_PASS;      /* K17 常亮 */
        bt_printf("RESULT: PASS board bring-up OK. K17 should be STEADY ON.\r\n");
    } else {
        MMIO_TEST_STATUS = TEST_FAIL;      /* K17 4 Hz 快闪 */
        bt_printf("RESULT: FAIL %d item(s) failed. K17 blinks at 4 Hz.\r\n", fail);
    }
    /* 给脚本解析用的机器可读行 */
    bt_printf("RESULT-LINE: boardtest pass=%d fail=%d skip=%d\r\n", pass, fail, skip);

    for (;;)
        __asm__ volatile("");              /* 停在这儿，等待复位/重新下载 */
}
