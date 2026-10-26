#include "bsp.h"
volatile uint32_t bsp_data_magic=BSP_DATA_MAGIC;
volatile uint32_t bsp_ecalls,bsp_irqs;
uint32_t trap_dispatch(uint32_t cause,uint32_t pc,uint32_t value,uint32_t *regs) {
    (void)regs;
    if(cause==11u){++bsp_ecalls;return pc+4u;}
    if(cause==0x8000000bu){++bsp_irqs;uart_irq_service();return pc;}
    printf("TRAP_FAIL cause=%08X pc=%08X value=%08X\r\n",cause,pc,value);
#ifdef RETURN_TO_LOADER
    /* 崩溃后也回到 Loader，便于连续迭代（Loader 在 ROM 0x0） */
    __asm__ volatile ("lui t0,0\n\tjalr zero,0(t0)");
#else
    for(;;) {}
#endif
}
int bsp_check(void) {
    if(bsp_data_magic!=BSP_DATA_MAGIC||bsp_ecalls||bsp_irqs)return 0;
    if(!bsp_trap_probe()||bsp_ecalls!=1u)return 0;
    uint32_t start=timer_cycles();timer_delay_us(10u);
    return (uint32_t)(timer_cycles()-start)>=938u;
}
