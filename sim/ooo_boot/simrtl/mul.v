// ============================================================================
// mul  --  厂家 APM 原语的仿真替身（仅用于 ModelSim）
//
// 真实器件里 `mul` 是 Pango 的 APM 原语：33x33 有符号乘法、带 ce/rst、
// 三级流水寄存器（见 ooo_core.v:478 注释 "2 pipeline registers (APM)"）。
// 仿真库里没有它，这里给出等价的行为模型，使迭代意核能被仿真。
//
// 位流仍由真正的厂家原语构建，本文件不参与综合。
// ============================================================================
`timescale 1ns / 1ps

module mul (
    input  wire        ce,
    input  wire        rst,
    input  wire        clk,
    input  wire [32:0] a,
    input  wire [32:0] b,
    output wire [65:0] p
);
    reg [65:0] p1, p2, p3;

    always @(posedge clk) begin
        if (rst) begin
            p1 <= 66'd0;
            p2 <= 66'd0;
            p3 <= 66'd0;
        end else if (ce) begin
            p1 <= $signed(a) * $signed(b);
            p2 <= p1;
            p3 <= p2;
        end
    end

    assign p = p3;
endmodule
