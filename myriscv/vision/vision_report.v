//======================================================================
// vision_report.v -- 结果行格式化 + 串口上报（CPU 兜底通路用）
//
// 把一帧的识别结果拼成一行紧凑文本，逐字节交给 uart_tx：
//   VISION,<帧号>,<类别>,<x0>,<y0>,<x1>,<y1>,<置信度>,<延迟us>,<计数>\n
//
// ★ 这条格式是两侧共用的协议 ★
//   正式方案里由 CPU 上的 sw/main.c 用 uart_putc() 发出（同一个格式），
//   RK3568 上的 host/vision_console.py 负责解析。
//   改字段顺序/分隔符必须同时改这三处。
//
// 为什么要有这个模块：
//   CPU 核由另一组设计，在它就绪之前（或演示时作为兜底），需要一条
//   「纯硬件」通路把结果发出来。本模块 + demo_bus_master + uart_tx
//   组成的 demo_top 不依赖任何 CPU 就能跑完整流程。
//
// 实现要点：
//   * 先把整行拼进一个小的分布式 RAM msg[]，再整行顺序发出，
//     避免做「一边算一边发」的复杂流水。
//   * 十进制用顺序除法器逐位取，不做 64 位组合除法。
//   * 延迟 us = frame_cyc * 1000 / CAM_CLK_KHZ（frame_cyc 单位是 cam 时钟周期）。
//======================================================================
`timescale 1ns / 1ps

module vision_report #(
    parameter CAM_CLK_KHZ = 25000,   // 摄像头 PCLK 频率（kHz）
    parameter MSG_MAX     = 96       // 一行最长字节数，留足余量
)(
    input  wire        clk,
    input  wire        rstn,

    input  wire        start,        // 1 拍脉冲：开始拼一行并发送
    input  wire [31:0] frame_no,
    input  wire [31:0] cls,          // 0=A 1=B 2=C 其他=--
    input  wire [31:0] x0,
    input  wire [31:0] y0,
    input  wire [31:0] x1,
    input  wire [31:0] y1,
    input  wire [31:0] score,
    input  wire [31:0] frame_cyc,
    input  wire [31:0] item_cnt,

    output reg  [7:0]  tx_data,
    output reg         tx_valid,
    input  wire        tx_ready,

    output reg         busy,         // 从 start 到 done 之间为 1
    output reg         done          // 整行发完，1 拍脉冲
);
    // ---- 字段编号（顺序即协议顺序）----
    // 0=帧号 1=类别 2=x0 3=y0 4=x1 5=y1 6=置信度 7=延迟us 8=计数
    localparam F_LAST = 5'd8;
    localparam LIT_N  = 5'd7;        // "VISION,"

    // ---- 主状态 ----
    localparam S_IDLE  = 3'd0;
    localparam S_LAT   = 3'd1;       // 求延迟 us
    localparam S_LATW  = 3'd2;
    localparam S_MSG   = 3'd3;       // 拼行
    localparam S_TX    = 3'd4;       // 发出去
    localparam S_FIN   = 3'd5;

    // ---- 拼行子状态 ----
    localparam M_LIT   = 3'd0;
    localparam M_FIELD = 3'd1;
    localparam M_CLS   = 3'd2;
    localparam M_DIV   = 3'd3;
    localparam M_DIVW  = 3'd4;
    localparam M_NEMIT = 3'd5;
    localparam M_SEP   = 3'd6;

    reg [7:0]  msg [0:MSG_MAX-1];
    reg [7:0]  wptr;                 // 已写入字节数

    reg [7:0]  dig [0:9];            // 十进制数字栈，LSB 在前
    reg [7:0]  dcnt;                 // 已入栈位数
    reg [7:0]  eidx;                 // 出栈索引

    reg [31:0] cur_val;
    reg [31:0] lat_us;

    reg [2:0]  st;
    reg [2:0]  mst;
    reg [4:0]  lit_i;
    reg [4:0]  fidx;
    reg [7:0]  tidx;

    // ---- 延迟换算用的除法器 ----
    reg         lat_start;
    wire [31:0] lat_q;
    wire        lat_done, lat_busy;

    div_u32_seq u_div_lat (
        .clk      (clk),
        .rstn     (rstn),
        .start    (lat_start),
        // frame_cyc*1000 在 frame_cyc < 4.29M 时不溢出（cam 域 25MHz 下即约 172ms/帧）
        .dividend (frame_cyc * 32'd1000),
        .divisor  ((CAM_CLK_KHZ == 0) ? 32'd1 : CAM_CLK_KHZ),
        .quotient (lat_q),
        .busy     (lat_busy),
        .done     (lat_done)
    );

    // ---- 取十进制数字用的除法器（每次除 10）----
    reg         dg_start;
    reg [31:0]  dg_dividend;
    wire [31:0] dg_q;
    wire        dg_done, dg_busy;

    div_u32_seq u_div_dig (
        .clk      (clk),
        .rstn     (rstn),
        .start    (dg_start),
        .dividend (dg_dividend),
        .divisor  (32'd10),
        .quotient (dg_q),
        .busy     (dg_busy),
        .done     (dg_done)
    );

    // ---- "VISION," 的常量部分 ----
    function [7:0] lit_ch;
        input [4:0] i;
        begin
            case (i)
                5'd0: lit_ch = "V";
                5'd1: lit_ch = "I";
                5'd2: lit_ch = "S";
                5'd3: lit_ch = "I";
                5'd4: lit_ch = "O";
                5'd5: lit_ch = "N";
                5'd6: lit_ch = ",";
                default: lit_ch = 8'h20;
            endcase
        end
    endfunction

    // ---- 字段 -> 数值 ----
    function [31:0] num_val;
        input [4:0] f;
        begin
            case (f)
                5'd0: num_val = frame_no;
                5'd2: num_val = x0;
                5'd3: num_val = y0;
                5'd4: num_val = x1;
                5'd5: num_val = y1;
                5'd6: num_val = score;
                5'd7: num_val = lat_us;
                5'd8: num_val = item_cnt;
                default: num_val = 32'd0;
            endcase
        end
    endfunction

    always @(posedge clk) begin
        if (!rstn) begin
            st        <= S_IDLE;
            mst       <= M_LIT;
            wptr      <= 8'd0;
            lit_i     <= 5'd0;
            fidx      <= 5'd0;
            tidx      <= 8'd0;
            tx_data   <= 8'd0;
            tx_valid  <= 1'b0;
            cur_val   <= 32'd0;
            lat_us    <= 32'd0;
            dcnt      <= 8'd0;
            eidx      <= 8'd0;
            busy      <= 1'b0;
            done      <= 1'b0;
            lat_start <= 1'b0;
            dg_start  <= 1'b0;
            dg_dividend <= 32'd0;
        end
        else begin
            done      <= 1'b0;
            lat_start <= 1'b0;
            dg_start  <= 1'b0;

            case (st)
                S_IDLE: begin
                    if (start && !busy) begin
                        busy      <= 1'b1;
                        lat_start <= 1'b1;
                        wptr      <= 8'd0;
                        st        <= S_LAT;
                    end
                end

                S_LAT: st <= S_LATW;    // 让 start 被除法器吃掉

                S_LATW: begin
                    if (lat_done) begin
                        lat_us <= (lat_q > 32'd1000000) ? 32'd1000000 : lat_q;
                        lit_i  <= 5'd0;
                        mst    <= M_LIT;
                        st     <= S_MSG;
                    end
                end

                //---------------- 拼行 ----------------
                S_MSG: begin
                    case (mst)
                        M_LIT: begin
                            msg[wptr] <= lit_ch(lit_i);
                            wptr      <= wptr + 8'd1;
                            if (lit_i == (LIT_N - 5'd1)) begin
                                fidx <= 5'd0;
                                mst  <= M_FIELD;
                            end
                            lit_i <= lit_i + 5'd1;
                        end

                        M_FIELD: begin
                            if (fidx == 5'd1) mst <= M_CLS;   // 类别走字符串分支
                            else begin
                                cur_val <= num_val(fidx);
                                dcnt    <= 8'd0;
                                mst     <= M_DIV;
                            end
                        end

                        M_CLS: begin
                            if (cls <= 32'd2) begin
                                msg[wptr] <= 8'd65 + cls[7:0];   // 'A' + cls
                                wptr      <= wptr + 8'd1;
                            end
                            else begin
                                msg[wptr]     <= "-";
                                msg[wptr + 8'd1] <= "-";
                                wptr          <= wptr + 8'd2;
                            end
                            mst <= M_SEP;
                        end

                        M_DIV: begin
                            dg_dividend <= cur_val;
                            dg_start    <= 1'b1;
                            mst         <= M_DIVW;
                        end

                        M_DIVW: begin
                            if (dg_done) begin
                                // 余数 = 被除数 - 商*10，正好是一位数字
                                dig[dcnt] <= 8'd48 + (dg_dividend - dg_q * 32'd10);
                                dcnt      <= dcnt + 8'd1;
                                cur_val   <= dg_q;
                                if (dg_q == 32'd0) begin
                                    eidx <= dcnt + 8'd1;
                                    mst  <= M_NEMIT;
                                end
                                else mst <= M_DIV;
                            end
                        end

                        M_NEMIT: begin
                            if (eidx == 8'd0) mst <= M_SEP;
                            else begin
                                msg[wptr] <= dig[eidx - 8'd1];
                                wptr      <= wptr + 8'd1;
                                eidx      <= eidx - 8'd1;
                            end
                        end

                        M_SEP: begin
                            if (fidx == F_LAST) begin
                                msg[wptr] <= 8'd10;              // '\n'
                                wptr      <= wptr + 8'd1;
                                tidx      <= 8'd0;
                                st        <= S_TX;
                            end
                            else begin
                                msg[wptr] <= ",";
                                wptr      <= wptr + 8'd1;
                                fidx      <= fidx + 5'd1;
                                mst       <= M_FIELD;
                            end
                        end

                        default: mst <= M_LIT;
                    endcase
                end

                //---------------- 串口发出 ----------------
                S_TX: begin
                    if (!tx_valid) begin
                        if (tidx < wptr) begin
                            tx_data  <= msg[tidx];
                            tx_valid <= 1'b1;
                        end
                        else st <= S_FIN;
                    end
                    else if (tx_ready) begin
                        tx_valid <= 1'b0;
                        tidx     <= tidx + 8'd1;
                    end
                end

                S_FIN: begin
                    done <= 1'b1;
                    busy <= 1'b0;
                    st   <= S_IDLE;
                end

                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
