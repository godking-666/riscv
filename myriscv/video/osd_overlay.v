`timescale 1ns/1ps
//=============================================================================
// osd_overlay.v —— 在 HDMI 画面上叠加识别结果（像素域，pclk）
//
// 位置：插在 hdmi_frame_out 的 RGB888 之后、rgb2tmds 之前。
// 数据：cls 来自 cnn_mmio 的 engine_class（core_clk 域），本模块内部做 2 级同步。
//
// 显示：左上角一个 64x64 的方块（8x8 字模放大 8 倍），
//       底色压暗到 1/2 让白字在亮背景上也看得清，
//       笔画用白色。
//
// 为什么这么设计：
//   * 不动 data_bus_interconnect（不新增 MMIO 地址），风险最低
//   * 字模只用 10 个数字，case 表综合成几百个 LUT，几乎不占资源
//   * 类别只在 core_clk 更新，跨到 pclk 后慢一帧显示，肉眼无感
//=============================================================================
module osd_overlay (
    input  wire        pclk,
    input  wire        rst_n,
    input  wire [23:0] rgb_in,
    input  wire        de,
    input  wire [11:0] x_act,
    input  wire [11:0] y_act,
    input  wire [3:0]  cls,        // 识别类别（异步，来自 core_clk）
    output wire [23:0] rgb_out
);
    // ---- 方块位置与大小：左上角，64x64 ----
    localparam integer BOX_X = 40;
    localparam integer BOX_Y = 40;
    localparam integer BOX_W = 64;   // 8 像素 x 放大 8 倍
    localparam integer BOX_H = 64;

    // ---- 类别跨时钟域（core_clk -> pclk）----
    (* async_reg = "true" *) reg [3:0] cls_s1, cls_s2;
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin cls_s1 <= 4'd0; cls_s2 <= 4'd0; end
        else        begin cls_s1 <= cls;  cls_s2 <= cls_s1; end
    end
    // 只显示 0..9，其它值当 0
    wire [3:0] d = (cls_s2 > 4'd9) ? 4'd0 : cls_s2;

    // ---- 8x8 字模 ----
    function [7:0] glyph_row;
        input [3:0] dig;
        input [2:0] row;
        reg   [6:0] key;
        begin
            key = {dig, row};
            case (key)
                7'h00: glyph_row = 8'h3C;
                7'h01: glyph_row = 8'h66;
                7'h02: glyph_row = 8'h6E;
                7'h03: glyph_row = 8'h76;
                7'h04: glyph_row = 8'h66;
                7'h05: glyph_row = 8'h66;
                7'h06: glyph_row = 8'h3C;
                7'h07: glyph_row = 8'h00;
                7'h08: glyph_row = 8'h18;
                7'h09: glyph_row = 8'h38;
                7'h0A: glyph_row = 8'h18;
                7'h0B: glyph_row = 8'h18;
                7'h0C: glyph_row = 8'h18;
                7'h0D: glyph_row = 8'h18;
                7'h0E: glyph_row = 8'h7E;
                7'h0F: glyph_row = 8'h00;
                7'h10: glyph_row = 8'h3C;
                7'h11: glyph_row = 8'h66;
                7'h12: glyph_row = 8'h06;
                7'h13: glyph_row = 8'h0C;
                7'h14: glyph_row = 8'h18;
                7'h15: glyph_row = 8'h30;
                7'h16: glyph_row = 8'h7E;
                7'h17: glyph_row = 8'h00;
                7'h18: glyph_row = 8'h3C;
                7'h19: glyph_row = 8'h66;
                7'h1A: glyph_row = 8'h06;
                7'h1B: glyph_row = 8'h1C;
                7'h1C: glyph_row = 8'h06;
                7'h1D: glyph_row = 8'h66;
                7'h1E: glyph_row = 8'h3C;
                7'h1F: glyph_row = 8'h00;
                7'h20: glyph_row = 8'h0C;
                7'h21: glyph_row = 8'h1C;
                7'h22: glyph_row = 8'h3C;
                7'h23: glyph_row = 8'h6C;
                7'h24: glyph_row = 8'h7E;
                7'h25: glyph_row = 8'h0C;
                7'h26: glyph_row = 8'h0C;
                7'h27: glyph_row = 8'h00;
                7'h28: glyph_row = 8'h7E;
                7'h29: glyph_row = 8'h60;
                7'h2A: glyph_row = 8'h7C;
                7'h2B: glyph_row = 8'h06;
                7'h2C: glyph_row = 8'h06;
                7'h2D: glyph_row = 8'h66;
                7'h2E: glyph_row = 8'h3C;
                7'h2F: glyph_row = 8'h00;
                7'h30: glyph_row = 8'h1C;
                7'h31: glyph_row = 8'h30;
                7'h32: glyph_row = 8'h60;
                7'h33: glyph_row = 8'h7C;
                7'h34: glyph_row = 8'h66;
                7'h35: glyph_row = 8'h66;
                7'h36: glyph_row = 8'h3C;
                7'h37: glyph_row = 8'h00;
                7'h38: glyph_row = 8'h7E;
                7'h39: glyph_row = 8'h66;
                7'h3A: glyph_row = 8'h06;
                7'h3B: glyph_row = 8'h0C;
                7'h3C: glyph_row = 8'h18;
                7'h3D: glyph_row = 8'h18;
                7'h3E: glyph_row = 8'h18;
                7'h3F: glyph_row = 8'h00;
                7'h40: glyph_row = 8'h3C;
                7'h41: glyph_row = 8'h66;
                7'h42: glyph_row = 8'h66;
                7'h43: glyph_row = 8'h3C;
                7'h44: glyph_row = 8'h66;
                7'h45: glyph_row = 8'h66;
                7'h46: glyph_row = 8'h3C;
                7'h47: glyph_row = 8'h00;
                7'h48: glyph_row = 8'h3C;
                7'h49: glyph_row = 8'h66;
                7'h4A: glyph_row = 8'h66;
                7'h4B: glyph_row = 8'h3E;
                7'h4C: glyph_row = 8'h06;
                7'h4D: glyph_row = 8'h0C;
                7'h4E: glyph_row = 8'h38;
                7'h4F: glyph_row = 8'h00;
                default: glyph_row = 8'h00;
            endcase
        end
    endfunction

    // ---- 判断当前像素是否落在方块内 ----
    wire in_box = de &&
                  (x_act >= BOX_X) && (x_act < BOX_X + BOX_W) &&
                  (y_act >= BOX_Y) && (y_act < BOX_Y + BOX_H);

    wire [11:0] bx = (x_act >= BOX_X) ? (x_act - BOX_X) : 12'd0;
    wire [11:0] by = (y_act >= BOX_Y) ? (y_act - BOX_Y) : 12'd0;

    // 放大 8 倍：屏幕坐标右移 3 位 = 字模坐标
    wire [2:0]  gcol = bx[5:3];
    wire [2:0]  grow = by[5:3];

    wire [7:0]  row_bits = glyph_row(d, grow);
    wire        bit_on   = row_bits[7 - gcol];   // MSB 是最左像素

    // ---- 合成：笔画白色，底压暗一半（保证任何背景上都看得清）----
    wire [23:0] dimmed = {1'b0, rgb_in[23:1]};
    assign rgb_out = in_box ? (bit_on ? 24'hFFFFFF : dimmed) : rgb_in;
endmodule
