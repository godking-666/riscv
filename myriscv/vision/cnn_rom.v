//======================================================================
// cnn_rom.v -- 权重/bias 只读存储器（clk 域）
//
// 数据来自 tools/cnn_golden.py 生成的 rtl/cnn_weights.vh（勿手改）。
// 这一层包装只做两件事：
//   1) 加读出寄存器 -> 让综合工具把 ROM 放进 BRAM/ROM 资源，而不是一大片 LUT；
//   2) 越界地址返回 0 -> 仿真里不会读到 X，TB 不会因为 X 传播误报。
//
// 读延迟：w_data/b_data/fc_data 都是 1 拍（地址拍进去、下一拍数据出来）；
// cfg_data 是组合读（只在换层那一刻用，路径很短）。
//
// 踩过的坑：cnn_weights.vh 里的数组必须在 module 内部 include，
//           否则 reg 数组会变成模块外的东西，综合工具认不出来。
//======================================================================
`timescale 1ns / 1ps

// 端口位宽用 cnn_defs.vh 的宏（`define 预处理按文本顺序，必须在端口声明之前 include）
`include "cnn_defs.vh"

module cnn_rom #(
    parameter integer FC_BW = 3200
) (
    input  wire         clk,

    input  wire [`CNN_W_AW-1:0]  w_addr,
    output wire [63:0]  w_data,

    input  wire [`CNN_B_AW-1:0]  b_addr,
    output reg  [255:0] b_data,

    input  wire [7:0]   cfg_addr,
    output wire [31:0]  cfg_data,

    input  wire [`CNN_FC_AW-1:0] fc_addr,
    output wire [31:0]  fc_data,

    output wire [FC_BW-1:0] fc_bias
);
    `include "cnn_weights.vh"

    always @(posedge clk) begin
        b_data  <= (b_addr  < CNN_B_OGS)                ? cnn_b_rom[b_addr]  : 256'd0;
    end

    assign w_data = (w_addr < CNN_W_WORDS) ? cnn_w_rom[w_addr] : 64'd0;
    assign cfg_data = (cfg_addr < `CNN_NLAYER * `CNN_CFG_N) ? cnn_cfg[cfg_addr] : 32'd0;
    assign fc_data = (fc_addr < CNN_FC_IW) ? cnn_fc_w[fc_addr] : 32'd0;
    assign fc_bias  = CNN_FC_B;
endmodule