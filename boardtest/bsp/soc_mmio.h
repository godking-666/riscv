/*
 * soc_mmio.h - 本工程 SoC 的 MMIO 地址定义
 *
 * 与 myriscv/soc_top.v、simple_mmio.v、uart_mmio.v 的实际译码保持一致：
 *   simple_mmio : 0x1000_0000 起 4 KiB   （soc_top 默认 MMIO_BASE）
 *   uart_mmio   : 0x1000_1000 起 16 字节 （soc_top 默认 UART_BASE，ENABLE_UART=1）
 *   DDR         : 0x4000_0000 起 512 MiB
 *
 * 重要硬件约束（见 doc/SoC结构说明 与 data_bus_interconnect.v）：
 *   片内启动 ROM 只挂在**指令总线**上，数据总线只能访问 RAM / MMIO / UART / DDR。
 *   因此任何会被 load 读取的数据（.rodata、字符串、跳转表）都必须放在 RAM 里，
 *   不能放在 ROM 里。链接脚本 linker_onchip.ld 已按此划分。
 */
#ifndef SOC_MMIO_H
#define SOC_MMIO_H

#include <stdint.h>

/* CPU / core_clk 频率。board_top.CORE_CLK_HZ 的默认值，也是 DDR IP 输出的 core_clk。 */
#define SOC_CPU_HZ              93750000u

/* ---- simple_mmio（基址 0x1000_0000）---- */
#define MMIO_BASE               0x10000000u
#define MMIO_SCRATCH            (*(volatile uint32_t *)(MMIO_BASE + 0x00u))
#define MMIO_ID                 (*(volatile uint32_t *)(MMIO_BASE + 0x04u))
#define MMIO_CYCLE              (*(volatile uint32_t *)(MMIO_BASE + 0x08u))
#define MMIO_STATUS             (*(volatile uint32_t *)(MMIO_BASE + 0x0Cu))
#define MMIO_TEST_STATUS        (*(volatile uint32_t *)(MMIO_BASE + 0x10u))

/* MMIO_ID 的固定值 'MMIO'，可用于自检外设是否存在 */
#define MMIO_ID_VALUE           0x4D4D494Fu

/* TEST_STATUS 取值：0=IDLE 1=RUN 2=PASS 3=FAIL（结果锁存至复位） */
#define TEST_IDLE               0u
#define TEST_RUN                1u
#define TEST_PASS               2u
#define TEST_FAIL               3u

/* ---- uart_mmio（基址 0x1000_1000，16 字节）----
 * TX_DATA 低 lane 写、RX_DATA 低 lane 读；STATUS/CONTROL 按字访问。
 * 写 TX_DATA 必须在 TX_READY 为 1 时进行：忙时写会被丢弃并返回总线错误，
 * 而总线错误会变成 store access fault 异常，所以下面 uart_putc() 先轮询。 */
#define UART_BASE               0x10001000u
#define UART_TX_DATA            (*(volatile uint8_t  *)(UART_BASE + 0x00u))
#define UART_RX_DATA            (*(volatile uint8_t  *)(UART_BASE + 0x04u))
#define UART_STATUS             (*(volatile uint32_t *)(UART_BASE + 0x08u))
#define UART_CONTROL            (*(volatile uint32_t *)(UART_BASE + 0x0Cu))

#define UART_ST_TX_READY        (1u << 0)   /* bit0 */
#define UART_ST_TX_BUSY         (1u << 1)   /* bit1 */
#define UART_ST_RX_NOT_EMPTY    (1u << 2)   /* bit2 */
#define UART_ST_RX_FULL         (1u << 3)   /* bit3 */
#define UART_ST_FRAME_ERROR     (1u << 4)   /* bit4 sticky */
#define UART_ST_RX_OVERFLOW     (1u << 5)   /* bit5 sticky */
#define UART_ST_RX_IRQ_ENABLE   (1u << 6)   /* bit6 */
#define UART_ST_RX_IRQ_PENDING  (1u << 7)   /* bit7 */

/* CONTROL 命令位（需要写 lane1，即 +0xD 的移位数据或 SW） */
#define UART_CTL_CLEAR_FRAME    (1u << 0)   /* W1C */
#define UART_CTL_CLEAR_OVERFLOW (1u << 1)   /* W1C */
#define UART_CTL_IRQ_ENABLE     (1u << 8)
#define UART_CTL_IRQ_DISABLE    (1u << 9)   /* 同时写 1 时禁用优先 */

/* ---- DDR（板级窗口，仅作记录；本 port 的片上模式不使用）---- */
#define DDR_BASE                0x40000000u

#endif /* SOC_MMIO_H */
