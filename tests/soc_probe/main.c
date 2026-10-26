/* 集成 SoC 性能探针 v2：边跑边打印，用来区分"DDR 极慢"与"DDR 通路挂死"
 *
 * 设计要点：
 *  - 指针追逐按步打印进度（小数组每 50 步、大数组每 2 步），一旦卡住就知道卡在第几步
 *  - 每步前检查 elapsed，超过上限立即中止并报告 ABORT，避免整机卡死
 *  - 先用小数组（全命中）验证测量框架本身，再跑超过 D$ 的大数组
 *
 * 只用 %d/%u/%x（本 BSP 的 printf 不支持 %l）
 */
#include <stdint.h>
#include "bsp.h"

static uint8_t small_buf[2048]    __attribute__((aligned(64)));
static uint8_t big_buf[32*1024]   __attribute__((aligned(4096)));
volatile uint32_t sink;

static int chase_report(volatile uint8_t *base, uint32_t *idx, uint32_t steps,
                        uint32_t step_marks, uint32_t limit, const char *tag)
{
    uint32_t cur = 0;
    uint32_t t0 = timer_cycles();
    for (uint32_t s = 0; s < steps; s++) {
        uint32_t el = timer_cycles() - t0;
        if (el > limit) {
            printf("ABORT %s step=%u elapsed=%u limit=%u\r\n", tag, s, el, limit);
            return 0;
        }
        cur = idx[cur];
        sink += base[cur * 64u];
        if (step_marks && ((s % step_marks) == 0)) {
            printf("  %s step=%u elapsed=%u\r\n", tag, s, el);
        }
    }
    uint32_t total = timer_cycles() - t0;
    printf("DONE %s steps=%u cycles=%u per_step=%u\r\n", tag, steps, total, total / steps);
    return 1;
}

int main(void)
{
    printf("\r\n=== SOC PROBE2 begin ===\r\n");

    /* ---- 0) 时钟标定：8 条依赖 addi + addi + bnez = 10 拍/迭代 ----
       用 MMIO CYCLE（93.75 MHz 计数）测时间；若 CPU 跑 135 MHz，
       则 ticks ≈ cycles * 93.75/135 = cycles * 0.694。 */
    {
        uint32_t iters = 20000u;              /* 20000 * 10 = 200000 拍 */
        uint32_t acc = 0;
        uint32_t t0 = timer_cycles();
        __asm__ volatile(
            "1:\n\t"
            "addi %0, %0, 1\n\t"
            "addi %0, %0, 1\n\t"
            "addi %0, %0, 1\n\t"
            "addi %0, %0, 1\n\t"
            "addi %0, %0, 1\n\t"
            "addi %0, %0, 1\n\t"
            "addi %0, %0, 1\n\t"
            "addi %0, %0, 1\n\t"
            "addi %1, %1, -1\n\t"
            "bnez %1, 1b\n\t"
            : "+r"(acc), "+r"(iters) : : "memory");
        uint32_t t1 = timer_cycles();
        sink += acc;
        uint32_t ticks = t1 - t0;
        uint32_t cyc = (20000u - iters) * 10u + 10u;   /* 实际完成的拍数（上界近似） */
        printf("CLOCK ticks=%u approx_cpu_cycles=%u\r\n", ticks, cyc);
        if (ticks) {
            printf("CLOCK cpu_mhz_x100=%u (ticks=%u -> 93.75*cyc/ticks)\r\n",
                   (uint32_t)(((uint64_t)9375u * cyc) / ticks));
        }
    }

    static uint32_t idx_small[32];
    for (uint32_t i = 0; i < 32u; i++) idx_small[i] = (i + 1u) & 31u;
    printf("small init ok\r\n");
    sink = 0;
    (void)chase_report(small_buf, idx_small, 200u, 50u, 5000000u, "small");

    static uint32_t idx_big[512] __attribute__((aligned(64)));
    for (uint32_t i = 0; i < 512u; i++) idx_big[i] = (i + 1u) & 511u;
    printf("big init ok\r\n");
    sink = 0;
    (void)chase_report(big_buf, idx_big, 40u, 2u, 50000000u, "big");

    printf("=== SOC PROBE2 end ===\r\n");
    return 0;
}
