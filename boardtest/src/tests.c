/*
 * tests.c  ---  上板自检的各项测试
 *
 * 排列顺序是按依赖关系来的：越靠前的越基础，第一项失败就说明问题在最底层。
 *   1-2   CPU 基本运算与分支          失败 => 核本身或编译产物有问题
 *   3-5   MMIO（ID/SCRATCH/CYCLE）    失败 => 数据互连译码或 simple_mmio
 *   6-9   片内数据 RAM                失败 => data_bram_adapter / 字节写使能
 *   10-13 异常机制（非法指令/访问错误/非对齐）  失败 => CSR / mtvec / mepc / mtval
 *   14-15 UART 存在性与发送           失败 => uart_mmio 译码或 ENABLE_UART
 *   16-17 DDR 读写与地址不混叠        失败 => DDR IP / 桥 / 地址换算
 *   18    UART 接收中断（需要 PC 配合）失败 => RX 引脚 / FIFO / IRQ 通路
 */
#include "boardtest.h"
#include "soc_mmio.h"

/* 链接脚本给出的自检专用 RAM 区（程序自己的数据/栈都不在里面） */
extern char __ramtest_start[];
extern char __ramtest_end[];

#define RAMTEST_WORDS  (((uint32_t)(__ramtest_end - __ramtest_start)) / 4u)

/* 每项测试的"第一个失败的子项"名字与实测/期望值，便于定位 */
static const char *g_sub;
static uint32_t    g_got, g_want;

#define SUB(name)        do { if (!g_sub) g_sub = (name); } while (0)
#define CHECK(cond, nm)  do { if (!(cond)) SUB(nm); } while (0)
#define CHECK2(cond, nm, got, want) \
    do { if (!(cond)) { if (!g_sub) { g_sub = (nm); g_got = (uint32_t)(got); g_want = (uint32_t)(want); } } } while (0)
#define FAILF(...)       do { bt_note(__VA_ARGS__); return BT_FAIL; } while (0)
#define PASSF(...)       do { bt_note(__VA_ARGS__); return BT_PASS; } while (0)

/* ================================================================== */
/* 1. CPU 基本运算                                                     */
/* ================================================================== */
static int t_cpu_alu(void)
{
    volatile uint32_t u1 = 0xF0000000u, u2 = 0x0F0F0F0Fu;
    volatile int32_t  s1 = -100, s2 = 7;

    g_sub = 0; g_got = 0; g_want = 0;
    CHECK2((u1 + u2) == 0xFF0F0F0Fu, "add", u1 + u2, 0xFF0F0F0Fu);
    CHECK2((u1 - u2) == 0xE0F0F0F1u, "sub", u1 - u2, 0xE0F0F0F1u);
    CHECK2((u1 & u2) == 0x00000000u, "and", u1 & u2, 0u);
    CHECK2((u1 | u2) == 0xFF0F0F0Fu, "or", u1 | u2, 0xFF0F0F0Fu);
    CHECK2((u1 ^ u2) == 0xFF0F0F0Fu, "xor", u1 ^ u2, 0xFF0F0F0Fu);
    CHECK2(((uint32_t)(s1 + s2)) == 0xFFFFFFA3u, "add(signed)",
           (uint32_t)(s1 + s2), 0xFFFFFFA3u);
    CHECK2((s1 >> 1) == -50, "sra", (uint32_t)(s1 >> 1), (uint32_t)-50);
    CHECK2(((uint32_t)u1 >> 28) == 0xFu, "srl", (uint32_t)u1 >> 28, 0xFu);
    CHECK2((u1 << 4) == 0x00000000u, "sll", u1 << 4, 0u);
    CHECK2((1u << 31) == 0x80000000u, "sll31", 1u << 31, 0x80000000u);
    CHECK2((s1 < s2) == 1, "slt(signed)", (uint32_t)(s1 < s2), 1u);
    CHECK2((u1 < u2) == 0, "sltu", (uint32_t)(u1 < u2), 0u);
    CHECK2((int32_t)(s1 | 0x1F) == -97, "ori",
           (uint32_t)(int32_t)(s1 | 0x1F), (uint32_t)-97);   /* -100|0x1F = 0xFFFFFF9F = -97 */
    CHECK2((((uint32_t)s2) << 8) == 0x00000700u, "slli",
           ((uint32_t)s2) << 8, 0x00000700u);

    if (g_sub)
        FAILF("第一个不符的子项: %s (got=0x%08x want=0x%08x)", g_sub, g_got, g_want);
    PASSF("14 项运算全部通过");
}

/* ================================================================== */
/* 2. CPU 分支与循环                                                   */
/* ================================================================== */
static int t_cpu_branch(void)
{
    uint32_t i, sum = 0;
    int32_t  acc = 0;

    for (i = 0; i < 100u; i++)
        sum += i;                       /* bne + 有符号/无符号混合比较 */
    if (sum != 4950u)
        FAILF("0..99 累加 = %u, 期望 4950", sum);

    for (i = 0; i < 10u; i++)
        acc -= 3;
    if (acc != -30)
        FAILF("负向循环 = %d, 期望 -30", (int)acc);

    {   /* 有符号 vs 无符号比较，验证 blt/bge 与 bltu/bgeu 走的是不同比较 */
        volatile int32_t  a = -1;
        volatile uint32_t b = 1u;
        if (!(a < 0))
            FAILF("blt 有符号比较错误");
        if ((uint32_t)a < b)
            FAILF("bltu 把 -1 当成了小数");
    }
    PASSF("累加/负向循环/有符号与无符号比较均正确");
}

/* ================================================================== */
/* 3. simple_mmio 寄存器识别                                           */
/* ================================================================== */
static int t_mmio_id(void)
{
    uint32_t id;
    bt_trap_reset();
    id = MMIO_ID;
    if (bt_trap_fired())
        FAILF("读 0x10000004 触发异常，MMIO 未映射？mcause=%u", (uint32_t)g_trap_cause);
    if (id != MMIO_ID_VALUE)
        FAILF("ID = 0x%08x, 期望 0x%08x", id, (uint32_t)MMIO_ID_VALUE);
    PASSF("ID = 0x%08x （'MMIO'）", id);
}

/* ================================================================== */
/* 4. SCRATCH 读写 + 字节/半字写使能                                   */
/* 软件维护一份影子值，用同样的字节语义更新，再整体比较 ——             */
/* 这样能同时验证 wstrb 与数据移位是否正确。                           */
/* ================================================================== */
static int t_mmio_scratch(void)
{
    volatile uint8_t  *s8  = (volatile uint8_t  *)&MMIO_SCRATCH;
    volatile uint16_t *s16 = (volatile uint16_t *)&MMIO_SCRATCH;
    uint32_t shadow = 0, got;

    bt_trap_reset();

    MMIO_SCRATCH = 0xA5A5A5A5u;                 shadow = 0xA5A5A5A5u;
    got = MMIO_SCRATCH;
    if (got != shadow)
        FAILF("SW 写回的 = 0x%08x, 期望 0x%08x", got, shadow);

    s8[1] = 0x5Au;                              /* byte1 = 0x5A */
    shadow = (shadow & ~0x0000FF00u) | 0x00005A00u;
    got = MMIO_SCRATCH;
    if (got != shadow)
        FAILF("SB 到 +1 后 = 0x%08x, 期望 0x%08x", got, shadow);

    s16[1] = 0x1234u;                           /* bytes2..3 = 0x1234 */
    shadow = (shadow & ~0xFFFF0000u) | 0x12340000u;
    got = MMIO_SCRATCH;
    if (got != shadow)
        FAILF("SH 到 +2 后 = 0x%08x, 期望 0x%08x", got, shadow);

    s8[3] = 0x00u;                              /* byte3 = 0 清掉 */
    shadow = shadow & ~0xFF000000u;
    got = MMIO_SCRATCH;
    if (got != shadow)
        FAILF("SB 到 +3 后 = 0x%08x, 期望 0x%08x", got, shadow);

    MMIO_SCRATCH = 0xFFFFFFFFu;
    got = MMIO_SCRATCH;
    if (got != 0xFFFFFFFFu)
        FAILF("全 1 写回 = 0x%08x", got);

    MMIO_SCRATCH = 0u;
    got = MMIO_SCRATCH;
    if (got != 0u)
        FAILF("清零后 = 0x%08x", got);

    if (bt_trap_fired())
        FAILF("SCRATCH 访问触发异常 mcause=%u mtval=0x%08x",
              (uint32_t)g_trap_cause, (uint32_t)g_trap_tval);

    PASSF("SW/SB/SH 写使能与数据移位正确（含 +1/+2/+3 偏移）");
}

/* ================================================================== */
/* 5. CYCLE 计数器单调递增                                             */
/* ================================================================== */
static int t_mmio_cycle(void)
{
    uint32_t c0, c1, i;
    bt_trap_reset();
    c0 = MMIO_CYCLE;
    for (i = 0; i < 2000u; i++)
        __asm__ volatile("" ::: "memory");
    c1 = MMIO_CYCLE;
    if (bt_trap_fired())
        FAILF("读 CYCLE 触发异常 mcause=%u", (uint32_t)g_trap_cause);
    if (c1 == c0)
        FAILF("两次读数相同 (=%u)，计数器没有走动", c0);
    PASSF("2000 次空循环期间走了 %u 拍", (uint32_t)(c1 - c0));
}

/* ================================================================== */
/* 6. 片内 RAM：walking-1 与全 0/全 1                                  */
/* ================================================================== */
static int t_ram_walking1(void)
{
    volatile uint32_t *p = (volatile uint32_t *)__ramtest_start;
    uint32_t i, bad = 0xFFFFFFFFu;

    for (i = 0; i < RAMTEST_WORDS; i++)
        p[i] = 1u << (i & 31u);
    for (i = 0; i < RAMTEST_WORDS; i++)
        if (p[i] != (1u << (i & 31u))) { bad = i; break; }
    if (bad != 0xFFFFFFFFu)
        FAILF("word[%u] = 0x%08x, 期望 0x%08x", bad, p[bad], 1u << (bad & 31u));

    for (i = 0; i < RAMTEST_WORDS; i++)
        p[i] = 0xFFFFFFFFu;
    for (i = 0; i < RAMTEST_WORDS; i++)
        if (p[i] != 0xFFFFFFFFu) { bad = i; break; }
    if (bad != 0xFFFFFFFFu)
        FAILF("全 1 时 word[%u] = 0x%08x", bad, p[bad]);

    for (i = 0; i < RAMTEST_WORDS; i++)
        p[i] = 0u;
    for (i = 0; i < RAMTEST_WORDS; i++)
        if (p[i] != 0u) { bad = i; break; }
    if (bad != 0xFFFFFFFFu)
        FAILF("全 0 时 word[%u] = 0x%08x", bad, p[bad]);

    PASSF("%u 个字（%u 字节）walking-1 / 全0 / 全1 通过",
          RAMTEST_WORDS, RAMTEST_WORDS * 4u);
}

/* ================================================================== */
/* 7. 片内 RAM：地址混入数据（检测地址线粘连/译码错误）                */
/* ================================================================== */
static int t_ram_addr_in_addr(void)
{
    volatile uint32_t *p = (volatile uint32_t *)__ramtest_start;
    uint32_t i, bad = 0xFFFFFFFFu;

    for (i = 0; i < RAMTEST_WORDS; i++)
        p[i] = ((uint32_t)__ramtest_start + i * 4u) ^ 0xA5A5A5A5u;
    for (i = 0; i < RAMTEST_WORDS; i++) {
        uint32_t want = ((uint32_t)__ramtest_start + i * 4u) ^ 0xA5A5A5A5u;
        if (p[i] != want) { bad = i; break; }
    }
    if (bad != 0xFFFFFFFFu)
        FAILF("word[%u] = 0x%08x, 期望 0x%08x（地址线可能粘连）", bad, p[bad],
              ((uint32_t)__ramtest_start + bad * 4u) ^ 0xA5A5A5A5u);

    PASSF("%u 个字地址混入数据全部一致", RAMTEST_WORDS);
}

/* ================================================================== */
/* 8. 片内 RAM：字节访问互不串扰                                       */
/* ================================================================== */
static int t_ram_byte_lanes(void)
{
    volatile uint8_t *b = (volatile uint8_t *)__ramtest_start;
    uint32_t i, bad = 0xFFFFFFFFu, want = 0, val = 1u;

    for (i = 0; i < 128u; i++) {
        b[i] = (uint8_t)val;
        val += 7u;                       /* 不用乘法，避免引入 libgcc 的 __mulsi3 */
        if (val > 0xFFu)
            val -= 0x100u;
    }
    val = 1u;
    for (i = 0; i < 128u; i++) {
        if (b[i] != (uint8_t)val) { bad = i; want = val; break; }
        val += 7u;
        if (val > 0xFFu)
            val -= 0x100u;
    }
    if (bad != 0xFFFFFFFFu)
        FAILF("byte[%u] = 0x%02x, 期望 0x%02x（字节写使能或相邻字节串扰）",
              bad, b[bad], (uint32_t)want);

    PASSF("128 个字节逐个写回一致，相邻字节无串扰");
}

/* ================================================================== */
/* 9. 片内 RAM：半字访问不影响同字的另一半                             */
/* ================================================================== */
static int t_ram_half_lanes(void)
{
    volatile uint32_t *w = (volatile uint32_t *)__ramtest_start;
    volatile uint16_t *h = (volatile uint16_t *)__ramtest_start;
    uint32_t i;

    for (i = 0; i < 32u; i++) {
        w[i] = 0xDEADBEEFu;
        h[i * 2u + 1u] = 0x1234u;                     /* 写高半字（+2 字节） */
        if (w[i] != 0x1234BEEFu)
            FAILF("word[%u] = 0x%08x, 期望 0x1234BEEF（高半字写破坏了低半字）",
                  i, w[i]);
    }
    for (i = 0; i < 32u; i++) {
        w[i] = 0xDEADBEEFu;
        h[i * 2u] = 0x5678u;                          /* 写低半字 */
        if (w[i] != 0xDEAD5678u)
            FAILF("word[%u] = 0x%08x, 期望 0xDEAD5678（低半字写破坏了高半字）",
                  i, w[i]);
    }
    PASSF("高/低半字分别写入 32 个字，另一半均保持不变");
}

/* ================================================================== */
/* 10. 异常：非法指令                                                  */
/* ================================================================== */
static int t_trap_illegal(void)
{
    bt_trap_reset();
    __asm__ volatile(".word 0x00000000");    /* 非法指令，处理函数会跳过它 */
    if (!bt_trap_fired())
        FAILF("非法指令没有触发异常（异常机制未生效？）");
    if (g_trap_cause != 2u)
        FAILF("mcause = %u, 期望 2 (illegal instruction)", (uint32_t)g_trap_cause);
    if (g_trap_epc == 0u)
        FAILF("mepc = 0，没有记录故障指令地址");
    PASSF("mcause=2, mepc=0x%08x，且已正确返回继续执行", (uint32_t)g_trap_epc);
}

/* ================================================================== */
/* 11. 异常：访问未映射地址（走互连的错误响应）                        */
/* ================================================================== */
static int t_trap_load_unmapped(void)
{
    volatile uint32_t junk;
    bt_trap_reset();
    junk = *(volatile uint32_t *)0x20000000u;     /* 数据总线上没有任何从机 */
    (void)junk;
    if (!bt_trap_fired())
        FAILF("读 0x20000000 没有触发异常（访问故障通路有问题）");
    if (g_trap_cause != 5u)
        FAILF("mcause = %u, 期望 5 (load access fault)", (uint32_t)g_trap_cause);
    if (g_trap_tval != 0x20000000u)
        FAILF("mtval = 0x%08x, 期望 0x20000000", (uint32_t)g_trap_tval);
    PASSF("mcause=5, mtval=0x%08x", (uint32_t)g_trap_tval);
}

/* ================================================================== */
/* 12. 异常：MMIO 窗口内未实现的偏移                                   */
/* ================================================================== */
static int t_trap_mmio_offset(void)
{
    volatile uint32_t junk;
    bt_trap_reset();
    junk = *(volatile uint32_t *)0x10000020u;     /* 4 KiB 窗口内，但没实现 */
    (void)junk;
    if (!bt_trap_fired())
        FAILF("读 0x10000020 没有触发异常（simple_mmio 的默认分支应报错）");
    if (g_trap_cause != 5u)
        FAILF("mcause = %u, 期望 5", (uint32_t)g_trap_cause);
    if (g_trap_tval != 0x10000020u)
        FAILF("mtval = 0x%08x, 期望 0x10000020", (uint32_t)g_trap_tval);
    PASSF("未实现偏移正确报访问故障 mtval=0x%08x", (uint32_t)g_trap_tval);
}

/* ================================================================== */
/* 13. 异常：非对齐访问                                                */
/* ================================================================== */
static int t_trap_misaligned(void)
{
    volatile uint16_t junk;
    uint32_t odd = ((uint32_t)__ramtest_start) + 1u;
    bt_trap_reset();
    junk = *(volatile uint16_t *)odd;
    (void)junk;
    if (!bt_trap_fired())
        FAILF("奇地址 LH 没有触发异常（本核按规范应报 cause 4）");
    if (g_trap_cause != 4u)
        FAILF("mcause = %u, 期望 4 (load address misaligned)", (uint32_t)g_trap_cause);
    PASSF("mcause=4, mtval=0x%08x", (uint32_t)g_trap_tval);
}

/* ================================================================== */
/* 14. UART 是否存在                                                   */
/* ================================================================== */
static int t_uart_present(void)
{
    uint8_t st;
    bt_trap_reset();
    st = bt_uart_status();
    if (bt_trap_fired())
        FAILF("读 UART STATUS 触发异常，uart_mmio 未映射（soc_top 的 ENABLE_UART 是否为 1？）");
    if (!(st & UART_ST_TX_READY))
        FAILF("STATUS=0x%02x 的 TX_READY(bit0) 不是 1", st);
    PASSF("STATUS=0x%02x, TX_READY=1, TX_BUSY=0", st);
}

/* ================================================================== */
/* 15. UART 发送                                                       */
/* ================================================================== */
static int t_uart_tx(void)
{
    bt_trap_reset();
    bt_puts("[boardtest] UART-TX-MARKER-0123456789\r\n");
    if (bt_trap_fired())
        FAILF("发送过程中触发异常 mcause=%u", (uint32_t)g_trap_cause);
    if (!bt_uart_tx_ready())
        FAILF("发送结束后 TX_READY 没有恢复");
    PASSF("已发出 UART-TX-MARKER 串；PC 端能看到即为 TX 通路正常");
}

/* ================================================================== */
/* 16. DDR：一个窗口内的读写                                           */
/* ================================================================== */
static int t_ddr_window(void)
{
    volatile uint32_t *d = (volatile uint32_t *)DDR_BASE;
    uint32_t i, bad = 0xFFFFFFFFu;

    bt_trap_reset();
    d[0] = 0xA5A5A5A5u;
    if (bt_trap_fired())
        FAILF("写 DDR 0x%08x 触发异常 mcause=%u（ENABLE_DDR=0 或 DDR 未初始化）",
              (uint32_t)DDR_BASE, (uint32_t)g_trap_cause);
    if (d[0] != 0xA5A5A5A5u)
        FAILF("DDR[0] 回读 = 0x%08x, 期望 0xA5A5A5A5", d[0]);

    for (i = 0; i < 1024u; i++)
        d[i] = ((uint32_t)DDR_BASE + i * 4u) ^ 0x5A5A5A5Au;
    for (i = 0; i < 1024u; i++) {
        uint32_t want = ((uint32_t)DDR_BASE + i * 4u) ^ 0x5A5A5A5Au;
        if (d[i] != want) { bad = i; break; }
    }
    if (bad != 0xFFFFFFFFu)
        FAILF("DDR word[%u] = 0x%08x, 期望 0x%08x", bad, d[bad],
              ((uint32_t)DDR_BASE + bad * 4u) ^ 0x5A5A5A5Au);

    PASSF("0x%08x 起 4 KiB 地址混入数据全部一致", (uint32_t)DDR_BASE);
}

/* ================================================================== */
/* 17. DDR：远端地址不混叠（验证地址换算，不是只测了开头）             */
/* ================================================================== */
static int t_ddr_alias(void)
{
    volatile uint32_t *a = (volatile uint32_t *)DDR_BASE;
    volatile uint32_t *b = (volatile uint32_t *)(DDR_BASE + 0x00200000u);  /* +2 MiB */
    volatile uint32_t *c = (volatile uint32_t *)(DDR_BASE + 0x01000000u);  /* +16 MiB */

    bt_trap_reset();
    a[0] = 0x11111111u;
    b[0] = 0x22222222u;
    c[0] = 0x33333333u;
    if (bt_trap_fired())
        FAILF("远端 DDR 地址触发异常 mcause=%u mtval=0x%08x",
              (uint32_t)g_trap_cause, (uint32_t)g_trap_tval);
    if (a[0] != 0x11111111u || b[0] != 0x22222222u || c[0] != 0x33333333u)
        FAILF("三处地址混叠: +0=0x%08x +2M=0x%08x +16M=0x%08x",
              a[0], b[0], c[0]);
    PASSF("+0 / +2 MiB / +16 MiB 三处互不影响");
}

/* ================================================================== */
/* 18. UART 接收中断（需要 PC 端在 2 秒内发一个字节）                  */
/* ================================================================== */
#ifndef BT_RX_WAIT_SECONDS
#define BT_RX_WAIT_SECONDS 2
#endif

static int t_uart_rx_irq(void)
{
#if BT_RX_WAIT_SECONDS == 0
    bt_note("编译期已关闭（BT_RX_WAIT_SECONDS=0）");
    return BT_SKIP;
#else
    uint32_t t0, limit, mie;

    if (!g_console_ok) {
        bt_note("UART 不可用，跳过");
        return BT_SKIP;
    }

    g_irq_count = 0;
    g_irq_byte  = 0;

    UART_CONTROL = UART_CTL_IRQ_ENABLE;            /* bit8：使能 RX 中断 */
    CSR_READ(mie, mie);
    CSR_WRITE(mie, mie | MIE_MEIE);
    CSR_SET(mstatus, MSTATUS_MIE);                 /* 开全局中断 */

    t0    = bt_cycle();
    limit = (uint32_t)BT_RX_WAIT_SECONDS * (uint32_t)SOC_CPU_HZ;
    while ((uint32_t)(bt_cycle() - t0) < limit) {
        if (g_irq_count)
            break;
    }

    CSR_CLR(mstatus, MSTATUS_MIE);                 /* 先关全局再撤使能 */
    CSR_READ(mie, mie);
    CSR_WRITE(mie, mie & ~MIE_MEIE);
    UART_CONTROL = UART_CTL_IRQ_DISABLE;

    if (g_irq_count == 0u)
        bt_note("参考: 在 %d 秒内从 PC 发一个字节即可测到；未收到属正常",
                BT_RX_WAIT_SECONDS);
    else
        bt_note("收到 %u 次中断, ISR 读到的字节 = 0x%02x ('%c')",
                (uint32_t)g_irq_count, (uint32_t)g_irq_byte,
                (g_irq_byte >= 32u && g_irq_byte < 127u) ? (char)g_irq_byte : '.');

    return (g_irq_count == 0u) ? BT_SKIP : BT_PASS;
#endif
}

/* ================================================================== */
/* 测试表                                                              */
/* ================================================================== */
const bt_case bt_cases[] = {
    { "CPU 基本整数运算",        t_cpu_alu },
    { "CPU 分支与循环",          t_cpu_branch },
    { "MMIO ID 识别",            t_mmio_id },
    { "MMIO SCRATCH 字节写使能", t_mmio_scratch },
    { "MMIO CYCLE 递增",         t_mmio_cycle },
    { "片内 RAM walking-1",      t_ram_walking1 },
    { "片内 RAM 地址混入数据",   t_ram_addr_in_addr },
    { "片内 RAM 字节访问",       t_ram_byte_lanes },
    { "片内 RAM 半字访问",       t_ram_half_lanes },
    { "异常 非法指令",           t_trap_illegal },
    { "异常 未映射地址访问",     t_trap_load_unmapped },
    { "异常 MMIO 未实现偏移",    t_trap_mmio_offset },
    { "异常 非对齐访存",         t_trap_misaligned },
    { "UART 存在性",             t_uart_present },
    { "UART 发送",               t_uart_tx },
    { "DDR 窗口读写",            t_ddr_window },
    { "DDR 远端地址不混叠",      t_ddr_alias },
    { "UART 接收中断",           t_uart_rx_irq },
};

const int bt_case_count = (int)(sizeof(bt_cases) / sizeof(bt_cases[0]));
