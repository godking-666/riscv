//======================================================================
// cam_model.v -- OV5640 DVP 输出模型（仅仿真用）
//
// 产生与真实 DVP 同形的时序：pclk / vsync / href / data[7:0]
//   * 帧起始：vsync 拉高 VSYNC_W 拍
//   * 行内：href 高电平期间 data 为有效字节
//   * 画面内容：哑光背景 200 + 一个矩形物品（obj_* 决定位置尺寸，obj_val 决定亮度）
//
// BYTES_PER_PIX 与 ov5640_capture 的对应关系必须一致：
//   1 = 每字节一个像素，直接输出 8 位灰度
//   2 = RGB565，每个像素输出两个字节。按下面方式编码，使接收端用
//       pix = {byte0[2:0], byte1[7:5], 2'b00} 取绿通道后，
//       得到的灰度等于原灰度的低两位清零（对 4 的倍数完全无损）。
//       byte0 = {g[7:3], g[7:5]}    byte1 = {g[4:2], g[7:3]}
//
// TB 通过层次赋值改 obj_x/obj_y/obj_w/obj_h/obj_val/obj_en 来切换场景。
//======================================================================
`timescale 1ns / 1ps

module cam_model #(
    parameter H_ACT         = 320,
    parameter V_ACT         = 240,
    parameter H_BLANK       = 32,     // 以像素计
    parameter V_BLANK       = 8,
    parameter VSYNC_W       = 4,
    parameter BYTES_PER_PIX = 2
)(
    input  wire       pclk,
    input  wire       rstn,
    output reg        vsync,
    output reg        href,
    output reg [7:0]  data
);
    localparam H_TOTAL = H_BLANK * BYTES_PER_PIX + H_ACT * BYTES_PER_PIX;
    localparam V_TOTAL = V_BLANK + V_ACT;

    // ---- 由 TB 层次赋值 ----
    reg [15:0] obj_x, obj_y, obj_w, obj_h;
    reg [ 7:0] obj_val;
    reg        obj_en;

    reg [15:0] hc, vc;

    wire        active_line = (vc >= V_BLANK);
    wire        active_pix  = active_line && (hc >= (H_BLANK * BYTES_PER_PIX));
    wire [15:0] hoff = hc - (H_BLANK * BYTES_PER_PIX);
    wire [15:0] px   = (BYTES_PER_PIX == 2) ? {1'b0, hoff[15:1]} : hoff;
    wire [15:0] py   = vc - V_BLANK;

    wire in_obj = obj_en &&
                  (px >= obj_x) && (px < (obj_x + obj_w)) &&
                  (py >= obj_y) && (py < (obj_y + obj_h));

    wire [7:0] g = in_obj ? obj_val : 8'd200;   // 200 = 哑光背景亮度

    wire [7:0] out_byte = (BYTES_PER_PIX == 2)
                        ? (hoff[0] ? {g[4:2], g[7:3]} : {g[7:3], g[7:5]})
                        : g;

    always @(posedge pclk) begin
        if (!rstn) begin
            hc <= 16'd0;
            vc <= 16'd0;
        end
        else if (hc == (H_TOTAL - 1)) begin
            hc <= 16'd0;
            vc <= (vc == (V_TOTAL - 1)) ? 16'd0 : (vc + 16'd1);
        end
        else begin
            hc <= hc + 16'd1;
        end
    end

    always @(posedge pclk) begin
        if (!rstn) begin
            vsync <= 1'b0;
            href  <= 1'b0;
            data  <= 8'd0;
        end
        else begin
            vsync <= (vc < VSYNC_W);
            href  <= active_pix;
            data  <= out_byte;
        end
    end
endmodule