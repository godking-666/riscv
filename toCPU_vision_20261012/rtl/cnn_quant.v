//======================================================================
// cnn_quant.v -- int8 定点重缩放（累加器域 -> int8 激活）
//
//   y = clamp( (acc*m + (1<<(sh-1))) >>> sh , -128, 127 )
//
// ★ 本模块**不再自带乘法器**：乘好的 prod = acc*m 由 cnn_pe_array 里那个
//   「一器两用」的乘法器送进来（累加模式算 w*a，量化模式算 acc*m），
//   这样每个 PE lane 只综合出 1 个 DSP（见 cnn_pe_array.v 的说明）。
//
// 与 tools/cnn_golden.py 的 requant() 逐位一致：四舍五入 + 算术右移
// （负数向下取整）两者都对齐。
//
// 踩过的坑：
//   * sh 可能是 0（理论上不会，但别让 (1<<(sh-1)) 变成负移位）。
//   * prod 必须是有符号 41 位：24 位累加器 x 16 位 m 最宽 40 位+符号。
//======================================================================
`timescale 1ns / 1ps

module cnn_quant (
    input  wire signed [40:0] prod,        // acc*m（已乘好）
    input  wire        [7:0]  sh,
    output wire signed [7:0]  y,
    output wire               sat          // 1 = 结果被饱和截断（调试用）
);
    wire        [40:0] rnd_half = (sh == 8'd0) ? 41'd0 : (41'd1 << (sh - 8'd1));
    wire signed [40:0] rounded  = prod + $signed(rnd_half);
    wire signed [40:0] shifted  = (sh == 8'd0) ? rounded : (rounded >>> sh);

    wire over  = (shifted >  $signed(41'sd127));
    wire under = (shifted < -$signed(41'sd128));

    assign y   = over  ?  8'sd127 :
                 under ? -8'sd128 :
                         shifted[7:0];
    assign sat = over | under;
endmodule