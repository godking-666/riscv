//======================================================================
// vision_top.v -- 视觉子系统顶层（「物品识别」应用场景的全部非 CPU 逻辑）
//
//   OV5640 ──DVP──► ov5640_capture ──► roi_stats ──(翻转握手)──┐
//      ▲                                                        │
//      │ SCCB 配置                                              │
//   ov5640_cam_ctrl ──► ov5640_sccb                             │
//                                                               │
//   CPU ◄──MMIO──► vision_regs ──(cfg 握手)──► cam 域配置锁存    │
//                      │                                        │
//                      └──► vision_classifier ◄─────────────────┘
//                               │
//                               └──► LED A/B/C
//
// 两个时钟域：
//   * cam_pclk 域：DVP 接收 + 帧内统计（跟摄像头像素时钟走）
//   * clk      域：MMIO 寄存器 + 相机配置 + 分类器 + 指示灯（跟 CPU 主时钟走）
// 三处跨域都是「翻转握手 + 多拍稳定」的常规做法，不引入额外时钟域。
//
// 参数默认值是给真实板卡用的；仿真里可以调小上电等待、调高 SCL 频率来加速。
//======================================================================
`timescale 1ns / 1ps

module vision_top #(
    // clk 频率：按 CPU 组 core_clk = 93.75 MHz（SoC 结构图 2026-10-05），SCCB 分频用。
    // ★ 待核对：若板上给视觉模块分配的是别的时钟，集成时改这一个值即可。
    parameter CAM_CLK_HZ          = 93750000,
    parameter CAM_SCL_HZ          = 100000,     // SCCB 时钟
    parameter CAM_PWDN_SETTLE_MS  = 10,         // 上电等待
    parameter CAM_RESET_SETTLE_MS = 20,         // 复位释放后等待
    parameter BYTES_PER_PIX       = 2           // 2 = RGB565
)(
    input  wire        clk,
    input  wire        rstn,

    // ---- 摄像头 DVP ----
    input  wire        cam_pclk,
    input  wire        cam_vsync,
    input  wire        cam_href,
    input  wire [7:0]  cam_data,

    // ---- 摄像头控制（SCCB 开漏 + 电源/复位，外接上拉）----
    inout  wire        cam_sda,
    output wire        cam_scl,
    output wire        cam_pwdn,
    output wire        cam_reset_n,

    // ---- MMIO 从端（接 CPU 地址译码出来的片选）----
    input  wire        bus_sel,
    input  wire        bus_we,
    input  wire [31:0] bus_addr,
    input  wire [31:0] bus_wdata,
    input  wire [3:0]  bus_be,
    output wire [31:0] bus_rdata,

    // ---- 中断 ----
    output wire        irq,

    // ---- A/B/C 指示灯 ----
    output wire        led_a,
    output wire        led_b,
    output wire        led_c
);

    //==================================================================
    // cam 域复位同步（异步复位、同步释放）
    //==================================================================
    reg [3:0] cam_rstn_sync;
    always @(posedge cam_pclk or negedge rstn) begin
        if (!rstn) cam_rstn_sync <= 4'd0;
        else       cam_rstn_sync <= {cam_rstn_sync[2:0], 1'b1};
    end
    wire cam_rstn = cam_rstn_sync[3];

    //==================================================================
    // SCCB 开漏总线：本模块只拉低，释放时交给外部上拉
    //==================================================================
    wire sccb_sda_out, sccb_sda_oe;
    wire sccb_sda_lo = sccb_sda_oe & ~sccb_sda_out;
    assign cam_sda = sccb_sda_lo ? 1'b0 : 1'bz;
    wire cam_sda_in = (cam_sda === 1'b0) ? 1'b0 : 1'b1;

    wire cam_cfg_busy, cam_cfg_done, cam_cfg_err;
    wire cam_restart;

    ov5640_cam_ctrl #(
        .CLK_HZ          (CAM_CLK_HZ),
        .SCL_HZ          (CAM_SCL_HZ),
        .PWDN_SETTLE_MS  (CAM_PWDN_SETTLE_MS),
        .RESET_SETTLE_MS (CAM_RESET_SETTLE_MS)
    ) u_cam_ctrl (
        .clk         (clk),
        .rstn        (rstn),
        .restart     (cam_restart),
        .cam_pwdn    (cam_pwdn),
        .cam_reset_n (cam_reset_n),
        .cam_scl     (cam_scl),
        .cam_sda_out (sccb_sda_out),
        .cam_sda_oe  (sccb_sda_oe),
        .cam_sda_in  (cam_sda_in),
        .cfg_busy    (cam_cfg_busy),
        .cfg_done    (cam_cfg_done),
        .cfg_err     (cam_cfg_err)
    );

    //==================================================================
    // vision_regs：MMIO + 配置 + 结果锁存
    //==================================================================
    wire [15:0] cfg_roi_x, cfg_roi_y, cfg_roi_w, cfg_roi_h;
    wire [7:0]  cfg_thresh;
    wire        cfg_pol, cfg_toggle, enable;

    wire [31:0] roi_w, roi_h, min_pix, area_c_max;

    wire [31:0] res_frame_cnt;
    wire [31:0] res_fg_cnt;
    wire [15:0] res_box_x0, res_box_y0, res_box_x1, res_box_y1;
    wire [31:0] res_cycles;
    wire        res_toggle;

    wire [31:0] lat_frame_cnt, lat_fg_cnt;
    wire [31:0] lat_box_x0, lat_box_y0, lat_box_x1, lat_box_y1, lat_cycles;
    wire        frame_new;

    wire [31:0] cls, score, obj_w, obj_h;
    wire        cls_valid, cls_done;

    vision_regs u_regs (
        .clk          (clk),
        .rstn         (rstn),
        .bus_sel      (bus_sel),
        .bus_we       (bus_we),
        .bus_addr     (bus_addr),
        .bus_wdata    (bus_wdata),
        .bus_be       (bus_be),
        .bus_rdata    (bus_rdata),
        .irq          (irq),
        .cam_cfg_done (cam_cfg_done),
        .cam_cfg_err  (cam_cfg_err),
        .cam_restart  (cam_restart),
        .cfg_roi_x    (cfg_roi_x),
        .cfg_roi_y    (cfg_roi_y),
        .cfg_roi_w    (cfg_roi_w),
        .cfg_roi_h    (cfg_roi_h),
        .cfg_thresh   (cfg_thresh),
        .cfg_pol      (cfg_pol),
        .cfg_toggle   (cfg_toggle),
        .enable       (enable),
        .roi_w        (roi_w),
        .roi_h        (roi_h),
        .min_pix      (min_pix),
        .area_c_max   (area_c_max),
        .res_frame_cnt(res_frame_cnt),
        .res_fg_cnt   (res_fg_cnt),
        .res_box_x0   (res_box_x0),
        .res_box_y0   (res_box_y0),
        .res_box_x1   (res_box_x1),
        .res_box_y1   (res_box_y1),
        .res_cycles   (res_cycles),
        .res_toggle   (res_toggle),
        .lat_frame_cnt(lat_frame_cnt),
        .lat_fg_cnt   (lat_fg_cnt),
        .lat_box_x0   (lat_box_x0),
        .lat_box_y0   (lat_box_y0),
        .lat_box_x1   (lat_box_x1),
        .lat_box_y1   (lat_box_y1),
        .lat_cycles   (lat_cycles),
        .frame_new    (frame_new),
        .cls_i        (cls),
        .score_i      (score),
        .obj_w_i      (obj_w),
        .obj_h_i      (obj_h),
        .cls_valid_i  (cls_valid),
        .cls_done_i   (cls_done)
    );

    //==================================================================
    // 配置跨域：clk 域 cfg_toggle 翻转 → cam 域取边沿 → 一次性锁存全部配置
    //==================================================================
    reg [1:0] ct_sync;
    always @(posedge cam_pclk or negedge rstn) begin
        if (!rstn) ct_sync <= 2'b00;
        else       ct_sync <= {ct_sync[0], cfg_toggle};
    end
    wire cfg_edge = ct_sync[0] ^ ct_sync[1];

    reg [15:0] roi_x_r, roi_y_r, roi_w_r, roi_h_r;
    reg [7:0]  thresh_r;
    reg        pol_r;

    always @(posedge cam_pclk or negedge rstn) begin
        if (!rstn) begin
            roi_x_r  <= 16'd0;
            roi_y_r  <= 16'd0;
            roi_w_r  <= 16'd320;
            roi_h_r  <= 16'd240;
            thresh_r <= 8'd128;
            pol_r    <= 1'b0;
        end
        else if (cfg_edge) begin
            roi_x_r  <= cfg_roi_x;
            roi_y_r  <= cfg_roi_y;
            roi_w_r  <= cfg_roi_w;
            roi_h_r  <= cfg_roi_h;
            thresh_r <= cfg_thresh;
            pol_r    <= cfg_pol;
        end
    end

    //==================================================================
    // cam 域：DVP 接收 + 帧内统计
    //==================================================================
    wire        pix_de;
    wire [7:0]  pix;
    wire [15:0] pix_x, pix_y;
    wire        pix_sof;

    ov5640_capture #(.BYTES_PER_PIX(BYTES_PER_PIX)) u_cap (
        .pclk    (cam_pclk),
        .rstn    (cam_rstn),
        .vsync   (cam_vsync),
        .href    (cam_href),
        .data    (cam_data),
        .pix_de  (pix_de),
        .pix     (pix),
        .pix_x   (pix_x),
        .pix_y   (pix_y),
        .pix_sof (pix_sof)
    );

    roi_stats u_stats (
        .pclk          (cam_pclk),
        .rstn          (cam_rstn),
        .pix_de        (pix_de),
        .pix           (pix),
        .pix_x         (pix_x),
        .pix_y         (pix_y),
        .pix_sof       (pix_sof),
        .roi_x         (roi_x_r),
        .roi_y         (roi_y_r),
        .roi_w         (roi_w_r),
        .roi_h         (roi_h_r),
        .thresh        (thresh_r),
        .pol           (pol_r),
        .res_frame_cnt (res_frame_cnt),
        .res_fg_cnt    (res_fg_cnt),
        .res_box_x0    (res_box_x0),
        .res_box_y0    (res_box_y0),
        .res_box_x1    (res_box_x1),
        .res_box_y1    (res_box_y1),
        .res_cycles    (res_cycles),
        .res_toggle    (res_toggle)
    );

    //==================================================================
    // clk 域：分类（AI 加速器的插入位置）
    //==================================================================
    vision_classifier u_cls (
        .clk        (clk),
        .rstn       (rstn),
        .frame_new  (frame_new),
        .fg_cnt     (lat_fg_cnt),
        .box_x0     (lat_box_x0),
        .box_y0     (lat_box_y0),
        .box_x1     (lat_box_x1),
        .box_y1     (lat_box_y1),
        .roi_w      (roi_w),
        .roi_h      (roi_h),
        .min_pix    (min_pix),
        .area_c_max (area_c_max),
        .cls        (cls),
        .score      (score),
        .obj_w      (obj_w),
        .obj_h      (obj_h),
        .valid      (cls_valid),
        .done       (cls_done)
    );

    //==================================================================
    // A/B/C 指示灯
    //==================================================================
    assign led_a = cls_valid & (cls == 32'd0);
    assign led_b = cls_valid & (cls == 32'd1);
    assign led_c = cls_valid & (cls == 32'd2);

endmodule
