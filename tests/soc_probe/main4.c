/* 分步自证探针 v4：把 DDR 读/写拆成最小步骤，每步打印一次
 * 目的：定位到底哪一类访存会挂住（上电后第一次写？读？cache line fill？）
 * 每步都立即 printf 刷新，卡住时最后打印的字母就是卡住的步骤。
 */
#include <stdint.h>
#include "bsp.h"

static uint8_t  sbuf[2048]   __attribute__((aligned(64)));
static uint8_t  bbuf[32*1024] __attribute__((aligned(4096)));
volatile uint32_t sink;
volatile uint8_t  one;

int main(void)
{
    printf("\r\n=== P4 start ===\r\n");

    /* A: 单个 volatile 字节写（.data/.bss，DDR） */
    one = 0x5A;
    printf("A wrote one=%x\r\n", one);

    /* B: 读回并校验 */
    if (one != 0x5A) { printf("B MISMATCH\r\n"); }
    printf("B readback ok\r\n");

    /* C: 32 次连续写（同一 cache line 附近） */
    for (uint32_t i = 0; i < 32u; i++) sbuf[i * 4u] = (uint8_t)i;
    printf("C 32 stores ok\r\n");

    /* D: 一个 cache line 之外的一次写（会触发 write-allocate） */
    sbuf[1024] = 0xA5;
    printf("D far store ok (%x)\r\n", sbuf[1024]);

    /* E: 跨 8 个 cache line 写 */
    for (uint32_t i = 0; i < 8u; i++) sbuf[i * 64u] = (uint8_t)(0x10u + i);
    printf("E 8-line stores ok\r\n");

    /* F: 大数组里跨 32KB 的 16 次写（每 2KB 一次，必然每次换行换组） */
    for (uint32_t i = 0; i < 16u; i++) bbuf[i * 2048u] = (uint8_t)i;
    printf("F 16 far stores ok\r\n");

    /* G: 读回 F 写的内容 */
    uint32_t bad = 0;
    for (uint32_t i = 0; i < 16u; i++) if (bbuf[i * 2048u] != (uint8_t)i) bad++;
    printf("G readback bad=%u\r\n", bad);

    /* H: 小范围指针追逐（全命中） */
    static uint32_t idx_s[32];
    for (uint32_t i = 0; i < 32u; i++) idx_s[i] = (i + 1u) & 31u;
    printf("H idx init ok\r\n");
    uint32_t cur = 0, t0 = timer_cycles();
    for (uint32_t s = 0; s < 200u; s++) { cur = idx_s[cur]; sink += sbuf[cur * 64u]; }
    printf("H small chase cycles=%u\r\n", timer_cycles() - t0);

    /* J: 大范围指针追逐（每步必 miss），只跑 8 步 */
    static uint32_t idx_b[512] __attribute__((aligned(64)));
    for (uint32_t i = 0; i < 512u; i++) idx_b[i] = (i + 1u) & 511u;
    printf("J idx_big init ok\r\n");
    cur = 0;
    t0 = timer_cycles();
    for (uint32_t s = 0; s < 8u; s++) {
        cur = idx_b[cur];
        sink += bbuf[cur * 64u];
        printf("  J step=%u cycles=%u\r\n", s, timer_cycles() - t0);
    }
    printf("J big chase done cycles=%u\r\n", timer_cycles() - t0);

    printf("=== P4 end ===\r\n");
    return 0;
}
