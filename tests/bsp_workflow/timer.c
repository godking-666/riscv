#include "bsp.h"
uint32_t timer_cycles(void) {return *(volatile uint32_t *)0x10000008u;}
void timer_delay_us(uint32_t us) {
    while(us) {
        uint32_t part=us>1000000u?1000000u:us;
        /* 每毫秒的周期数由 BSP_CLOCK_HZ 推导（旧代码硬编码 93750 = 93.75MHz/1e3）*/
        uint32_t per_ms=BSP_CLOCK_HZ/1000u;
        uint32_t ticks=(part/1000u)*per_ms+((part%1000u)*per_ms+999u)/1000u;
        uint32_t start=timer_cycles();
        while((uint32_t)(timer_cycles()-start)<ticks) {}
        us-=part;
    }
}
