/* 停摆验收测试：长时间打印 + 穿插跨 cache line 写
 *
 * 判据：能打印到 "STALLTEST end" 并返回 Loader ⇒ 停摆已消除（至少桥下游）；
 *       中途停住 ⇒ 根因在桥上游（CPU LSU 侧），看门狗覆盖不到。
 *
 * 输出量：1000 行 × ~46 字符 ≈ 46,000 字符 ≈ 4 秒（115200 波特）
 * 每 50 行做一次跨 cache line 写，逼出 D$ 的写分配/写回路径。
 */
#include <stdint.h>
#include "bsp.h"

static uint8_t buf[8 * 1024] __attribute__((aligned(64)));
volatile uint32_t sink;

int main(void)
{
    printf("\r\n=== STALLTEST begin ===\r\n");

    for (uint32_t line = 0; line < 1000u; line++) {
        /* 每 50 行写一个新 cache line（跨组，触发写分配；偶尔会驱逐脏行） */
        if ((line % 50u) == 0u) {
            uint32_t off = (line * 64u) % sizeof(buf);
            buf[off] = (uint8_t)line;
            sink += buf[off];
        }
        printf("line %u : 0123456789abcdefghijklmnopqrstuvwxyz\r\n", line);
        if (line == 500u) printf("--- half way ---\r\n");
    }

    printf("=== STALLTEST end ===\r\n");
    return 0;
}
