//======================================================================
// roi_stats.v -- 帧内背景/阈值分割统计（cam_pclk 域）
//
// 对「物品检测区」(ROI) 内的像素做前景判定，累计：
//   * 前景像素数 fg_cnt
//   * 前景外接矩形 (box_x0, box_y0) - (box_x1, box_y1)
//   * 本帧耗时（cam 时钟周期数）
//
// 前景判定：pol=0 → 像素比阈值暗算前景；pol=1 → 比阈值亮算前景。
// 哑光背景板 + 固定光照下，用固定阈值即可；背景差分等更稳的算法留待后续升级。
//
// 结果提交：在冻结结果后于帧起始（pix_sof）把累加器推给结果寄存器并翻转
// res_toggle。跨到 CPU 时钟域由 vision_regs 用「翻转握手」安全接收。
// 复位后第一个 sof 不提交（那时累加器还是空的）。
//======================================================================
`timescale 1ns / 1ps

module roi_stats (
    input  wire        pclk,
    input  wire        rstn,

    input  wire        pix_de,
    input  wire [7:0]  pix,
    input  wire [15:0] pix_x,
    input  wire [15:0] pix_y,
    input  wire        pix_sof,

    // 配置（已由上层同步到 pclk 域）
    input  wire [15:0] roi_x,
    input  wire [15:0] roi_y,
    input  wire [15:0] roi_w,
    input  wire [15:0] roi_h,
    input  wire [7:0]  thresh,
    input  wire        pol,

    // 结果（pclk 域，由 vision_regs 跨域取走）
    output reg  [31:0] res_frame_cnt,
    output reg  [31:0] res_fg_cnt,
    output reg  [15:0] res_box_x0,
    output reg  [15:0] res_box_y0,
    output reg  [15:0] res_box_x1,
    output reg  [15:0] res_box_y1,
    output reg  [31:0] res_cycles,
    output reg         res_toggle
);
    reg [31:0] frame_cnt;
    reg [31:0] cyc;
    reg [31:0] fg;
    reg [15:0] bx0, by0, bx1, by1;
    reg        have;

    // ROI 右/下边界（32 位比较，避免 16 位相加溢出）
    wire [31:0] roi_x_end = {16'd0, roi_x} + {16'd0, roi_w};
    wire [31:0] roi_y_end = {16'd0, roi_y} + {16'd0, roi_h};

    wire in_roi = ({16'd0, pix_x} >= {16'd0, roi_x}) &&
                  ({16'd0, pix_x} <  roi_x_end)     &&
                  ({16'd0, pix_y} >= {16'd0, roi_y}) &&
                  ({16'd0, pix_y} <  roi_y_end);

    wire hit = pol ? (pix > thresh) : (pix < thresh);

    always @(posedge pclk) begin
        if (!rstn) begin
            frame_cnt     <= 32'd0;
            cyc           <= 32'd0;
            fg            <= 32'd0;
            bx0           <= 16'hFFFF;
            by0           <= 16'hFFFF;
            bx1           <= 16'h0000;
            by1           <= 16'h0000;
            have          <= 1'b0;
            res_frame_cnt <= 32'd0;
            res_fg_cnt    <= 32'd0;
            res_box_x0    <= 16'd0;
            res_box_y0    <= 16'd0;
            res_box_x1    <= 16'd0;
            res_box_y1    <= 16'd0;
            res_cycles    <= 32'd0;
            res_toggle    <= 1'b0;
        end
        else begin
            cyc <= cyc + 32'd1;

            if (pix_sof) begin
                // 提交上一帧结果（第一帧跳过）
                if (frame_cnt != 32'd0) begin
                    res_frame_cnt <= frame_cnt;
                    res_fg_cnt    <= fg;
                    res_box_x0    <= bx0;
                    res_box_y0    <= by0;
                    res_box_x1    <= bx1;
                    res_box_y1    <= by1;
                    res_cycles    <= cyc;
                    res_toggle    <= ~res_toggle;
                end
                // 开始新一帧
                frame_cnt <= frame_cnt + 32'd1;
                cyc       <= 32'd0;
                fg        <= 32'd0;
                have      <= 1'b0;
                bx0       <= 16'hFFFF;
                by0       <= 16'hFFFF;
                bx1       <= 16'h0000;
                by1       <= 16'h0000;
            end
            else if (pix_de && in_roi && hit) begin
                fg <= fg + 32'd1;
                if (!have) begin
                    have <= 1'b1;
                    bx0  <= pix_x;
                    by0  <= pix_y;
                    bx1  <= pix_x;
                    by1  <= pix_y;
                end
                else begin
                    if (pix_x < bx0) bx0 <= pix_x;
                    if (pix_x > bx1) bx1 <= pix_x;
                    if (pix_y < by0) by0 <= pix_y;
                    if (pix_y > by1) by1 <= pix_y;
                end
            end
        end
    end
endmodule