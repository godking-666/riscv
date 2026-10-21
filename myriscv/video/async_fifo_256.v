`timescale 1ns/1ps
//=============================================================================
// async_fifo_256.v —— 自包含 256 位异步 FIFO（格雷码指针）
//
// 用途：桥接显示读通路的两端
//   * 写侧 = core_clk（DDR3 IP 用户时钟 93.75 MHz），display_frame_reader 写入
//   * 读侧 = pixel_clk（HDMI 74.25 MHz），hdmi_frame_out 读出
//
// 采用经典双时钟格雷码 FIFO：写指针/读指针各用 +1 位格雷码跨时钟域同步。
// 存储用 reg 数组（综合工具可推断成 sdpram，也可落 LUT），深度 64（0.8 行弹性）。
//=============================================================================
module async_fifo_256 #(
    parameter integer DATA_W      = 256,
    parameter integer ADDR_W      = 6,      // 深度 = 2^6 = 64
    parameter integer ALMOST_FULL = 48      // 64 - 16（一 burst = 16 beat 的余量）
) (
    input  wire                wr_clk,
    input  wire                wr_rst_n,
    input  wire                wr_flush,      // 写侧冲刷（本域）：帧起点清写指针
    input  wire                wr_en,
    input  wire [DATA_W-1:0]   wr_data,
    output wire                wr_full,
    output wire                wr_almost_full,

    input  wire                rd_clk,
    input  wire                rd_rst_n,
    input  wire                rd_flush,      // 读侧冲刷（本域）：帧起点清读指针
    input  wire                rd_en,
    output wire [DATA_W-1:0]   rd_data,
    output wire                rd_empty
);
    localparam DEPTH = 1 << ADDR_W;

    reg [DATA_W-1:0] mem [0:DEPTH-1];

    reg [ADDR_W:0] wr_ptr;                 // 二进制，+1 位区分满/空
    reg [ADDR_W:0] rd_ptr;
    reg [ADDR_W:0] wr_ptr_g;               // 格雷码
    reg [ADDR_W:0] rd_ptr_g;

    // 跨时钟域同步（2 级）。
    // async_reg 标记告诉综合器这是 CDC 同步器，不参与时序收敛（与队友 camera_mmio
    // 的 ready_sync/done_sync 同款写法），否则异步时钟间必然报 setup/hold 违例。
    (* async_reg="true" *) reg [ADDR_W:0] rd_ptr_g_s1, rd_ptr_g_s2;
    (* async_reg="true" *) reg [ADDR_W:0] wr_ptr_g_s1, wr_ptr_g_s2;

    wire wr_allow = wr_en && !wr_full;
    wire rd_allow = rd_en && !rd_empty;

    // ---------------- 写侧 ----------------
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n)
            wr_ptr <= {(ADDR_W+1){1'b0}};
        else if (wr_flush)
            wr_ptr <= {(ADDR_W+1){1'b0}};
        else if (wr_allow)
            wr_ptr <= wr_ptr + 1'b1;
    end

    always @(posedge wr_clk) begin
        if (wr_allow)
            mem[wr_ptr[ADDR_W-1:0]] <= wr_data;
    end

    // ---------------- 读侧 ----------------
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n)
            rd_ptr <= {(ADDR_W+1){1'b0}};
        else if (rd_flush)
            rd_ptr <= {(ADDR_W+1){1'b0}};
        else if (rd_allow)
            rd_ptr <= rd_ptr + 1'b1;
    end

    assign rd_data = mem[rd_ptr[ADDR_W-1:0]];

    // ---------------- 格雷码 ----------------
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) wr_ptr_g <= 0;
        else if (wr_flush) wr_ptr_g <= 0;
        else           wr_ptr_g <= wr_ptr ^ (wr_ptr >> 1);
    end
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) rd_ptr_g <= 0;
        else if (rd_flush) rd_ptr_g <= 0;
        else           rd_ptr_g <= rd_ptr ^ (rd_ptr >> 1);
    end

    // ---------------- 两级同步 ----------------
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin rd_ptr_g_s1 <= 0; rd_ptr_g_s2 <= 0; end
        else           begin rd_ptr_g_s1 <= rd_ptr_g; rd_ptr_g_s2 <= rd_ptr_g_s1; end
    end
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin wr_ptr_g_s1 <= 0; wr_ptr_g_s2 <= 0; end
        else           begin wr_ptr_g_s1 <= wr_ptr_g; wr_ptr_g_s2 <= wr_ptr_g_s1; end
    end

    // ---------------- 满 / 空 ----------------
    // 经典判据：最高两位取反即满；两指针格雷码全等即空
    assign wr_full = (wr_ptr_g == {~rd_ptr_g_s2[ADDR_W], ~rd_ptr_g_s2[ADDR_W-1],
                                   rd_ptr_g_s2[ADDR_W-2:0]});
    assign rd_empty = (rd_ptr_g == wr_ptr_g_s2);

    // ---------------- 几乎满（用二进制距离，供读侧反压）----------------
    function [ADDR_W:0] gray2bin;
        input [ADDR_W:0] g;
        integer i;
        begin
            gray2bin[ADDR_W] = g[ADDR_W];
            for (i = ADDR_W-1; i >= 0; i = i-1)
                gray2bin[i] = gray2bin[i+1] ^ g[i];
        end
    endfunction

    wire [ADDR_W:0] rd_bin_sync = gray2bin(rd_ptr_g_s2);
    wire [ADDR_W:0] wr_count = wr_ptr - rd_bin_sync;   // 当前占用字数（0..DEPTH）
    assign wr_almost_full = (wr_count >= ALMOST_FULL[ADDR_W:0]);

endmodule
