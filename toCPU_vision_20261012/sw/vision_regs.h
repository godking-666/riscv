/*===========================================================================
 * vision_regs.h -- 视觉子系统寄存器定义
 *
 * 本文件必须与 rtl/vision_regs.v 保持同步。改一处必须改两处。
 * RTL 与驱动共用同一份地址/位域定义，避免两边各自硬编码。
 *
 * 【给 CPU 组的两条硬要求】
 *   1) VISION_BASE 起的 4KB 必须配置为「不可缓存」。
 *      否则读 STATUS 会读到 D-Cache 里的旧值、写 CTRL 可能不下发。
 *   2) 该段写在 CPU 侧必须有序（直通写，或在 CTRL 写之前加写屏障）。
 *=========================================================================*/
#ifndef VISION_REGS_H
#define VISION_REGS_H

/* ---- 基址：CPU 侧地址译码必须与此一致 ---- */
#define VISION_BASE          0x80000000u
#define VISION_SIZE          0x00001000u

/* ---- 偏移 ---- */
#define VISION_OFF_ID          0x000u   /* RO  魔数 0x56495331 ("VIS1")       */
#define VISION_OFF_VERSION     0x004u   /* RO  0x00010000                     */
#define VISION_OFF_CTRL        0x008u   /* RW  控制                           */
#define VISION_OFF_STATUS      0x00Cu   /* RO  状态                           */
#define VISION_OFF_IRQ_CLR     0x010u   /* WO  写任意值清 DONE                */
#define VISION_OFF_FRAME_CNT   0x014u   /* RO  已接收帧数                     */
#define VISION_OFF_ITEM_CNT    0x018u   /* RO  检出物品数（出现沿自增）        */
#define VISION_OFF_FRAME_CYC   0x01Cu   /* RO  帧周期，单位 cam 时钟周期       */
#define VISION_OFF_ROI_X       0x020u   /* RW  物品检测区左上角 X             */
#define VISION_OFF_ROI_Y       0x024u   /* RW  物品检测区左上角 Y             */
#define VISION_OFF_ROI_W       0x028u   /* RW  物品检测区宽（复位默认 320）    */
#define VISION_OFF_ROI_H       0x02Cu   /* RW  物品检测区高（复位默认 240）    */
#define VISION_OFF_THRESH      0x030u   /* RW  [7:0] 阈值 [8] 极性            */
#define VISION_OFF_MIN_PIX     0x034u   /* RW  判为有物品的最小前景像素数      */
#define VISION_OFF_AREA_C_MAX  0x038u   /* RW  小于此面积判为 C 类            */
#define VISION_OFF_CLASS       0x03Cu   /* RO  0=A 1=B 2=C 255=无物品         */
#define VISION_OFF_SCORE       0x040u   /* RO  置信度，千分比                 */
#define VISION_OFF_BOX_X0      0x044u   /* RO  外接框左                       */
#define VISION_OFF_BOX_Y0      0x048u   /* RO  外接框上                       */
#define VISION_OFF_BOX_X1      0x04Cu   /* RO  外接框右                       */
#define VISION_OFF_BOX_Y1      0x050u   /* RO  外接框下                       */
#define VISION_OFF_FG_CNT      0x054u   /* RO  前景像素数                     */
#define VISION_OFF_OBJ_W       0x058u   /* RO  目标宽                         */
#define VISION_OFF_OBJ_H       0x05Cu   /* RO  目标高                         */

/* ---- 地址（基址 + 偏移）---- */
#define VISION_REG(o)   (*(volatile unsigned int *)(VISION_BASE + (o)))

/* ---- CTRL 位域 ----
 * ★ CTRL 是「整寄存器写」：写 CTRL 必须把你想要的位全给出来。
 *   例如只想重启相机，要写 EN | CAM_RESTART，不能只写 CAM_RESTART，
 *   否则 b0=0 会把使能一起清掉。 */
#define VISION_CTRL_EN          (1u << 0)   /* 使能：开始接收并锁存结果         */
#define VISION_CTRL_SOFT_RST    (1u << 1)   /* 自清：清计数与 DONE/ERR          */
#define VISION_CTRL_IRQ_EN      (1u << 2)   /* 允许 DONE 拉高中断线             */
#define VISION_CTRL_CFG_COMMIT  (1u << 3)   /* 自清：把 ROI/阈值一次性推给 cam 域 */
#define VISION_CTRL_CAM_RESTART (1u << 4)   /* 自清：重跑相机上电时序 + SCCB 配置 */

/* ---- STATUS 位域 ---- */
#define VISION_ST_EN            (1u << 0)
#define VISION_ST_DONE          (1u << 1)   /* 有新结果；写 IRQ_CLR 清除        */
#define VISION_ST_ERR           (1u << 2)   /* ROI 面积为 0 等配置错误          */
#define VISION_ST_CAM_OK        (1u << 3)   /* 至少收到过一帧（粘滞）           */
#define VISION_ST_CAM_CFG_DONE  (1u << 4)   /* 相机 SCCB 配置表已下发完         */
#define VISION_ST_CAM_CFG_ERR   (1u << 5)   /* SCCB 过程中出现过 NACK           */

/* ---- THRESH 位域 ---- */
#define VISION_THRESH_MASK      0xFFu
#define VISION_THRESH_POL       (1u << 8)   /* 0=比阈值暗算前景 1=亮算前景      */

/* ---- 类别编码 ---- */
#define VISION_CLASS_A          0u
#define VISION_CLASS_B          1u
#define VISION_CLASS_C          2u
#define VISION_CLASS_NONE       255u

#define VISION_MAGIC            0x56495331u

#endif /* VISION_REGS_H */