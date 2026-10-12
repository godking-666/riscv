/* File : core_portme.h  ---  本工程 CoreMark 移植层配置
 *
 * 依据 EEMBC CoreMark v1.01 的 barebones 移植模板改写，针对：
 *   自研五级流水 RV32I CPU / 93.75 MHz core_clk /
 *   16 KiB 片内指令 ROM + 16 KiB 片内数据 RAM + simple_mmio + uart_mmio
 *
 * 关键配置说明：
 *   HAS_FLOAT    = 1  必须为 1，否则 core_main.c 不会打印官方
 *                     "CoreMark 1.0 : <分数> / <编译器> <参数> / <内存位置>" 那一行
 *                     （该行只在 known_id==3，即 2K performance run 下输出，且被 #if HAS_FLOAT 包裹）。
 *                     代价是需要软件浮点（libgcc）和一个支持 %f 的 ee_printf。
 *   MEM_METHOD   = MEM_STATIC  数据块用静态数组，不依赖 malloc/堆。
 *   SEED_METHOD  = SEED_VOLATILE  种子来自 core_portme.c 里的 volatile 变量，
 *                     配合 -DPERFORMANCE_RUN=1 得到官方 2K performance run 的已知种子，
 *                     CoreMark 会用 list/matrix/state 三张已知 CRC 表自动校验结果。
 *   MAIN_HAS_NOARGC = 1  裸机没有 argc/argv。
 */
#ifndef CORE_PORTME_H
#define CORE_PORTME_H

#include <stddef.h>
#include "soc_mmio.h"   /* SOC_CPU_HZ 与 MMIO 地址 */

/* ITERATIONS 由构建脚本用 -DITERATIONS=n 传入；漏传时给个安全默认值。
 * n = 0 表示让 CoreMark 自己试探到 >=10 秒（官方支持的行为）。 */
#ifndef ITERATIONS
#define ITERATIONS 0
#endif

/************************/
/* Data types and settings */
/************************/

#ifndef HAS_FLOAT
#define HAS_FLOAT 1
#endif
#ifndef HAS_TIME_H
#define HAS_TIME_H 0
#endif
#ifndef USE_CLOCK
#define USE_CLOCK 0
#endif
#ifndef HAS_STDIO
#define HAS_STDIO 0
#endif
#ifndef HAS_PRINTF
#define HAS_PRINTF 0
#endif

/* COMPILER_FLAGS 来自构建脚本的 -DFLAGS_STR="..."，会原样打印进报告，
 * 这是赛题要求的「统一编译参数披露」的一部分。 */
#ifndef COMPILER_VERSION
#ifdef __GNUC__
#define COMPILER_VERSION "GCC " __VERSION__
#else
#define COMPILER_VERSION "unknown compiler"
#endif
#endif
#ifndef COMPILER_FLAGS
#ifdef FLAGS_STR
#define COMPILER_FLAGS FLAGS_STR
#else
#define COMPILER_FLAGS "(FLAGS_STR not defined)"
#endif
#endif
#ifndef MEM_LOCATION
#define MEM_LOCATION "STATIC"
#endif

typedef signed short   ee_s16;
typedef unsigned short ee_u16;
typedef signed int     ee_s32;
typedef double         ee_f32;
typedef unsigned char  ee_u8;
typedef unsigned int   ee_u32;
typedef ee_u32         ee_ptr_int;   /* 必须能装下指针 */
typedef size_t         ee_size_t;

#ifndef NULL
#define NULL ((void *)0)
#endif

#define align_mem(x) (void *)(4 + (((ee_ptr_int)(x) - 1) & ~3))

/* CORE_TICKS = simple_mmio 的 32 位 CYCLE 计数器（每个 core_clk 加一）。
 * 注意：32 位在 93.75 MHz 下约 45.8 秒回绕，所以单次测量必须 < 45 秒。
 * core_portme.c 的 get_time() 会对接近回绕的读数给出告警。 */
#define CORETIMETYPE ee_u32
typedef ee_u32 CORE_TICKS;

#ifndef SEED_METHOD
#define SEED_METHOD SEED_VOLATILE
#endif

#ifndef MEM_METHOD
#define MEM_METHOD MEM_STATIC
#endif

#ifndef MULTITHREAD
#define MULTITHREAD 1
#define USE_PTHREAD 0
#define USE_FORK    0
#define USE_SOCKET  0
#endif

#ifndef MAIN_HAS_NOARGC
#define MAIN_HAS_NOARGC 1
#endif

#ifndef MAIN_HAS_NORETURN
#define MAIN_HAS_NORETURN 0
#endif

extern ee_u32 default_num_contexts;

typedef struct CORE_PORTABLE_S {
    ee_u8 portable_id;
} core_portable;

void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);

#if !defined(PROFILE_RUN) && !defined(PERFORMANCE_RUN) && !defined(VALIDATION_RUN)
#if (TOTAL_DATA_SIZE == 1200)
#define PROFILE_RUN 1
#elif (TOTAL_DATA_SIZE == 2000)
#define PERFORMANCE_RUN 1
#else
#define VALIDATION_RUN 1
#endif
#endif

int ee_printf(const char *fmt, ...);

/* ---- 本移植额外提供的接口 ---- */
/* CYCLE 计数器每 core_clk 一拍加一 */
#define CM_TICKS_PER_SEC   ((ee_u32)SOC_CPU_HZ)
/* 判定「必须至少运行 10 秒」用的秒数换算 */
double cm_ticks_to_secs(ee_u32 ticks);
/* 结果状态，供 portable_fini 上报到 MMIO TEST_STATUS（LED 指示） */
extern volatile int cm_result_ok;

#endif /* CORE_PORTME_H */
