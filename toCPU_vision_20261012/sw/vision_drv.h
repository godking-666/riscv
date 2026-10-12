/*===========================================================================
 * vision_drv.h -- 视觉子系统裸机驱动接口
 *
 * 面向场景：「物品放入检测区 -> 取回类别/外接框/置信度/计数」。
 * 不依赖任何 OS，纯 MMIO 轮询；中断版本见 vision_drv_irq_*（待接 CPU 中断后启用）。
 *=========================================================================*/
#ifndef VISION_DRV_H
#define VISION_DRV_H

#include "vision_regs.h"

typedef struct {
    unsigned int cls;        /* 0=A 1=B 2=C 255=无物品                */
    unsigned int score;      /* 置信度，千分比                        */
    unsigned int x0, y0;     /* 外接框左上                            */
    unsigned int x1, y1;     /* 外接框右下                            */
    unsigned int obj_w, obj_h;
    unsigned int fg_cnt;     /* 前景像素数                            */
    unsigned int frame_cyc;  /* 帧周期（cam 时钟周期）                 */
    unsigned int frame_no;   /* 帧号                                  */
    unsigned int item_cnt;   /* 累计检出物品数                        */
} vision_result_t;

/* 器件探测：返回 ID 寄存器。等于 VISION_MAGIC 说明器件在位。 */
unsigned int vision_probe(void);

/* 配置 + 使能。调用后视觉子系统开始出结果。
 *   thresh : 前景阈值；pol=0 表示比阈值暗的像素算前景
 *   min_pix: 小于该前景像素数视为「无物品」
 *   area_c_max: 前景像素数小于该值判为 C 类
 */
void vision_init(unsigned int roi_x, unsigned int roi_y,
                 unsigned int roi_w, unsigned int roi_h,
                 unsigned int thresh, unsigned int pol,
                 unsigned int min_pix, unsigned int area_c_max);

void vision_enable(int en);
void vision_soft_reset(void);

/* 读 STATUS 原始值（相机状态位都在里面） */
unsigned int vision_status(void);

/* 等相机 SCCB 配置完成。返回 0=已完成，-1=超时。 */
int  vision_wait_camera(unsigned int timeout_loops);

/* 相机掉线自恢复：重跑上电时序 + SCCB 配置表，并保持使能。
 * 注意 CTRL 是整寄存器写，所以内部写的是 EN | CAM_RESTART。 */
void vision_cam_restart(void);

/* 轮询等待新结果。返回 0=成功，-1=超时。 */
int  vision_wait_done(unsigned int timeout_loops);

/* 清 DONE（为下一帧做准备） */
void vision_clear_done(void);

/* 一次性读回全部结果 */
void vision_read(vision_result_t *r);

/* 读单帧：内部完成「清 DONE -> 等 DONE -> 读结果」。
 * 返回 0=成功，-1=超时。 */
int  vision_capture(vision_result_t *r, unsigned int timeout_loops);

const char *vision_class_name(unsigned int cls);

/* 帧周期换算成毫秒的千分之一（微秒）。cam_clk_hz 传摄像头 PCLK 频率。 */
unsigned int vision_latency_us(unsigned int frame_cyc, unsigned int cam_clk_hz);

#endif /* VISION_DRV_H */