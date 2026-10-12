/*===========================================================================
 * vision_drv.c -- 视觉子系统裸机驱动实现
 *=========================================================================*/
#include "vision_drv.h"

unsigned int vision_probe(void)
{
    return VISION_REG(VISION_OFF_ID);
}

void vision_init(unsigned int roi_x, unsigned int roi_y,
                 unsigned int roi_w, unsigned int roi_h,
                 unsigned int thresh, unsigned int pol,
                 unsigned int min_pix, unsigned int area_c_max)
{
    unsigned int t;

    /* 先关使能再改配置，避免配置改到一半被采到 */
    vision_enable(0);

    VISION_REG(VISION_OFF_ROI_X)      = roi_x;
    VISION_REG(VISION_OFF_ROI_Y)      = roi_y;
    VISION_REG(VISION_OFF_ROI_W)      = roi_w;
    VISION_REG(VISION_OFF_ROI_H)      = roi_h;
    VISION_REG(VISION_OFF_MIN_PIX)    = min_pix;
    VISION_REG(VISION_OFF_AREA_C_MAX) = area_c_max;

    t = (thresh & VISION_THRESH_MASK);
    if (pol) t |= VISION_THRESH_POL;
    VISION_REG(VISION_OFF_THRESH) = t;

    /* 把 ROI/阈值一次性推给 cam 时钟域（CFG_COMMIT 自清写） */
    VISION_REG(VISION_OFF_CTRL) = VISION_CTRL_CFG_COMMIT;

    vision_soft_reset();
}

void vision_enable(int en)
{
    VISION_REG(VISION_OFF_CTRL) = en ? VISION_CTRL_EN : 0u;
}

void vision_soft_reset(void)
{
    VISION_REG(VISION_OFF_CTRL) = VISION_CTRL_SOFT_RST;
}

unsigned int vision_status(void)
{
    return VISION_REG(VISION_OFF_STATUS);
}

int vision_wait_camera(unsigned int timeout_loops)
{
    unsigned int i;
    for (i = 0; i < timeout_loops; i++) {
        if (VISION_REG(VISION_OFF_STATUS) & VISION_ST_CAM_CFG_DONE)
            return 0;
    }
    return -1;
}

void vision_cam_restart(void)
{
    /* CTRL 是整寄存器写：必须把 EN 一起带上，否则会把使能清掉 */
    VISION_REG(VISION_OFF_CTRL) = VISION_CTRL_EN | VISION_CTRL_CAM_RESTART;
}

int vision_wait_done(unsigned int timeout_loops)
{
    unsigned int i;
    for (i = 0; i < timeout_loops; i++) {
        if (VISION_REG(VISION_OFF_STATUS) & VISION_ST_DONE)
            return 0;
    }
    return -1;
}

void vision_clear_done(void)
{
    VISION_REG(VISION_OFF_IRQ_CLR) = 1u;
}

void vision_read(vision_result_t *r)
{
    r->cls       = VISION_REG(VISION_OFF_CLASS);
    r->score     = VISION_REG(VISION_OFF_SCORE);
    r->x0        = VISION_REG(VISION_OFF_BOX_X0);
    r->y0        = VISION_REG(VISION_OFF_BOX_Y0);
    r->x1        = VISION_REG(VISION_OFF_BOX_X1);
    r->y1        = VISION_REG(VISION_OFF_BOX_Y1);
    r->obj_w     = VISION_REG(VISION_OFF_OBJ_W);
    r->obj_h     = VISION_REG(VISION_OFF_OBJ_H);
    r->fg_cnt    = VISION_REG(VISION_OFF_FG_CNT);
    r->frame_cyc = VISION_REG(VISION_OFF_FRAME_CYC);
    r->frame_no  = VISION_REG(VISION_OFF_FRAME_CNT);
    r->item_cnt  = VISION_REG(VISION_OFF_ITEM_CNT);
}

int vision_capture(vision_result_t *r, unsigned int timeout_loops)
{
    vision_clear_done();
    if (vision_wait_done(timeout_loops) != 0)
        return -1;
    vision_read(r);
    return 0;
}

const char *vision_class_name(unsigned int cls)
{
    switch (cls) {
    case VISION_CLASS_A: return "A";
    case VISION_CLASS_B: return "B";
    case VISION_CLASS_C: return "C";
    default:             return "--";
    }
}

unsigned int vision_latency_us(unsigned int frame_cyc, unsigned int cam_clk_hz)
{
    /* 帧周期(周期数) / cam 频率(Hz) * 1e6 -> 微秒。
     * 用 64 位中间量避免溢出。 */
    unsigned long long us;
    if (cam_clk_hz == 0u) return 0u;
    us = (unsigned long long)frame_cyc * 1000000ull / (unsigned long long)cam_clk_hz;
    return (unsigned int)us;
}