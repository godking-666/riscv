//======================================================================
// vision_demo_top.v -- 「物品识别」FPGA 演示顶层（不依赖 CPU 的完整闭环）
//
//   OV5640 ──DVP──► vision_top ──► LED A/B/C
//                       ▲
//   总线主控（CPU 替代件）┘──► vision_report ──► uart_tx ──► RK3568 显示
//        └──► bus_addr_dec（地址译码参考实现）
//
// 这个顶层把「除 CPU 核设计以外的全部工作」串成一条可以上板跑的链路：
//   相机配置 → 采集 → 帧内统计 → 分类 → 指示灯 + 文本上报
// 主控是一段纯硬件状态机（demo_bus_master），行为与 sw/main.c 完全等价。
//
// 两种用法：
//   (1) 【现在】没有 CPU：直接烧这个顶层，插上摄像头就能演示。功能分先拿到手。
//   (2) 【以后】CPU 就绪：把 demo_bus_master / vision_report / uart_tx 三个
//       模块从本文件里拿掉，把 CPU 的 bus_sel/bus_we/... 接到 vision_top 即可，
//       vision_top 及其以下的 RTL 一行都不用改。
//
// 复位：rstn_ext 是外部复位（低有效，接按键或上电复位）。
//       另外内部自带 1024 拍的上电定时，就算复位脚没接好也能自己跑起来。
//======================================================================
`timescale 1ns / 1ps

module vision_demo_top #(
    // clk 频率：★ 2026-10-12 板卡更换为盘古100K MINI(FBG676)，系统时钟 = 27MHz 晶振(D18) 直驱。
    // 27MHz 下分频误差：UART 115200 → DIV=(27e6+57600)/115200=234 拍/位（实际 115385Hz，+0.16%）；
    // SCCB 100kHz → DIV_CNT=67（实际 100.7kHz，+0.75%），均在容差内。
    // 若整包 SoC 统一倍频（如 108MHz），此处改为对应值并同步改 timings.sdc。
    parameter CAM_CLK_HZ          = 27000000,
    parameter CAM_SCL_HZ          = 100000,
    parameter CAM_PWDN_SETTLE_MS  = 10,
    parameter CAM_RESET_SETTLE_MS = 20,
    parameter BYTES_PER_PIX       = 2,        // 2 = RGB565
    parameter BAUD                = 115200,
    parameter CAM_CLK_KHZ         = 25000,    // 摄像头 PCLK 频率（kHz），只用于算延迟

    // ---- 上电配置（与 sw/main.c 的 vision_init 参数对应）----
    parameter [31:0] CFG_ROI_X      = 32'd0,
    parameter [31:0] CFG_ROI_Y      = 32'd0,
    parameter [31:0] CFG_ROI_W      = 32'd320,
    parameter [31:0] CFG_ROI_H      = 32'd240,
    parameter [31:0] CFG_THRESH     = 32'd128,
    parameter [31:0] CFG_MIN_PIX    = 32'd64,
    parameter [31:0] CFG_AREA_C_MAX = 32'd500
)(
    input  wire        clk,           // 板载主时钟
    input  wire        rstn_ext,      // 外部复位，低有效

    // ---- 摄像头 DVP ----
    input  wire        cam_pclk,
    input  wire        cam_vsync,
    input  wire        cam_href,
    input  wire [7:0]  cam_data,

    // ---- 摄像头控制 ----
    inout  wire        cam_sda,       // SCCB，需要外部上拉
    output wire        cam_scl,
    output wire        cam_pwdn,
    output wire        cam_reset_n,

    // ---- 上报给 RK3568 ----
    output wire        uart_txd,

    // ---- 指示灯 ----
    output wire        led_a,
    output wire        led_b,
    output wire        led_c,
    output wire        led_run,       // 每完成一帧翻转一次（心跳）
    output wire        led_ok,        // 出过至少一帧结果
    output wire        led_err        // 相机 SCCB 出现过 NACK
);
    //==================================================================
    // 复位：外部复位 + 内部上电定时，再同步释放
    //==================================================================
    reg [9:0] por_cnt = 10'd0;
    always @(posedge clk) begin
        if (por_cnt != 10'h3FF) por_cnt <= por_cnt + 10'd1;
    end
    wire por_n    = (por_cnt == 10'h3FF);
    wire rstn_raw = rstn_ext & por_n;

    reg [2:0] rst_sync;
    always @(posedge clk or negedge rstn_raw) begin
        if (!rstn_raw) rst_sync <= 3'b000;
        else           rst_sync <= {rst_sync[1:0], 1'b1};
    end
    wire rstn = rst_sync[2];

    //==================================================================
    // 总线（主控 -> 地址译码 -> vision_top）
    //==================================================================
    wire led_a_i, led_b_i, led_c_i;   // LED 输出打一拍前的内部信号（见文件尾）
    wire        bus_sel, bus_we;
    wire [31:0] bus_addr, bus_wdata, bus_rdata;
    wire [ 3:0] bus_be;

    wire sel_rom, sel_ram, sel_vision, sel_uart, sel_gpio, sel_none, cacheable;

    bus_addr_dec u_dec (
        .addr       (bus_addr),
        .sel_rom    (sel_rom),
        .sel_ram    (sel_ram),
        .sel_vision (sel_vision),
        .sel_uart   (sel_uart),
        .sel_gpio   (sel_gpio),
        .sel_none   (sel_none),
        .cacheable  (cacheable)
    );

    //==================================================================
    // 总线主控（CPU 替代件）
    //==================================================================
    wire [31:0] r_frame_no, r_cls, r_x0, r_y0, r_x1, r_y1;
    wire [31:0] r_score, r_frame_cyc, r_item_cnt;
    wire        rep_start, rep_done;
    wire        drv_stale, drv_cam_err;
    wire [31:0] drv_noframe;
    wire        irq;

    demo_bus_master #(
        .CFG_ROI_X      (CFG_ROI_X),
        .CFG_ROI_Y      (CFG_ROI_Y),
        .CFG_ROI_W      (CFG_ROI_W),
        .CFG_ROI_H      (CFG_ROI_H),
        .CFG_THRESH     (CFG_THRESH),
        .CFG_MIN_PIX    (CFG_MIN_PIX),
        .CFG_AREA_C_MAX (CFG_AREA_C_MAX)
    ) u_cpu (
        .clk        (clk),
        .rstn       (rstn),
        .bus_sel    (bus_sel),
        .bus_we     (bus_we),
        .bus_addr   (bus_addr),
        .bus_wdata  (bus_wdata),
        .bus_be     (bus_be),
        .bus_rdata  (bus_rdata),
        .rep_start  (rep_start),
        .rep_done   (rep_done),
        .o_frame_no (r_frame_no),
        .o_cls      (r_cls),
        .o_x0       (r_x0),
        .o_y0       (r_y0),
        .o_x1       (r_x1),
        .o_y1       (r_y1),
        .o_score    (r_score),
        .o_frame_cyc(r_frame_cyc),
        .o_item_cnt (r_item_cnt),
        .o_stale    (drv_stale),
        .o_cam_err  (drv_cam_err),
        .o_noframe  (drv_noframe)
    );

    //==================================================================
    // 视觉子系统（CPU 就绪后这一块原样复用）
    //==================================================================
    vision_top #(
        .CAM_CLK_HZ          (CAM_CLK_HZ),
        .CAM_SCL_HZ          (CAM_SCL_HZ),
        .CAM_PWDN_SETTLE_MS  (CAM_PWDN_SETTLE_MS),
        .CAM_RESET_SETTLE_MS (CAM_RESET_SETTLE_MS),
        .BYTES_PER_PIX       (BYTES_PER_PIX)
    ) u_vis (
        .clk         (clk),
        .rstn        (rstn),
        .cam_pclk    (cam_pclk),
        .cam_vsync   (cam_vsync),
        .cam_href    (cam_href),
        .cam_data    (cam_data),
        .cam_sda     (cam_sda),
        .cam_scl     (cam_scl),
        .cam_pwdn    (cam_pwdn),
        .cam_reset_n (cam_reset_n),
        .bus_sel     (sel_vision),
        .bus_we      (bus_we),
        .bus_addr    (bus_addr),
        .bus_wdata   (bus_wdata),
        .bus_be      (bus_be),
        .bus_rdata   (bus_rdata),
        .irq         (irq),
        .led_a       (led_a_i),
        .led_b       (led_b_i),
        .led_c       (led_c_i)
    );

    //==================================================================
    // 结果行 -> 串口
    //==================================================================
    wire [7:0] tx_data;
    wire       tx_valid, tx_ready;

    vision_report #(
        .CAM_CLK_KHZ (CAM_CLK_KHZ)
    ) u_rep (
        .clk        (clk),
        .rstn       (rstn),
        .start      (rep_start),
        .frame_no   (r_frame_no),
        .cls        (r_cls),
        .x0         (r_x0),
        .y0         (r_y0),
        .x1         (r_x1),
        .y1         (r_y1),
        .score      (r_score),
        .frame_cyc  (r_frame_cyc),
        .item_cnt   (r_item_cnt),
        .tx_data    (tx_data),
        .tx_valid   (tx_valid),
        .tx_ready   (tx_ready),
        .busy       (),
        .done       (rep_done)
    );

    uart_tx #(
        .CLK_HZ (CAM_CLK_HZ),
        .BAUD   (BAUD)
    ) u_uart (
        .clk    (clk),
        .rstn   (rstn),
        .data   (tx_data),
        .valid  (tx_valid),
        .ready  (tx_ready),
        .tx     (uart_txd)
    );

    //==================================================================
    // 指示灯
    //==================================================================
    reg heartbeat;
    reg seen_ok;
    always @(posedge clk) begin
        if (!rstn) begin
            heartbeat <= 1'b0;
            seen_ok   <= 1'b0;
        end
        else if (rep_done) begin
            heartbeat <= ~heartbeat;
            seen_ok   <= 1'b1;
        end
    end

    //==================================================================
    // LED 输出打一拍：u_cls 的 valid/cls 是组合输出，直接驱动片外 LED 时
    // IO 输出路径受 5ns output_delay 约束而时序违例（WNS -3ns）。
    // 全部 LED 统一寄存后变成 reg->pad 路径，可 pack 进 IOB 收敛。
    //==================================================================
    reg  led_a_r, led_b_r, led_c_r, led_run_r, led_ok_r, led_err_r;
    always @(posedge clk) begin
        if (!rstn) begin
            led_a_r   <= 1'b0;
            led_b_r   <= 1'b0;
            led_c_r   <= 1'b0;
            led_run_r <= 1'b0;
            led_ok_r  <= 1'b0;
            led_err_r <= 1'b0;
        end
        else begin
            led_a_r   <= led_a_i;
            led_b_r   <= led_b_i;
            led_c_r   <= led_c_i;
            led_run_r <= heartbeat;
            led_ok_r  <= seen_ok;
            led_err_r <= drv_cam_err;
        end
    end

    assign led_a   = led_a_r;
    assign led_b   = led_b_r;
    assign led_c   = led_c_r;
    assign led_run = led_run_r;
    assign led_ok  = led_ok_r;
    assign led_err = led_err_r;
endmodule
