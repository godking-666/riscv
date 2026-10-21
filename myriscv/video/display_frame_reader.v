`timescale 1ns/1ps
//=============================================================================
// display_frame_reader.v —— 显示帧线性突发读（core_clk 域）
//
// 从 DDR3 原生地址（帧 A=28'h0400000 / 帧 B=28'h0480000，32 位字地址）线性读出
// 一帧，以 16 beat（256bit × 16 = 512 B）为突发，共 FRAME_BURSTS 个突发。
//
// 帧布局：1280×720 RGB565 = 1843200 B = 460800 字 = 57600 beat = 3600 突发。
// 每 beat = 8 字 = 16 像素；每 burst = 16 beat = 128 字。
//
// ★ 帧同步设计（这是修掉"画面被切成多块"的关键）
//   * 每收到一个 frame_start（显示器 vs 起点，已同步到本域）就从 burst 0 开始读
//   * 读满 FRAME_BURSTS 个突发后**停在 S_IDLE**，等下一个 frame_start
//   * 因为读侧被 FIFO 的 almost_full 反压，速率自动与像素端匹配，
//     所以它恰好在**一个显示帧内**读完 3600 个突发，帧间 FIFO 自然排空
//   ⇒ 帧边界严格对齐 vs，且帧首不会混入上一帧的残留数据
//
//   之前"自由运行 + 读满就绕回"的做法会让绕回点落在显示画面任意位置，
//   表现为一条横贯全宽的水平接缝（外加绕回时的行内相位错位造成的垂直接缝）。
//=============================================================================
module display_frame_reader #(
    parameter [27:0] FRAME_ADDR   = 28'h0400000,   // 帧 A 原生字地址（保留兼容）
    parameter integer FRAME_BURSTS = 3600,         // 57600 beat / 16
    parameter [3:0]  ARLEN        = 4'd15          // 16 beat
) (
    input  wire         clk,
    input  wire         resetn,
    // 帧选择：0 = 缓冲 A(0x0400000)，1 = 缓冲 B(0x0480000)
    // 由 soc_ddr3_top 根据 camera_mmio 的 source_seq0/seq1 判断"哪个最新"
    input  wire         frame_sel,
    // 帧起点脉冲（已同步到 clk）：显示器 vs 起点，开始读新的一帧
    input  wire         restart,
    // ---- 到仲裁器的 AR ----
    output wire [27:0]  araddr,
    output wire [3:0]   arlen,
    output reg          arvalid,
    input  wire         arready,
    // ---- 仲裁器路由回来的 R ----
    input  wire         rvalid,
    input  wire         rlast,
    input  wire [255:0] rdata,
    // ---- 到异步 FIFO 的写侧 ----
    output reg          fifo_wr_en,
    output reg [255:0]  fifo_wr_data,
    input  wire         fifo_almost_full
);
    localparam S_IDLE = 2'd0, S_AR = 2'd1, S_RD = 2'd2;

    reg [1:0]  state;
    reg [11:0] burst_cnt;   // 0..3599

    assign arlen = ARLEN;

    // ---- 帧基址选择 ----
    // 相机 A/B 双缓冲交替写；camera_mmio 在**开始写**某缓冲时把它的 buffer_seq 清 0、
    // **写完**才置 frame_seq+1，所以 seq 大的那个一定是已完成的，不会读到半写帧。
    // 在每帧起点锁存，保证一帧之内基址不变。
    localparam [27:0] FRAME_A = 28'h0400000;
    localparam [27:0] FRAME_B = 28'h0480000;

    reg  [27:0] frame_base;
    wire [27:0] frame_base_next = frame_sel ? FRAME_B : FRAME_A;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) frame_base <= FRAME_A;
        else if (state == S_IDLE && restart) frame_base <= frame_base_next;
    end

    // 突发 N 的起始字地址 = frame_base + N*128（每 burst 16 beat × 8 字）
    assign araddr = frame_base + ({16'd0, burst_cnt} << 7);

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            state <= S_IDLE;
            burst_cnt <= 12'd0;
            arvalid <= 1'b0;
            fifo_wr_en <= 1'b0;
            fifo_wr_data <= 256'd0;
        end else begin
            fifo_wr_en <= 1'b0;   // 默认不写
            case (state)
                // 等显示帧起点；到了就从 burst 0 开始读这一帧
                S_IDLE: begin
                    arvalid <= 1'b0;
                    if (restart) begin
                        burst_cnt <= 12'd0;
                        state <= S_AR;
                    end
                end
                S_AR: begin
                    if (!fifo_almost_full) begin
                        arvalid <= 1'b1;
                        if (arvalid && arready) begin
                            arvalid <= 1'b0;
                            state <= S_RD;
                        end
                    end else begin
                        arvalid <= 1'b0;
                    end
                end
                S_RD: begin
                    if (rvalid) begin
                        fifo_wr_en <= 1'b1;
                        fifo_wr_data <= rdata;
                        if (rlast) begin
                            if (burst_cnt == FRAME_BURSTS-1) begin
                                // 这一帧读完了：停下来等下一个 frame_start，
                                // 帧间 FIFO 因此自然排空，帧首不会混入上一帧残留。
                                burst_cnt <= 12'd0;
                                state <= S_IDLE;
                            end else begin
                                burst_cnt <= burst_cnt + 12'd1;
                                state <= S_AR;
                            end
                        end
                    end
                end
            endcase
        end
    end
endmodule
