/*===========================================================================
 * main.c -- 物品识别应用主程序（跑在 RISC-V CPU 上）
 *
 * 职责：
 *   1) 初始化视觉子系统（ROI / 阈值 / 门限）
 *   2) 循环取回每一帧的识别结果
 *   3) 把「类别 / 框 / 延迟 / 计数」按一行紧凑协议发给 RK3568 显示终端
 *      （A/B/C 指示灯由 RTL 直接驱动，软件不用管）
 *
 * 依赖 CPU 组提供的 BSP：uart_putc()。其余全部用自带的小格式化函数完成，
 * 不依赖 printf，避免为了几行输出就拉进整个 newlib stdio。
 *=========================================================================*/
#include "vision_regs.h"
#include "vision_drv.h"

/* ---- 由 CPU 组 BSP 提供 ---- */
extern void uart_putc(char c);

/* 摄像头 PCLK 频率：板卡上按实际配置填。OV5640 常用 24/48 MHz。 */
#define CAM_CLK_HZ        24000000u

#define WAIT_LOOPS        20000000u   /* 轮询超时（按 CPU 主频经验值） */

/*---- 极简输出 ----*/
static void put_u32(unsigned int v)
{
    char buf[11];
    int  i = 0;
    if (v == 0u) { uart_putc('0'); return; }
    while (v > 0u && i < 10) { buf[i++] = (char)('0' + (v % 10u)); v /= 10u; }
    while (i > 0) uart_putc(buf[--i]);
}

static void put_str(const char *s)
{
    while (*s) uart_putc(*s++);
}

/* 屏幕协议（RK3568 侧按逗号切分即可）：
 *   VISION,<帧号>,<类别>,<x0>,<y0>,<x1>,<y1>,<置信度>,<延迟us>,<计数>\n
 */
static void report(const vision_result_t *r)
{
    unsigned int lat_us = vision_latency_us(r->frame_cyc, CAM_CLK_HZ);

    put_str("VISION,");
    put_u32(r->frame_no);          uart_putc(',');
    put_str(vision_class_name(r->cls)); uart_putc(',');
    put_u32(r->x0);                uart_putc(',');
    put_u32(r->y0);                uart_putc(',');
    put_u32(r->x1);                uart_putc(',');
    put_u32(r->y1);                uart_putc(',');
    put_u32(r->score);             uart_putc(',');
    put_u32(lat_us);               uart_putc(',');
    put_u32(r->item_cnt);
    uart_putc('\n');
}

int main(void)
{
    vision_result_t r;
    unsigned int    id, to_cnt = 0u;

    put_str("\n[vision] boot\n");

    /* ---- 器件探测：能读到魔数才继续，否则早报错，别让后面所有读数都是幻觉 ---- */
    id = vision_probe();
    if (id != VISION_MAGIC) {
        put_str("[vision] ERR: 未找到视觉子系统, ID=0x");
        put_u32(id);
        put_str("  请检查地址译码与不可缓存属性\n");
        for (;;) { }
    }
    put_str("[vision] 视觉子系统在线\n");

    /* ---- 配置 ----
     * ROI 先按整帧来；标定好「物品检测区」的实际像素范围后再收紧。
     * THRESH 需要现场标定：哑光背景亮度与物品亮度之间取中值。 */
    vision_init(/*roi_x*/ 0, /*roi_y*/ 0,
                /*roi_w*/ 320, /*roi_h*/ 240,
                /*thresh*/ 128, /*pol*/ 0,
                /*min_pix*/ 64, /*area_c_max*/ 500);

    vision_enable(1);

    /* ---- 等相机 SCCB 配置表下发完 ----
     * 相机不在位时也不卡死，靠超时兜底继续往下走（结果会一直是「无物品」）。 */
    if (vision_wait_camera(WAIT_LOOPS) == 0)
        put_str("[vision] 相机配置完成\n");
    else
        put_str("[vision] 警告: 相机配置超时, 检查 XCLK/接线\n");

    if (vision_status() & VISION_ST_CAM_CFG_ERR)
        put_str("[vision] 警告: SCCB 出现过 NACK\n");

    /* ---- 主循环 ----
     * 功能优先：轮询取结果。中断方式等 CPU 侧中断控制器稳定后再换，
     * 换的时候只需要把 vision_capture 里的轮询换成等中断，协议不用动。 */
    for (;;) {
        if (vision_capture(&r, WAIT_LOOPS) != 0) {
            /* 连续几次等不到结果 -> 大概率是相机掉线/复位，重启相机自恢复 */
            if (++to_cnt >= 3u) {
                to_cnt = 0u;
                put_str("[vision] 连续超时, 重启相机\n");
                vision_cam_restart();
            }
            continue;
        }
        to_cnt = 0u;
        report(&r);
    }
}