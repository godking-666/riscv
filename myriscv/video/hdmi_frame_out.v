`timescale 1ns/1ps
//=============================================================================
// hdmi_frame_out.v —— 从异步 FIFO 取像素、转 RGB888、送 TMDS（pixel_clk 域）
//
// 结构：clk_hdmi PLL(27M → 74.25M / 371.25M) + sync_vg(720p60)
//       + 16 像素移位寄存器（每 16 像素取一个 256bit 字）
//       + RGB565→RGB888 + rgb2tmds
//
// ★ 关于 sync_vg 的 de_re（踩过的坑，务必注意）：
//   `de_re` 不是"行起点脉冲"！它是**整行有效电平**，只是比 de_out 早 2 拍
//   （源码里 h_count 阈值各差 2）。若拿它当"每行取一个字"的使能，
//   会导致整行 1280 拍每拍都取 FIFO → 同一个 16 像素字被反复播放、
//   FIFO 瞬间抽干、画面变成规则平铺的瓦片。
//   本模块因此**不用 de_re**，改由 de 的上升沿自己产生 1 拍 line_start。
//
// ★ rgb2tmds 的复位用**异步**复位（rst_oserdes_n = locked0 & rst_n），
//   避免 74.25MHz 同步复位驱动 371.33MHz OSERDES 复位脚造成 Recovery 违例。
//=============================================================================
module hdmi_frame_out (
    input  wire         sys_clk,       // 27 MHz（D18）
    input  wire         rst_n,         // 低有效

    // ---- 异步 FIFO 读侧（pixel_clk 域）----
    output wire         fifo_rd_en,
    input  wire [255:0] fifo_rd_data,
    input  wire         fifo_rd_empty,

    // ---- TMDS 输出 ----
    output wire         tmds_clk_p,
    output wire         tmds_clk_n,
    output wire [2:0]   tmds_data_p,
    output wire [2:0]   tmds_data_n,

    output wire         hdmi_pclk,
    output wire         hdmi_locked,
    // 帧起点脉冲（pixel_clk 域，1 拍）：由 soc_ddr3_top 同步到 core_clk 后
    // 用来把显示读侧的帧边界对齐到 vs
    output wire         frame_start,
    // 识别类别（core_clk 域，异步）：OSD 在画面左上角叠加显示
    input  wire [3:0]   osd_class
);
    // ---------------- 1) PLL ----------------
    wire pclk;
    wire pclkx5;
    wire locked0;
    clk_hdmi u_clk_hdmi (
        .clkout0 (pclk),
        .clkout1 (pclkx5),
        .lock    (locked0),
        .clkin1  (sys_clk)
    );

    wire rst_pclk_raw = locked0 & rst_n;
    reg [2:0] rst_sync;
    always @(posedge pclk) begin
        rst_sync <= {rst_sync[1:0], rst_pclk_raw};
    end
    wire rst_pclk_n = rst_sync[2];
    // ★ OSERDES 复位必须用异步复位（见模块头注释）
    wire rst_oserdes_n = rst_pclk_raw;

    assign hdmi_pclk   = pclk;
    assign hdmi_locked = locked0;

    // ---------------- 2) 720p60 时序 ----------------
    wire        vs, hs, de;
    wire [11:0] x_act, y_act;
    sync_vg #(
        .X_BITS(12), .Y_BITS(12),
        .V_TOTAL(750), .V_FP(5), .V_BP(20), .V_SYNC(5), .V_ACT(720),
        .H_TOTAL(1650), .H_FP(110), .H_BP(220), .H_SYNC(40), .H_ACT(1280),
        .HV_OFFSET(12'd0)
    ) u_sync_vg (
        .clk(pclk), .rstn(rst_pclk_n),
        .vs_out(vs), .hs_out(hs), .de_out(de), .de_re(),
        .x_act(x_act), .y_act(y_act)
    );

    // ---------------- 3) 行起点 / 帧起点（真正的 1 拍脉冲）----------------
    reg de_d;
    always @(posedge pclk or negedge rst_pclk_n) begin
        if (!rst_pclk_n) de_d <= 1'b0;
        else             de_d <= de;
    end
    wire line_start = de & ~de_d;               // 每行第一个有效像素：1 拍

    // ★ 帧起点用 **vs 上升沿**（垂直消隐开始），不用"第一个有效行的 de 上升沿"。
    //   原因（实测）：读侧和像素侧若同时起步，FIFO 此刻是空的，前若干像素
    //   取不到数据就输出黑；缺多少取决于 DDR 仲裁延迟，于是**屏幕最左边缘**
    //   每帧闪一下。实测时间差分在 x≈130~180 处达 8.6，是画面中部 (0.83) 的
    //   10 倍，而且每隔约 0.7~1 s 出现一次 24~31 的突跳。
    //   改到 vs 后，读侧有整个垂直消隐期
    //   （V_FP+V_SYNC+V_BP = 5+5+20 = 30 行 × 1650 pclk ≈ 667 us）
    //   把 FIFO 预填满（almost_full=48 字 = 768 像素），有效像素开始时已就绪。
    reg vs_d;
    always @(posedge pclk or negedge rst_pclk_n) begin
        if (!rst_pclk_n) vs_d <= 1'b0;
        else             vs_d <= vs;
    end
    reg frame_start_r;
    always @(posedge pclk or negedge rst_pclk_n) begin
        if (!rst_pclk_n) frame_start_r <= 1'b0;
        else             frame_start_r <= vs & ~vs_d;   // vs 上升沿 = 帧开始
    end
    assign frame_start = frame_start_r;

    // ---------------- 4) 16 像素移位寄存器 ----------------
    // 每行 1280 像素 = 80 个字（80 × 16）。正常情况下一行正好消耗 80 个字，
    // cnt 在行末自然回到 0；行首的 line_start 只是"保险"，确保即使上一行
    // 因 FIFO 下溢停在中间，这一行也从 cnt=0 重新对齐。
    reg [255:0] shift_reg;
    reg [3:0]   cnt;
    wire refill = (cnt == 4'd0);
    wire take_word = de && (line_start || refill) && !fifo_rd_empty;
    assign fifo_rd_en = take_word;

    always @(posedge pclk or negedge rst_pclk_n) begin
        if (!rst_pclk_n) begin
            shift_reg <= 256'd0;
            cnt       <= 4'd0;
        end else if (de) begin
            if (line_start || refill) begin
                if (!fifo_rd_empty) begin
                    shift_reg <= fifo_rd_data;   // 取一个新 256bit 字（16 像素）
                    cnt       <= 4'd15;
                end else begin
                    cnt <= 4'd0;                  // 空：停在 0，下一拍再试
                end
            end else begin
                shift_reg <= shift_reg << 16;
                cnt       <= cnt - 4'd1;
            end
        end
    end

    wire [15:0] pix565 = shift_reg[255:240];

    // ---------------- 5) RGB565 -> RGB888 ----------------
    // RGB565: R[4:0]=[15:11], G[5:0]=[10:5], B[4:0]=[4:0]
    wire [7:0] r8 = {pix565[15:11], pix565[15:13]};
    wire [7:0] g8 = {pix565[10:5],  pix565[10:9] };
    wire [7:0] b8 = {pix565[4:0],   pix565[4:2]  };
    wire [23:0] rgb888 = {r8, g8, b8};

    // ---------------- 5b) OSD 叠加（左上角显示识别类别）----------------
    // 只替换像素值，不影响时序：x_act/y_act 来自 sync_vg，判定方块位置。
    wire [23:0] rgb_osd;
    osd_overlay u_osd (
        .pclk    (pclk),
        .rst_n   (rst_pclk_n),
        .rgb_in  (rgb888),
        .de      (de),
        .x_act   (x_act),
        .y_act   (y_act),
        .cls     (osd_class),
        .rgb_out (rgb_osd)
    );

    // 空时输出黑，避免残影/垃圾
    wire [23:0] vid_pdata = (de && fifo_rd_empty) ? 24'h000000 : rgb_osd;

    // ---------------- 6) TMDS ----------------
    rgb2tmds u_rgb2tmds (
        .tmds_clk_p  (tmds_clk_p),
        .tmds_clk_n  (tmds_clk_n),
        .tmds_data_p (tmds_data_p),
        .tmds_data_n (tmds_data_n),
        .rstn        (rst_oserdes_n),
        .vid_pdata   (vid_pdata),
        .vid_pvde    (de),
        .vid_phsync  (hs),
        .vid_pvsync  (vs),
        .pixelclk    (pclk),
        .serialclk   (pclkx5)
    );

endmodule
