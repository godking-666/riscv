`timescale 1ns / 1ps

// Pango MINI-(200H) / PG2L200H-6IFBG676 physical board boundary.
// Current generated DDR IP: 125 MHz reference, 750 Mbps, core_clk=93.75 MHz.
module board_top #(
    parameter [31:0] RESET_PC = 32'h0000_0000,
    parameter [31:0] DDR_BASE = 32'h4000_0000,
    parameter integer CORE_CLK_HZ = 93_750_000,
    parameter integer SELFTEST_TIMEOUT_CYCLES = CORE_CLK_HZ * 5,
    parameter integer KEY_DEBOUNCE_CYCLES = 2_500_000 // 20 ms at 125 MHz
) (
    input wire camera_pclk, camera_vsync, camera_href,
    input wire [7:0] camera_data,
    inout wire camera_scl, camera_sda,
    output wire camera_resetn,
    input  wire        ddr_ref_clk_p,
    input  wire        ddr_ref_clk_n,
    input  wire        resetn,
    output wire        led_clk_alive,
    output wire        led_ddr_ready,
    output wire        led_selftest,
    output wire        mem_cs_n,
    output wire        mem_rst_n,
    output wire        mem_ck,
    output wire        mem_ck_n,
    output wire        mem_cke,
    output wire        mem_ras_n,
    output wire        mem_cas_n,
    output wire        mem_we_n,
    output wire        mem_odt,
    output wire [14:0] mem_a,
    output wire [ 2:0] mem_ba,
    inout  wire [ 3:0] mem_dqs,
    inout  wire [ 3:0] mem_dqs_n,
    inout  wire [31:0] mem_dq,
    output wire [ 3:0] mem_dm,
    output wire        uart_tx,
    input  wire        uart_rx,
    // 通用 GPIO（基础任务）：3 盏空余 LED（C18/E18/A17）+ 4 个空余按键（C23/B22/A22/B20）
    output wire [1:0]  gpio_led,
    input  wire [3:0]  gpio_key,
    // HDMI 输出（彩条里程碑）：27MHz 晶振 + 8 根 TMDS 差分
    // 引脚取自厂商 5_1 ov5640 的 fdc（已实板验证）
    input  wire        sys_clk,       // D18  27 MHz
    output wire        tmds_clk_p,    // N21
    output wire        tmds_clk_n,    // N22
    output wire [2:0]  tmds_data_p,   // R25 / P23 / N23
    output wire [2:0]  tmds_data_n    // P25 / P24 / N24
);
    wire ddr_ref_clk;
    wire key_ref_clk;
    wire key_resetn;
    wire camera_pixel_clk;
    wire core_clk;
    wire ddr_init_done;
    wire soc_resetn;
    wire [7:0] gpio_in, gpio_out, gpio_dir;
    wire [1:0] dbg_led;   // 临时调试观测
    wire       gpio_irq;
    wire [31:0] debug_wb_pc;
    wire [31:0] debug_inst;
    wire [ 3:0] debug_wb_rf_we;
    wire [ 4:0] debug_wb_rf_wnum;
    wire [31:0] debug_wb_rf_wdata;

    // Same port-only instantiation as the generated DDR example test_ddr.v.
    // Electrical standard/termination must be checked against the board
    // oscillator and bank supply before bitstream generation.
    GTP_INBUFDS u_ddr_ref_clk_buf (
        .O(ddr_ref_clk), .I(ddr_ref_clk_p), .IB(ddr_ref_clk_n)
    );

    // Keep the counter clock on a global clock route. Port names come from
    // the installed Pango GTP_CLKBUFG primitive (CLKIN / CLKOUT).
    GTP_CLKBUFG u_key_ref_clk_buf (
        .CLKIN(ddr_ref_clk), .CLKOUT(key_ref_clk)
    );

    GTP_CLKBUFG u_camera_pclk_buf (
        .CLKIN(camera_pclk), .CLKOUT(camera_pixel_clk)
    );

    // KEY0 asserts reset immediately. Release must remain stable for 20 ms.
    // The input reference keeps running while the DDR PLL/core is in reset.
    reset_button_debounce #(
        .STABLE_CYCLES(KEY_DEBOUNCE_CYCLES)
    ) u_key0_debounce (
        .clk(key_ref_clk), .keyn(resetn), .resetn_out(key_resetn)
    );

    // Final SoC reset release is still synchronized to core_clk and gated by
    // DDR initialization/PLL lock inside soc_ddr3_top.
    soc_ddr3_top #(
        .ENABLE_CAMERA(1), .ENABLE_PREPROCESS(1), .ENABLE_CNN(1),
        .ENABLE_GPIO(1),
        .CAMERA_COLORBAR_ENABLE(0), // Live scene: PRE-ISP test pattern disabled.
        .CAMERA_DVP_TEST_ENABLE(0), // Live scene: DVP test generator disabled.
        .RESET_PC(RESET_PC), .DDR_BASE(DDR_BASE),
        .CORE_CLK_HZ(CORE_CLK_HZ),
        .SELFTEST_TIMEOUT_CYCLES(SELFTEST_TIMEOUT_CYCLES)
    ) u_soc (
        .camera_pclk(camera_pixel_clk), .camera_vsync(camera_vsync), .camera_href(camera_href),
        .camera_data(camera_data), .camera_scl(camera_scl), .camera_sda(camera_sda),
        .camera_resetn(camera_resetn),

        .ddr_ref_clk(ddr_ref_clk), .resetn(key_resetn),
        .uart_tx(uart_tx), .uart_rx(uart_rx),
        .gpio_in(gpio_in), .gpio_out(gpio_out),
        .gpio_dir(gpio_dir), .gpio_irq(gpio_irq),
        .irq_external(1'b0), .irq_software(1'b0), .irq_timer(1'b0),
        .core_clk(core_clk), .ddr_init_done(ddr_init_done),
        .soc_resetn(soc_resetn),
        .debug_wb_pc(debug_wb_pc), .debug_inst(debug_inst),
        .debug_wb_rf_we(debug_wb_rf_we),
        .debug_wb_rf_wnum(debug_wb_rf_wnum),
        .debug_wb_rf_wdata(debug_wb_rf_wdata),
        .led_clk_alive(led_clk_alive), .led_ddr_ready(led_ddr_ready),
        .led_selftest(led_selftest),
        .mem_cs_n(mem_cs_n), .mem_rst_n(mem_rst_n),
        .mem_ck(mem_ck), .mem_ck_n(mem_ck_n), .mem_cke(mem_cke),
        .mem_ras_n(mem_ras_n), .mem_cas_n(mem_cas_n),
        .mem_we_n(mem_we_n), .mem_odt(mem_odt),
        .mem_a(mem_a), .mem_ba(mem_ba), .mem_dm(mem_dm),
        .mem_dq(mem_dq), .mem_dqs(mem_dqs), .mem_dqs_n(mem_dqs_n),
        .sys_clk(sys_clk),
        .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n),
        .tmds_data_p(tmds_data_p), .tmds_data_n(tmds_data_n),
        .dbg_led(dbg_led)
    );

    // ---- 通用 GPIO 引脚映射 ----
    // 输入：KEY1..KEY4（低有效），取反成「按下=1」给软件；高位补 0
    assign gpio_in  = {4'b0000, ~gpio_key};
    // 输出：只有 DIR=1 的位才驱动 LED（复位后 DIR=0 -> LED 熄灭，不会漂）
    // ---- 临时：E18/A17 改为显示通路观测 LED ----
    //   E18 = 相机是否写过帧（亮=写过，说明相机已 arm）
    //   A17 = 显示 FIFO 是否为空（亮=显示端没数据）
    // 恢复 GPIO 功能时把下面一行换回：
    //     assign gpio_led = gpio_dir[1:0] & gpio_out[1:0];
    assign gpio_led = dbg_led;

    // ---- HDMI 显示输出：已在 soc_ddr3_top 内走「DDR3 帧 → 异步 FIFO → HDMI」通路 ----
endmodule
