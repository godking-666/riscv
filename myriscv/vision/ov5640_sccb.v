//======================================================================
// ov5640_sccb.v -- OV5640 SCCB（类 I2C）配置主机
//
// 按 ov5640_init_table.vh 里的表，逐条以 SCCB 三线写时序下发：
//   START | 器件地址 | ACK | 寄存器高 | ACK | 寄存器低 | ACK | 数据 | ACK | STOP
//
// 实现要点：
//   * 36 位移位寄存器一次装下 4 个字节 + 4 个 ACK 槽：MSB 先出，
//     位值 1 = 释放 SDA（高），0 = 拉低 SDA。ACK 槽固定填 1，让从机驱动。
//   * 每个位分 4 个相位，各 phase 持续 DIV_CNT 个 clk，SCL 频率 = CLK_HZ/(4*DIV_CNT)。
//   * 采样从机 ACK 存入 ack_err（粘滞），软件可读；不因 NACK 中断流程
//     —— SCCB 本来就允许从机不应答，中断流程反而更难定位问题。
//   * 表项里的 delay_ms 用于软复位后的等待，必须真有，否则后面的写入会丢。
//
// 器件地址：OV5640 写地址 0x78（8 位形式，即 0x3C<<1）。
//======================================================================
`timescale 1ns / 1ps

module ov5640_sccb #(
    parameter CLK_HZ = 93750000,
    parameter SCL_HZ = 100000
)(
    input  wire clk,
    input  wire rstn,

    input  wire start,        // 1 拍脉冲：开始跑整张表
    output reg  busy,
    output reg  done,         // 1 拍脉冲：整张表跑完
    output reg  ack_err,      // 粘滞：出现过 NACK（1 拍写 clear 清）

    input  wire clear_err,

    // SCCB 三线（开漏：sda_oe=1 且 sda_out=0 时拉低，否则释放）
    output reg  scl,
    output reg  sda_out,
    output reg  sda_oe,
    input  wire sda_in
);
    localparam CLK_KHZ = (CLK_HZ + 500) / 1000;
    localparam DIV_CNT = (CLK_HZ / (SCL_HZ * 4));
    // DIV_CNT 需 >= 1；93.75MHz clk / 100kHz SCL 下为 234（实际 SCL ≈ 100.2 kHz）

    localparam S_IDLE  = 3'd0;
    localparam S_START = 3'd1;
    localparam S_BITS  = 3'd2;
    localparam S_STOP  = 3'd3;
    localparam S_DLY   = 3'd4;
    localparam S_NEXT  = 3'd5;
    localparam S_DONE  = 3'd6;

    `include "ov5640_init_table.vh"

    reg [2:0]  st;
    reg [1:0]  ph;
    reg [5:0]  slot;          // 0..35
    reg [5:0]  idx;           // 表项下标
    reg [35:0] tx_sh;
    reg [31:0] cur_entry;
    reg [31:0] dly_cnt;
    reg [15:0] div_cnt;
    wire [15:0] div_reload = DIV_CNT - 1;

    reg        req;           // start 锁存：start 是单拍脉冲，而状态机只在 tick 那拍看它，
                              // 不锁存就会漏拍（曾经的实际 bug）
    always @(posedge clk) begin
        if (!rstn)             req <= 1'b0;
        else if (start)        req <= 1'b1;
        else if (st != S_IDLE) req <= 1'b0;
    end

    wire tick = (div_cnt == 0);
    always @(posedge clk) begin
        if (!rstn) div_cnt <= div_reload;
        else       div_cnt <= tick ? div_reload : (div_cnt - 16'd1);
    end

    // ACK 槽位置：每个字节的第 9 位
    wire is_ack_slot = (slot == 6'd8) || (slot == 6'd17) ||
                       (slot == 6'd26) || (slot == 6'd35);

    // 组装一条表项的 36 位发送序列
    function [35:0] pack_entry;
        input [31:0] e;
        begin
            pack_entry = { 8'h78, 1'b1,
                           e[31:24], 1'b1,
                           e[23:16], 1'b1,
                           e[15: 8], 1'b1 };
        end
    endfunction

    always @(posedge clk) begin
        if (!rstn) begin
            st        <= S_IDLE;
            ph        <= 2'd0;
            slot      <= 6'd0;
            idx       <= 6'd0;
            tx_sh     <= 36'd0;
            cur_entry <= 32'd0;
            dly_cnt   <= 32'd0;
            busy      <= 1'b0;
            done      <= 1'b0;
            ack_err   <= 1'b0;
            scl       <= 1'b1;
            sda_out   <= 1'b1;
            sda_oe    <= 1'b0;
        end
        else begin
            done <= 1'b0;
            if (clear_err) ack_err <= 1'b0;

            // 延时状态不进 tick 节拍，按 clk 直接数
            if (st == S_DLY) begin
                if (dly_cnt == 32'd0) st <= S_NEXT;
                else                  dly_cnt <= dly_cnt - 32'd1;
            end
            else if (tick) begin
                case (st)
                    // ---------------- 空闲 ----------------
                    S_IDLE: begin
                        scl     <= 1'b1;
                        sda_out <= 1'b1;
                        sda_oe  <= 1'b0;
                        if (req) begin
                            cur_entry <= ov5640_init_entry(6'd0);
                            tx_sh     <= pack_entry(ov5640_init_entry(6'd0));
                            idx       <= 6'd0;
                            slot      <= 6'd0;
                            ph        <= 2'd0;
                            busy      <= 1'b1;
                            st        <= S_START;
                        end
                    end

                    // ---------------- START 条件 ----------------
                    S_START: begin
                        case (ph)
                            2'd0: begin scl <= 1'b1; sda_oe <= 1'b1; sda_out <= 1'b1; end
                            2'd1: begin scl <= 1'b1; sda_oe <= 1'b1; sda_out <= 1'b1; end
                            2'd2: begin scl <= 1'b1; sda_oe <= 1'b1; sda_out <= 1'b0; end
                            2'd3: begin scl <= 1'b0; sda_oe <= 1'b1; sda_out <= 1'b0; end
                            default: ;
                        endcase
                        if (ph == 2'd3) begin ph <= 2'd0; st <= S_BITS; end
                        else                  ph <= ph + 2'd1;
                    end

                    // ---------------- 36 个位槽 ----------------
                    S_BITS: begin
                        case (ph)
                            2'd0: begin
                                scl     <= 1'b0;
                                sda_out <= tx_sh[35];
                                sda_oe  <= ~tx_sh[35];   // 1 = 释放总线
                            end
                            2'd1: scl <= 1'b1;
                            2'd2: begin
                                scl <= 1'b1;
                                if (is_ack_slot && sda_in) ack_err <= 1'b1;  // NACK
                            end
                            2'd3: begin
                                scl   <= 1'b0;
                                tx_sh <= {tx_sh[34:0], 1'b1};
                            end
                            default: ;
                        endcase
                        if (ph == 2'd3) begin
                            ph <= 2'd0;
                            if (slot == 6'd35) begin slot <= 6'd0; st <= S_STOP; end
                            else                     slot <= slot + 6'd1;
                        end
                        else ph <= ph + 2'd1;
                    end

                    // ---------------- STOP 条件 ----------------
                    S_STOP: begin
                        case (ph)
                            2'd0: begin scl <= 1'b0; sda_oe <= 1'b1; sda_out <= 1'b0; end
                            2'd1: begin scl <= 1'b1; sda_oe <= 1'b1; sda_out <= 1'b0; end
                            2'd2: begin scl <= 1'b1; sda_oe <= 1'b0; sda_out <= 1'b1; end
                            2'd3: begin scl <= 1'b1; sda_oe <= 1'b0; sda_out <= 1'b1; end
                            default: ;
                        endcase
                        if (ph == 2'd3) begin
                            ph <= 2'd0;
                            if (cur_entry[7:0] != 8'd0) begin
                                dly_cnt <= cur_entry[7:0] * CLK_KHZ;
                                st      <= S_DLY;
                            end
                            else st <= S_NEXT;
                        end
                        else ph <= ph + 2'd1;
                    end

                    // ---------------- 取下一项 ----------------
                    S_NEXT: begin
                        if (idx >= (OV5640_INIT_N - 1)) begin
                            st <= S_DONE;
                        end
                        else begin
                            cur_entry <= ov5640_init_entry(idx + 6'd1);
                            tx_sh     <= pack_entry(ov5640_init_entry(idx + 6'd1));
                            idx       <= idx + 6'd1;
                            slot      <= 6'd0;
                            ph        <= 2'd0;
                            st        <= S_START;
                        end
                    end

                    // ---------------- 结束 ----------------
                    S_DONE: begin
                        busy <= 1'b0;
                        done <= 1'b1;
                        st   <= S_IDLE;
                    end

                    default: st <= S_IDLE;
                endcase
            end
        end
    end
endmodule
