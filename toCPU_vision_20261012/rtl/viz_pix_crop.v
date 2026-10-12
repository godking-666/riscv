//======================================================================
// viz_pix_crop.v -- ROI -> 32x32 灰度采样 + 减帧均值（cam_pclk 域）
//
// 这个模块解决什么问题：
//   OV5640 给的是 320x240 的灰度流（ov5640_capture 已经把 RGB565 压成 1 字节），
//   CNN 要的是 32x32 int8、且**已减去自身均值**的图（golden 的 IMG 行就是这么做出来的）。
//   图像不进 CPU、不进 Cache，就在这里从像素流直接变成网络输入。
//
// 采样方式：点采样，坐标和目标与 tools/cnn_golden.py 的 read_pgm 一致
//      目标坐标 = roi + (rx * roi_w) >> 5      (rx, ry = 0..31)
//   不用盒式平均：盒式平均要 1024 个累加器 + 计数器，而点采样只要一个和。
//   代价是对噪声更敏感 —— 上板若发现抖动大，把这里换成「每格累加 + 计数」即可，
//   下游（viz_pix_buf / CNN）一行都不用动。
//
// 两遍法（必须两遍，因为均值是整帧的平均）：
//   第一遍（S_SAMPLE）：等到像素坐标等于目标坐标就把该像素写进 buf[ry*32+rx]，
//                       同时 sum += 像素（正好 1024 个样本 -> 均值 = sum >> 10）。
//   第二遍（S_NORM）  ：逐字节读回来，写回 clamp(原值 - 均值) 的 int8 补码，
//                       然后翻 frame_toggle 通知 clk 域「一帧就绪」。
//
// 约束（★ 待核对/必须在顶层保证）：roi_w >= 32 且 roi_h >= 32。
//   因为 (rx*roi_w)>>5 只有在 roi_w>=32 时才是严格递增的；小于 32 会有两个格子
//   抢同一个源像素，采样器就永远凑不齐 1024 格。默认 ROI 是 320x240，满足。
//
// 踩过的坑：
//   * 采样器的 rx/ry 用「命中才前进」：帧流里不是每个像素都要，坐标不等就跳过；
//     所以 pix_de 必须有意义（未对齐的 pix_x/pix_y 不要给脉冲）。
//   * 没凑齐就遇到的 pix_sof（帧结束）必须把采样器清零重来，否则会把
//     两帧的像素混进同一张图。
//   * 归一化那一遍是同一拍「读+写同一地址」，靠的是组合读 + 时钟沿写；
//     如果把 buf 的读口改成了时序读，这里必须插一拍流水。
//   * buf_raddr 必须是组合输出（assign），不能写成时序：写回用的是「上一拍的
//     buf_wdata + 本拍的 buf_addr」，读地址晚一拍会让归一化整体错位一个格子
//     （表现为 buf[0] 还是原始灰度，某个值跑到 index+1）。这个坑在 cnn_tb 里抓到。
//   * frame_toggle 是唯一跨到 clk 域的信号，clk 域打两拍取边沿（见 vision_cnn_top）。
//======================================================================
`timescale 1ns / 1ps

module viz_pix_crop (
    input  wire        pclk,
    input  wire        rstn,

    // ---- 来自 ov5640_capture 的像素流 ----
    input  wire        pix_de,
    input  wire [7:0]  pix,
    input  wire [15:0] pix_x,
    input  wire [15:0] pix_y,
    input  wire        pix_sof,

    // ---- ROI（cam 域锁存后的配置）----
    input  wire [15:0] roi_x,
    input  wire [15:0] roi_y,
    input  wire [15:0] roi_w,
    input  wire [15:0] roi_h,

    // ---- 像素缓冲端口 A（cam 域）----
    output reg         buf_we,
    output reg  [9:0]  buf_addr,
    output reg  [7:0]  buf_wdata,
    output wire [9:0]  buf_raddr,   // ★ 必须组合驱动，见文件头踩过的坑
    input  wire [7:0]  buf_rdata,

    // ---- 跨域握手：整帧归一化完成后翻一次 ----
    output reg         frame_toggle
);
    localparam S_SAMPLE = 2'd0;
    localparam S_NORM   = 2'd1;
    localparam S_DONE   = 2'd2;

    reg [1:0]  state;
    reg [4:0]  rx, ry;
    reg [17:0] sum;          // 1024 x 255 = 261120 < 2^18
    reg [9:0]  nrm_i;

    // 当前格子的源坐标（严格递增建立在 roi_w/roi_h >= 32 之上）
    wire [15:0] tgt_x = roi_x + (({11'd0, rx} * roi_w) >> 5);
    wire [15:0] tgt_y = roi_y + (({11'd0, ry} * roi_h) >> 5);
    wire        hit   = pix_de && (pix_x == tgt_x) && (pix_y == tgt_y);

    // 归一化：clamp(原始灰度 - 帧均值)
    wire [7:0]  mean = sum[17:10];
    wire signed [9:0] dif = $signed({2'b00, buf_rdata}) - $signed({2'b00, mean});
    // ★ 读地址必须组合：写回用的是「上一拍的 buf_wdata + 本拍的 buf_addr」，
    //   读地址若是寄存器输出，写回就会整体错位一个格子（踩过的坑）。
    assign buf_raddr = (state == S_NORM) ? nrm_i : 10'd0;

    wire [7:0]  nrm = (dif > 10'sd127) ? 8'd127 :
                      (dif < -10'sd128) ? 8'h80 : dif[7:0];

    always @(posedge pclk) begin
        if (!rstn) begin
            state        <= S_SAMPLE;
            rx           <= 5'd0;
            ry           <= 5'd0;
            sum          <= 18'd0;
            nrm_i        <= 10'd0;
            buf_we       <= 1'b0;
            buf_addr     <= 10'd0;
            buf_wdata    <= 8'd0;
            frame_toggle <= 1'b0;
        end
        else begin
            buf_we <= 1'b0;

            case (state)
                S_SAMPLE: begin
                    if (hit) begin
                        buf_we    <= 1'b1;
                        buf_addr  <= {ry, rx};        // ry*32 + rx
                        buf_wdata <= pix;
                        sum       <= sum + {10'd0, pix};
                        if (rx == 5'd31) begin
                            rx <= 5'd0;
                            if (ry == 5'd31) begin
                                nrm_i <= 10'd0;
                                state <= S_NORM;      // 1024 格凑齐，去做均值相减
                            end
                            else ry <= ry + 5'd1;
                        end
                        else rx <= rx + 5'd1;
                    end
                    else if (pix_sof) begin
                        rx  <= 5'd0;                  // 这一帧没凑齐，重来
                        ry  <= 5'd0;
                        sum <= 18'd0;
                    end
                end

                S_NORM: begin
                    buf_addr  <= nrm_i;
                    buf_wdata <= nrm;
                    buf_we    <= 1'b1;
                    if (nrm_i == 10'd1023) begin
                        nrm_i <= 10'd0;
                        state <= S_DONE;
                    end
                    else nrm_i <= nrm_i + 10'd1;
                end

                S_DONE: begin
                    frame_toggle <= ~frame_toggle;    // 通知 clk 域：新的一帧可用
                    rx           <= 5'd0;
                    ry           <= 5'd0;
                    sum          <= 18'd0;
                    state        <= S_SAMPLE;
                end

                default: state <= S_SAMPLE;
            endcase
        end
    end
endmodule
