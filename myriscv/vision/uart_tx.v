//======================================================================
// uart_tx.v -- 简易 UART 发送器（8N1，无校验）
//
// 用途：把识别结果行发给 RK3568 显示终端。
//   * 只在「无 CPU 兜底通路」里用到；正式方案里这行文本由 CPU 上的
//     sw/main.c 用 uart_putc() 发出。两条通路发的是同一种格式。
//   * 频率用参数给，换时钟/换波特率只改参数。
//
// 握手：ready=1 表示空闲可收。valid && ready 当拍被吃进一个字节，
//       之后 ready 拉低直到 stop 位发完。
//======================================================================
`timescale 1ns / 1ps

module uart_tx #(
    parameter CLK_HZ = 93750000,   // 与 CPU 组 core_clk 一致；115200 时分频 814 拍/位
    parameter BAUD   = 115200
)(
    input  wire       clk,
    input  wire       rstn,

    input  wire [7:0] data,
    input  wire       valid,
    output reg        ready,     // 1 = 空闲，可接收新字节
    output reg        tx         // 空闲时为 1
);
    localparam [31:0] DIV = (CLK_HZ + BAUD / 2) / BAUD;

    localparam S_IDLE  = 2'd0;
    localparam S_START = 2'd1;
    localparam S_DATA  = 2'd2;
    localparam S_STOP  = 2'd3;

    reg [ 1:0] st;
    reg [31:0] cnt;
    reg [ 7:0] sh;
    reg [ 2:0] bc;

    always @(posedge clk) begin
        if (!rstn) begin
            st    <= S_IDLE;
            cnt   <= 32'd0;
            sh    <= 8'd0;
            bc    <= 3'd0;
            tx    <= 1'b1;
            ready <= 1'b1;
        end
        else begin
            case (st)
                S_IDLE: begin
                    tx    <= 1'b1;
                    ready <= 1'b1;      // 下面若真收到字节，这句会被后面的赋值覆盖
                    if (valid && ready) begin
                        sh    <= data;
                        bc    <= 3'd7;
                        cnt   <= DIV - 32'd1;
                        ready <= 1'b0;
                        tx    <= 1'b0;  // start 位
                        st    <= S_START;
                    end
                end

                // start 位发完，顺手把 bit0 推到线上（sh 已右移一位，下面发 bit1..bit7）
                S_START: begin
                    if (cnt == 32'd0) begin
                        cnt <= DIV - 32'd1;
                        tx  <= sh[0];
                        sh  <= {1'b0, sh[7:1]};
                        st  <= S_DATA;
                    end
                    else cnt <= cnt - 32'd1;
                end

                S_DATA: begin
                    if (cnt == 32'd0) begin
                        cnt <= DIV - 32'd1;
                        if (bc == 3'd0) begin
                            tx <= 1'b1;     // stop 位
                            st <= S_STOP;
                        end
                        else begin
                            tx <= sh[0];
                            sh <= {1'b0, sh[7:1]};
                            bc <= bc - 3'd1;
                        end
                    end
                    else cnt <= cnt - 32'd1;
                end

                S_STOP: begin
                    if (cnt == 32'd0) begin
                        ready <= 1'b1;
                        st    <= S_IDLE;
                    end
                    else cnt <= cnt - 32'd1;
                end

                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
