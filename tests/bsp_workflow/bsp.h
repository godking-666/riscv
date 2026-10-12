#ifndef BSP_H
#define BSP_H
#include <stdint.h>
#include <stdarg.h>
/* 新板(PG2L200H-6IFBB676) 系统时钟 27MHz（D18，手册 1.3.2.5）；
 * 旧板 RK3568_MES2L100H 是 93.75MHz。可用 -DBSP_CLOCK_HZ=... 覆盖。 */
#ifndef BSP_CLOCK_HZ
#define BSP_CLOCK_HZ 27000000u
#endif
#define BSP_DATA_MAGIC 0x42da7a11u
extern volatile uint32_t bsp_data_magic,bsp_ecalls,bsp_irqs;
int putchar(int c);
int puts(const char *s);
int printf(const char *fmt,...);
int uart_getchar(void);
void uart_irq_enable(void);
void uart_irq_disable(void);
void uart_irq_service(void);
uint32_t timer_cycles(void);
void timer_delay_us(uint32_t us);
uint32_t crc32_update(uint32_t crc,const void *data,uint32_t size);
uint32_t crc32(const void *data,uint32_t size);
uint32_t trap_dispatch(uint32_t cause,uint32_t pc,uint32_t value,uint32_t *regs);
int bsp_trap_probe(void);
int bsp_check(void);
#endif
