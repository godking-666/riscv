/*
 * core_portme.c  ---  本工程 CoreMark 移植层
 *
 * 提供官方 CoreMark 要求的平台相关函数：
 *   portable_init / portable_fini / start_time / stop_time / get_time / time_in_secs
 *   portable_malloc / portable_free / default_num_contexts / 种子变量
 *
 * 计时源：simple_mmio 的 CYCLE 寄存器（0x1000_0008），每 core_clk 加一，
 *         与 CPU 同频，所以 ticks 就是 CPU 周期数，正是 CoreMark/MHz 需要的量。
 * 输出  ：uart_mmio 的 TX_DATA/STATUS（115200 8N1 @ 93.75 MHz）。
 *
 * 编译期开关：
 *   CM_CONSOLE=1  使用 UART 输出（默认）。要求 soc_top 的 ENABLE_UART=1。
 *   CM_CONSOLE=0  完全静默，只做计算（用于没有 UART 从机的仿真环境）。
 *   CM_UART_TIMEOUT  轮询 TX_READY 的最大次数，防止 UART 未接入时死等。
 */
#include "coremark.h"
#include "core_portme.h"
#include "soc_mmio.h"

#ifndef CM_CONSOLE
#define CM_CONSOLE 1
#endif
#ifndef CM_UART_TIMEOUT
#define CM_UART_TIMEOUT 2000000u
#endif

/* ------------------------------------------------------------------ */
/* 官方 CoreMark 需要的种子变量                                        */
/* PERFORMANCE_RUN : seed1=0 seed2=0 seed3=0x66 -> 官方 2K performance run */
/* VALIDATION_RUN  : seed1=0x3415 seed2=0x3415 seed3=0x66                  */
/* PROFILE_RUN     : 8 8 8                                                 */
/* seed4 = ITERATIONS （-DITERATIONS=n，n=0 时 CoreMark 自动确定到 >=10 秒）*/
/* ------------------------------------------------------------------ */
#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;   /* 0 = 三种算法全跑 */

ee_u32 default_num_contexts = 1;

/* 结果状态：+1 成功 / -1 失败 / 0 未判定。由 ee_printf 观察到官方结论文本时置位，
 * portable_fini 再把它写到 simple_mmio 的 TEST_STATUS，用于板上 LED 指示。
 * 这样不需要改动官方 core_main.c。 */
volatile int cm_result_ok = 0;

/* ------------------------------------------------------------------ */
/* 计时                                                                */
/* ------------------------------------------------------------------ */
CORETIMETYPE barebones_clock(void)
{
    return (CORETIMETYPE)MMIO_CYCLE;
}

#define GETMYTIME(_t)        (*_t = barebones_clock())
#define MYTIMEDIFF(fin, ini) ((ee_u32)((fin) - (ini)))
#define TIMER_RES_DIVIDER    1
#define SAMPLE_TIME_IMPLEMENTATION 1
#define EE_TICKS_PER_SEC     (CM_TICKS_PER_SEC / TIMER_RES_DIVIDER)

static CORETIMETYPE start_time_val, stop_time_val;
static ee_u32       cm_start_seen, cm_stop_seen;
static ee_u32       cm_elapsed_ticks;

void start_time(void)
{
    GETMYTIME(&start_time_val);
    cm_start_seen = 1;
}

void stop_time(void)
{
    GETMYTIME(&stop_time_val);
    cm_stop_seen = 1;
    cm_elapsed_ticks = MYTIMEDIFF(stop_time_val, start_time_val);
}

CORE_TICKS get_time(void)
{
    return (CORE_TICKS)cm_elapsed_ticks;
}

double cm_ticks_to_secs(ee_u32 ticks)
{
    return (double)ticks / (double)EE_TICKS_PER_SEC;
}

secs_ret time_in_secs(CORE_TICKS ticks)
{
    secs_ret retval = ((secs_ret)ticks) / (secs_ret)EE_TICKS_PER_SEC;
    return retval;
}

/* ------------------------------------------------------------------ */
/* 控制台                                                              */
/* ------------------------------------------------------------------ */
void cm_console_putc(char c)
{
#if CM_CONSOLE
    ee_u32 guard = 0;
    /* 必须等 TX_READY：忙时写 TX_DATA 会返回总线错误，
     * 而总线错误会升级成 store access fault 异常。 */
    while (((UART_STATUS & UART_ST_TX_READY) == 0u) && (guard < CM_UART_TIMEOUT))
        guard++;
    UART_TX_DATA = (ee_u8)c;
#else
    (void)c;
#endif
}

ee_u8 cm_console_rx_ready(void)
{
#if CM_CONSOLE
    return (UART_STATUS & UART_ST_RX_NOT_EMPTY) ? 1u : 0u;
#else
    return 0u;
#endif
}

ee_u8 cm_console_getc(void)
{
#if CM_CONSOLE
    if (!cm_console_rx_ready())
        return 0u;
    return UART_RX_DATA;
#else
    return 0u;
#endif
}

/* ------------------------------------------------------------------ */
/* 目标相关初始化 / 结束                                                */
/* ------------------------------------------------------------------ */
void portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc;
    (void)argv;

    /* 让板上 LED 显示 RUN */
    MMIO_TEST_STATUS = TEST_RUN;

    ee_printf("\n");
    ee_printf("=== CoreMark on myriscv (RV32I, 5-stage) ===\n");
    ee_printf("CPU clock (core_clk) : %lu Hz\n", (ee_u32)SOC_CPU_HZ);
    ee_printf("Timer                : simple_mmio CYCLE @ 0x%08lx (32-bit)\n",
              (ee_u32)MMIO_BASE + 0x08u);
    ee_printf("MMIO ID              : 0x%08lx (expect 0x%08lx)\n",
              (ee_u32)MMIO_ID, (ee_u32)MMIO_ID_VALUE);
    ee_printf("Iterations macro     : %ld (0 = 由 CoreMark 自动确定到 >=10 秒)\n",
              (long)ITERATIONS);
    ee_printf("\n");

    if (sizeof(ee_ptr_int) != sizeof(ee_u8 *))
        ee_printf("ERROR! ee_ptr_int cannot hold a pointer!\n");
    if (sizeof(ee_u32) != 4)
        ee_printf("ERROR! ee_u32 is not 32-bit!\n");
    if (sizeof(struct list_head_s) > 128)
        ee_printf("WARNING! list_head is larger than expected\n");

    p->portable_id = 1;
}

void portable_fini(core_portable *p)
{
    p->portable_id = 0;

    /* 32 位计数器回绕检查：93.75 MHz 下 2^32 拍约 45.8 秒 */
    if (cm_start_seen && cm_stop_seen) {
        if (cm_elapsed_ticks > 0xF0000000u) {
            ee_printf("\nWARNING! elapsed ticks = %lu, close to the 32-bit wrap "
                      "(45.8 s at %lu Hz). Lower ITERATIONS.\n",
                      (ee_u32)cm_elapsed_ticks, (ee_u32)SOC_CPU_HZ);
        }
        if (cm_elapsed_ticks < (ee_u32)EE_TICKS_PER_SEC) {
            ee_printf("\nNOTE: elapsed ticks = %lu (< 1 s).\n",
                      (ee_u32)cm_elapsed_ticks);
        }
    }

    if (cm_result_ok > 0) {
        MMIO_TEST_STATUS = TEST_PASS;
        ee_printf("\nRESULT: PASS CoreMark validated, exiting to idle loop.\n");
    } else if (cm_result_ok < 0) {
        MMIO_TEST_STATUS = TEST_FAIL;
        ee_printf("\nRESULT: FAIL CoreMark reported errors.\n");
    } else {
        ee_printf("\nRESULT: UNKNOWN (no validation text observed).\n");
    }
}

/* 只有 MEM_METHOD==MEM_MALLOC 才会用到；MEM_STATIC 下被 --gc-sections 丢弃。
 * 这里提供最简单的堆实现，便于以后切换到 MEM_MALLOC 时不用另写。 */
#ifdef CM_HEAP_SIZE
static ee_u8  cm_heap[CM_HEAP_SIZE];
static ee_u32 cm_heap_used;
void *portable_malloc(ee_size_t size)
{
    ee_u32 aligned = (ee_u32)((size + 7u) & ~7u);
    if (cm_heap_used + aligned > (ee_u32)CM_HEAP_SIZE)
        return NULL;
    void *p = &cm_heap[cm_heap_used];
    cm_heap_used += aligned;
    return p;
}
void portable_free(void *p) { (void)p; }
#else
void *portable_malloc(ee_size_t size) { (void)size; return NULL; }
void portable_free(void *p) { (void)p; }
#endif

/* ------------------------------------------------------------------ */
/* 异常处理：把 mcause/mepc 打出来并置 FAIL，然后停住                    */
/* start.S 会把 mtvec 指向这里。CoreMark 正常运行不应触发异常，          */
/* 一旦触发基本可以断定是访存地址错误（例如读到了未接入的地址）。        */
/* ------------------------------------------------------------------ */
void cm_trap_report(ee_u32 mcause, ee_u32 mepc, ee_u32 mtval)
{
    ee_printf("\n*** TRAP ***\n");
    ee_printf("mcause = 0x%08lx\n", (unsigned long)mcause);
    ee_printf("mepc   = 0x%08lx\n", (unsigned long)mepc);
    ee_printf("mtval  = 0x%08lx\n", (unsigned long)mtval);
    ee_printf("hint: 0x00000000 region loads must hit the data-bus RAM; "
              "0x10001000 needs ENABLE_UART=1.\n");
    MMIO_TEST_STATUS = TEST_FAIL;
    cm_result_ok = -1;
    for (;;)
        ;
}
