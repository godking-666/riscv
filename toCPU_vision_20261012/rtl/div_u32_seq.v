//======================================================================
// div_u32_seq.v -- 32 位无符号顺序除法器
//
//   quotient = dividend / divisor   （divisor == 0 时输出 0）
//
// 每帧只调用一次，速度要求低：用 33 拍换取面积小、时序友好。
// 用途：分类器计算 SCORE = 前景像素数 / ROI 面积 × 1000（千分比）。
//======================================================================
`timescale 1ns / 1ps

module div_u32_seq (
    input  wire        clk,
    input  wire        rstn,
    input  wire        start,      // 1 拍脉冲启动
    input  wire [31:0] dividend,
    input  wire [31:0] divisor,
    output reg  [31:0] quotient,
    output reg         busy,
    output reg         done        // 结束时 1 拍脉冲
);
    reg [31:0] q;      // 移位寄存器：开始时装被除数，结束时装商
    reg [32:0] r;      // 余数（33 位，避免移位溢出）
    reg [31:0] d;
    reg [ 5:0] cnt;
    reg        dv0;    // 除数为 0 标志

    // 一次迭代的组合逻辑
    wire [32:0] r_sh = {r[31:0], q[31]};
    wire        ge   = (r_sh >= {1'b0, d});
    wire [32:0] r_nx = ge ? (r_sh - {1'b0, d}) : r_sh;
    wire [31:0] q_nx = {q[30:0], ge};

    always @(posedge clk) begin
        if (!rstn) begin
            busy     <= 1'b0;
            done     <= 1'b0;
            quotient <= 32'd0;
            q        <= 32'd0;
            r        <= 33'd0;
            d        <= 32'd0;
            cnt      <= 6'd0;
            dv0      <= 1'b0;
        end
        else begin
            done <= 1'b0;

            if (start && !busy) begin
                busy     <= 1'b1;
                q        <= dividend;
                r        <= 33'd0;
                d        <= divisor;
                cnt      <= 6'd32;
                dv0      <= (divisor == 32'd0);
                quotient <= 32'd0;
            end
            else if (busy) begin
                r   <= r_nx;
                q   <= q_nx;
                cnt <= cnt - 6'd1;
                if (cnt == 6'd1) begin
                    busy     <= 1'b0;
                    done     <= 1'b1;
                    quotient <= dv0 ? 32'd0 : q_nx;
                end
            end
        end
    end
endmodule