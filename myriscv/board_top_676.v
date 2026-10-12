`timescale 1ns / 1ps

//=============================================================================
// board_top_676.v -- 盘古 676 系列 MINI-200H 板级顶层（PG2L200H-6IFBG676）
//
// 板卡：MES2L676-200HP-MINI（小眼睛科技 / 逻辑矩阵）
// 参考：《盘古MINI系列开发板硬件指导手册 V1.3》+ mini-base管脚映射.xlsx
//
// 与旧板（PG2L100H-6IFBG484）的根本差异：
//   * 系统时钟：旧板 125MHz 差分(DDR 参考) -> core_clk 93.75MHz
//               新板 **27MHz 单端**（FPGA_GCLK_27M = D18），需 GPLL 倍频
//   * 封装 FBG484 -> FBG676，引脚全部不同
//   * 复位/串口/LED/按键引脚全部不同（见下方注释与 .fdc）
//
// ★ 时钟策略（分两步走，降低风险）：
//   USE_PLL=0 : core_clk = 27MHz 直驱 —— 不需要生成任何 IP，**上电即可跑**
//               （UART 分频 27e6/115200 = 234.4 -> 234，误差 0.16%，可用）
//   USE_PLL=1 : core_clk = PLL 输出 108MHz（27MHz x 4）—— 需先用 IP Compiler
//               生成一个名为 sys_pll 的 PLL IP（27MHz 输入 / 108MHz 输出）
//
//   先按 USE_PLL=0 把全流程和上板打通（G1 闸门），再切 USE_PLL=1 冲 108MHz。
//   ★ 千万不要一上来就用 PLL：PLL 参数配错会导致完全无时钟，连串口都出不来，
//     届时无法判断是 PLL 错、复位错还是 CPU 错。
//
// 本轮范围（G1）：CPU + 片内 ROM/RAM + MMIO + UART + GPIO，**不含 DDR3、不含视觉**。
//   DDR3 与 vision_top 分别在 D3 / D2 接入。
//=============================================================================
module board_top_676 #(
    // CPU 复位地址（片内 ROM 基址为 0）
    parameter [31:0] RESET_PC = 32'h0000_0000,
    // core_clk 实际频率：必须与实际时钟一致，否则 UART/SCCB 分频错 -> 串口乱码
    parameter integer CORE_CLK_HZ = 27_000_000,
    // 0 = 27MHz 直驱；1 = 走 sys_pll 到 108MHz
    parameter integer USE_PLL = 0,
    // GPIO 位宽（低 5 位接 LED，低 5 位读按键）
    parameter integer GPIO_WIDTH = 8,
    // 板载 27MHz 晶振频率
    parameter integer XTAL_HZ = 27_000_000
) (
    // ---- 时钟与复位 ----
    input  wire                     clk_27m,      // D18  FPGA_GCLK_27M
    input  wire                     rstn_ext,     // C22  KEY0（低有效）

    // ---- 串口（CP2102 -> Type-C）----
    output wire                     uart_txd,     // C24
    input  wire                     uart_rxd,     // B24

    // ---- 板载 LED（高电平亮）----
    output wire [4:0]               led,          // A20 C18 C19 E18 A17

    // ---- 板载按键（低有效）----
    input  wire [3:0]               key,          // C23 B22 A22 B20 (KEY1..KEY4)

    // ---- OV5640 摄像头（CAM1 单路；J17 排针 pin-pin 直插 J10 扩展口）----
    // 模组自带 24MHz 晶振，FPGA 不供 XCLK；J17 无 PWDN 脚，故不引出 cam_pwdn。
    input  wire                     cam_pclk,     // L22
    input  wire                     cam_vsync,    // L23
    input  wire                     cam_href,     // T25
    input  wire [7:0]               cam_data,     // M24 R22 K26 K25 M25 N19 T24 R21
    inout  wire                     cam_sda,      // R20（SCCB 开漏）
    output wire                     cam_scl,      // P19
    output wire                     cam_reset_n   // T22（低有效，接模组 REST）
);

    // ---------------------------------------------------------------- 时钟
    wire core_clk;
    wire pll_lock;

    // sys_pll：由 IP Compiler 生成（Pango PLL，27MHz 输入 / 108MHz 输出）。
    // 未生成时 USE_PLL 必须保持 0，否则综合会报模块缺失。
    generate
        if (USE_PLL != 0) begin : g_pll
            sys_pll u_sys_pll (
                .clkin  (clk_27m),
                .clkout (core_clk),
                .lock   (pll_lock)
            );
        end else begin : g_bypass
            assign core_clk = clk_27m;
            assign pll_lock = 1'b1;     // 直驱时视为已锁定
        end
    endgenerate

    // pll_lock 已通过 LED4（hw_status）可视，不再单独引出端口，
    // 避免出现未约束的顶层输出端口导致 PDS 报错。
    // ---------------------------------------------------------------- 复位
    // 上电 POR + 外部按键复位 + PLL 未锁定，全部在 core_clk 域同步释放。
    // ★ 消抖/同步必须用 core_clk 之外也仍在跑的时钟源；直驱时 clk_27m 就是 core_clk，
    //   走 PLL 时 clk_27m 在 PLL 锁定前也在跑（晶振是外部有源），故两者都安全。
    reg [3:0] por_cnt = 4'd0;
    reg [2:0] rstn_sync = 3'b000;
    wire      rstn_raw = rstn_ext & pll_lock;
    wire      por_done = &por_cnt;

    always @(posedge core_clk) begin
        if (!por_done)
            por_cnt <= por_cnt + 4'd1;
    end

    always @(posedge core_clk) begin
        rstn_sync <= {rstn_sync[1:0], (rstn_raw & por_done)};
    end
    wire core_resetn = rstn_sync[2];

    // ---------------------------------------------------------------- CPU + SoC
    wire [ 1:0] selftest_status;
    wire        uart_irq, gpio_irq;
    wire        vis_irq;                       // 源自 vision_top.irq
    wire        vis_led_a, vis_led_b, vis_led_c;
    wire [GPIO_WIDTH-1:0] gpio_out, gpio_in, gpio_dir;
    wire [31:0] debug_wb_pc, debug_inst, debug_wb_rf_wdata;
    wire [ 3:0] debug_wb_rf_we;
    wire [ 4:0] debug_wb_rf_wnum;

    // 中断：UART RX（soc_top 内部已 OR）+ GPIO + 视觉，三路合起来送 CPU external。
    wire irq_ext = uart_irq | gpio_irq | vis_irq;

    // DDR3 本轮不接：DDR 用户口全部悬空/常量，ENABLE_DDR=0。
    // （D3 接入 200H 的 DDR3 IP 时再替换这一段）
    soc_top #(
        .RESET_PC          (RESET_PC),
        .ENABLE_DDR        (0),
        .UART_CLK_HZ       (CORE_CLK_HZ),
        .PERF_ENABLE       (1),
        .PERF_AUTO_ARM     (1),
        .GPIO_WIDTH        (GPIO_WIDTH),
        .ENABLE_GPIO       (1),
        .GPIO_BASE         (32'h1000_2000),
        .ENABLE_VISION     (1),
        .VISION_BASE       (32'h8000_0000),
        // ★ 必须等于实际 core_clk（vision_top 默认值是旧板 93.75MHz，传错 = 串口乱码）
        .CAM_CLK_HZ        (CORE_CLK_HZ),
        .CAM_SCL_HZ        (100_000)
    ) u_soc (
        .clk                (core_clk),
        .resetn             (core_resetn),
        .irq_external       (irq_ext),
        .irq_software       (1'b0),
        .irq_timer          (1'b0),
        .debug_wb_pc        (debug_wb_pc),
        .debug_wb_rf_we     (debug_wb_rf_we),
        .debug_wb_rf_wnum   (debug_wb_rf_wnum),
        .debug_wb_rf_wdata  (debug_wb_rf_wdata),
        .debug_inst         (debug_inst),

        // DDR3 本轮不用：DDR 初始化视为已完成，用户口悬空
        .ddr_init_done      (1'b1),
        .ddr_axi_awaddr     (),
        .ddr_axi_awuser_ap  (),
        .ddr_axi_awuser_id  (),
        .ddr_axi_awlen      (),
        .ddr_axi_awready    (1'b0),
        .ddr_axi_awvalid    (),
        .ddr_axi_wdata      (),
        .ddr_axi_wstrb      (),
        .ddr_axi_wready     (1'b0),
        .ddr_axi_wusero_id  (1'b0),
        .ddr_axi_wusero_last(1'b0),
        .ddr_axi_araddr     (),
        .ddr_axi_aruser_ap  (),
        .ddr_axi_aruser_id  (),
        .ddr_axi_arlen      (),
        .ddr_axi_arready    (1'b0),
        .ddr_axi_arvalid    (),
        .ddr_axi_rdata      (128'b0),
        .ddr_axi_rid        (4'b0),
        .ddr_axi_rlast      (1'b0),
        .ddr_axi_rvalid     (1'b0),

        .selftest_status    (selftest_status),
        .uart_rx            (uart_rxd),
        .uart_tx            (uart_txd),

        // 通用 GPIO（基础任务 3）
        .gpio_in            (gpio_in),
        .gpio_out           (gpio_out),
        .gpio_dir           (gpio_dir),
        .gpio_irq           (gpio_irq),

        // ---- OV5640 摄像头 / 视觉子系统 ----
        .cam_pclk           (cam_pclk),
        .cam_vsync          (cam_vsync),
        .cam_href           (cam_href),
        .cam_data           (cam_data),
        .cam_sda            (cam_sda),
        .cam_scl            (cam_scl),
        .cam_pwdn           (),
        .cam_reset_n        (cam_reset_n),
        .vis_irq            (vis_irq),
        .vis_led_a          (vis_led_a),
        .vis_led_b          (vis_led_b),
        .vis_led_c          (vis_led_c)
    );

    // ★ 注意：soc_top 内部已把 uart_mmio.uart_irq 与 irq_external 做过 OR，
    //   所以这里不必（也不能）再引出 UART 中断，本线恒 0。
    assign uart_irq = 1'b0;

    // ---------------------------------------------------------------- GPIO 引脚映射
    // gpio_in : [3:0] = KEY1..KEY4（低有效，取反成"按下=1"给软件更直观）
    //           [4]   = KEY0 状态（复位键，同时兼作软件可读的按键）
    //           [7:5] = 0
    assign gpio_in = {{(GPIO_WIDTH-5){1'b0}}, rstn_ext, ~key};

    // ---------------------------------------------------------------- LED 与状态
    // 心跳：core_clk / 2^23 -> 27MHz 时约 3.2Hz、54MHz 时约 6.4Hz（肉眼可见闪烁）
    reg [23:0] heartbeat = 24'd0;
    always @(posedge core_clk) begin
        if (!core_resetn)
            heartbeat <= 24'd0;
        else
            heartbeat <= heartbeat + 24'd1;
    end

    // LED 归属：gpio_dir[i]=1 的位由 GPIO 驱动，其余位显示硬件/视觉状态。
    // 这样既满足"基础任务要 GPIO"，又不丢上电自检与分类结果的可视信号。
    //   LED4 = 心跳（一眼看出 CPU 在跑）
    //   LED3 = C 类物品     LED2 = B 类物品     LED1 = A 类物品（视觉侧 led_a/b/c）
    //   LED0 = 复位已释放（上电/按键后常亮 = SoC 起来了）
    wire [4:0] hw_status = {heartbeat[23],   // LED4 心跳
                            vis_led_c,       // LED3 C 类
                            vis_led_b,       // LED2 B 类
                            vis_led_a,       // LED1 A 类
                            core_resetn};    // LED0 复位已释放
    assign led = (gpio_out[4:0] & gpio_dir[4:0]) |
                 (hw_status    & ~gpio_dir[4:0]);

endmodule
