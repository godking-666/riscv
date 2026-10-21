`timescale 1ns / 1ps

//=============================================================================
// hdmi_out.v —— 纯新增的 HDMI 输出通路（彩条里程碑）
//
// 目的：先把「HDMI 到底通不通」单独验证出来，**完全不碰 DDR3、不碰队友任何 RTL**。
//       彩条通了，再谈把 DDR3 里的相机画面接进来。
//
// 结构（全部来自厂商 5_1 ov5640 已验证设计）：
//   sys_clk(27MHz) ── clk_hdmi PLL ──┬─ pclk    = 74.25 MHz  (720p60 像素时钟)
//                                    └─ pclkx5  = 371.25 MHz (TMDS 串行时钟)
//   pclk ── sync_vg(720p60) ── hs/vs/de/x/y
//   x/y  ── 彩条 + 移动方块 ── RGB888
//   RGB888 + de/hs/vs + pclk/pclkx5 ── rgb2tmds ── tmds_clk/data 差分对
//
// 引脚（厂商 fdc 实测，TMDS 差分）：
//   tmds_clk_p/n      = N21 / N22
//   tmds_data_p/n[0]  = R25 / P25
//   tmds_data_p/n[1]  = P23 / P24
//   tmds_data_p[n][2] = N23 / N24
//
// ★ 重要：厂商 5_1 ov5640 的 Top.v 里**没有**例化 ms72xx_ctl（HDMI I2C 初始化），
//   而该例程在 200H 板上实测能出画面 —— 说明这块板的 HDMI 输出不需要 I2C 配置。
//   本模块因此也不做 I2C。若上板无显示，再加 ms72xx_ctl（RTL 已在 hdmi/ 下备好）。
//
// ★ 本模块**尚未加入 RISCV.pds**，加入前请先确认引脚与 L5 bank 供电。
//=============================================================================
module hdmi_out #(
    // 720p60 时序（sync_vg 默认值同款）
    parameter integer H_ACT   = 1280,
    parameter integer V_ACT   = 720,
    parameter integer H_TOTAL = 1650,
    parameter integer V_TOTAL = 750,
    parameter integer H_FP    = 110,
    parameter integer H_SYNC  = 40,
    parameter integer H_BP    = 220,
    parameter integer V_FP    = 5,
    parameter integer V_SYNC  = 5,
    parameter integer V_BP    = 20,
    // 1 = 内置彩条自测；0 = 由外部给的 vid_data/vid_de 接管（接 DDR 画面时用）
    parameter integer COLORBAR_ENABLE = 1
) (
    input  wire        sys_clk,       // 27 MHz（D18）
    input  wire        rst_n,         // 低有效

    // 外部视频输入（COLORBAR_ENABLE=0 时生效；本里程碑不用）
    input  wire [23:0] ext_pdata,
    input  wire        ext_de,
    input  wire        ext_hs,
    input  wire        ext_vs,

    // TMDS 差分输出
    output wire        tmds_clk_p,
    output wire        tmds_clk_n,
    output wire [2:0]  tmds_data_p,
    output wire [2:0]  tmds_data_n,

    // 状态（可接 LED 或留给上层）
    output wire        hdmi_pclk,     // 74.25 MHz
    output wire        hdmi_locked    // PLL 锁定
);

    // ---------------------------------------------------------------- 1) PLL
    wire pclk;
    wire pclkx5;
    wire locked0;

    clk_hdmi u_clk_hdmi (
        .clkout0 (pclk),
        .clkout1 (pclkx5),
        .lock    (locked0),
        .clkin1  (sys_clk)
    );

    // PLL 未锁定前保持复位；复位同步到 pclk 域
    wire rst_pclk_raw = locked0 & rst_n;
    reg  [2:0] rst_sync;
    always @(posedge pclk) begin
        rst_sync <= {rst_sync[1:0], rst_pclk_raw};
    end
    wire rst_pclk_n = rst_sync[2];

    assign hdmi_pclk   = pclk;
    assign hdmi_locked = locked0;

    // ---------------------------------------------------------------- 2) 720p60 时序
    wire        vs, hs, de, de_re;
    wire [11:0] x_act, y_act;

    sync_vg #(
        .X_BITS   (12),
        .Y_BITS   (12),
        .V_TOTAL  (V_TOTAL),
        .V_FP     (V_FP),
        .V_BP     (V_BP),
        .V_SYNC   (V_SYNC),
        .V_ACT    (V_ACT),
        .H_TOTAL  (H_TOTAL),
        .H_FP     (H_FP),
        .H_BP     (H_BP),
        .H_SYNC   (H_SYNC),
        .H_ACT    (H_ACT),
        .HV_OFFSET(12'd0)
    ) u_sync_vg (
        .clk    (pclk),
        .rstn   (rst_pclk_n),
        .vs_out (vs),
        .hs_out (hs),
        .de_out (de),
        .de_re  (de_re),
        .x_act  (x_act),
        .y_act  (y_act)
    );

    // ---------------------------------------------------------------- 3) 彩条 + 移动方块
    // 8 条竖彩条（每条约 160 像素），加一个随帧左右移动的白色方块，
    // 用来证明画面是「活的」而不是 PLL 锁死后卡住的静态图。
    reg [23:0] bar_rgb;
    always @* begin
        if      (x_act < 12'd160)  bar_rgb = 24'hFF_FF_FF;  // 白
        else if (x_act < 12'd320)  bar_rgb = 24'hFF_FF_00;  // 黄
        else if (x_act < 12'd480)  bar_rgb = 24'h00_FF_FF;  // 青
        else if (x_act < 12'd640)  bar_rgb = 24'h00_FF_00;  // 绿
        else if (x_act < 12'd800)  bar_rgb = 24'hFF_00_FF;  // 品红
        else if (x_act < 12'd960)  bar_rgb = 24'hFF_00_00;  // 红
        else if (x_act < 12'd1120) bar_rgb = 24'h00_00_FF;  // 蓝
        else                       bar_rgb = 24'h00_00_00;  // 黑
    end

    // 帧计数：de_re 每行有效时打一拍，用它驱动移动方块
    reg [31:0] pix_cnt;
    always @(posedge pclk) begin
        if (!rst_pclk_n)
            pix_cnt <= 32'd0;
        else if (de)
            pix_cnt <= pix_cnt + 32'd1;
    end

    // 方块：64×64，水平位置随 pix_cnt 缓慢右移并回绕
    wire [11:0] sq_x = pix_cnt[22:11];             // 0..2047 缓慢增长
    wire        in_sq_x = (x_act >= sq_x) && (x_act < (sq_x + 12'd64));
    wire        in_sq_y = (y_act >= 12'd328) && (y_act < 12'd392);
    wire        marker  = in_sq_x && in_sq_y;

    // 顶部 4 行做一条白带，方便一眼看出 y 方向是否正常
    wire top_band = (y_act < 12'd4);

    wire [23:0] bar_with_marker = marker ? 24'h00_00_00 :
                                  top_band ? 24'hFF_FF_FF : bar_rgb;

    // ---------------------------------------------------------------- 4) 视频数据选择
    wire [23:0] vid_pdata = (COLORBAR_ENABLE != 0) ? bar_with_marker : ext_pdata;
    wire        vid_pvde  = (COLORBAR_ENABLE != 0) ? de               : ext_de;
    wire        vid_phsync= (COLORBAR_ENABLE != 0) ? hs               : ext_hs;
    wire        vid_pvsync= (COLORBAR_ENABLE != 0) ? vs               : ext_vs;

    // ---------------------------------------------------------------- 5) TMDS 输出
    // ★ rgb2tmds 内部 OSERDES 跑在 371.33 MHz(pclkx5)，其复位脚必须用**异步**复位。
    //   若用 pclk(74.25MHz) 同步过的复位去驱动，会产生跨时钟域 Recovery 违例
    //   （实测 -2.717 ns）。厂商 Top.v 正是用 rst_n = locked0 & rst_in 这种异步复位。
    wire rst_oserdes_n = rst_pclk_raw;

    rgb2tmds u_rgb2tmds (
        .tmds_clk_p  (tmds_clk_p),
        .tmds_clk_n  (tmds_clk_n),
        .tmds_data_p (tmds_data_p),
        .tmds_data_n (tmds_data_n),
        .rstn        (rst_oserdes_n),
        .vid_pdata   (vid_pdata),
        .vid_pvde    (vid_pvde),
        .vid_phsync  (vid_phsync),
        .vid_pvsync  (vid_pvsync),
        .pixelclk    (pclk),
        .serialclk   (pclkx5)
    );

endmodule
