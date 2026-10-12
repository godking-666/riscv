`timescale 1ns / 1ps

// RK3568_MES2L100H / PG2L100H-6IFBG484 physical board boundary.
// Current generated DDR IP: 125 MHz reference, 750 Mbps, core_clk=93.75 MHz.
module board_top #(
    parameter [31:0] RESET_PC = 32'h0000_0000,
    parameter [31:0] DDR_BASE = 32'h4000_0000,
    parameter integer CORE_CLK_HZ = 93_750_000,
    parameter integer SELFTEST_TIMEOUT_CYCLES = CORE_CLK_HZ * 5,
    parameter integer KEY_DEBOUNCE_CYCLES = 2_500_000 // 20 ms at 125 MHz
) (
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
    inout  wire [ 1:0] mem_dqs,
    inout  wire [ 1:0] mem_dqs_n,
    inout  wire [15:0] mem_dq,
    output wire [ 1:0] mem_dm,
    output wire        uart_tx,
    input  wire        uart_rx
);
    wire ddr_ref_clk;
    wire key_ref_clk;
    wire key_resetn;
    wire core_clk;
    wire ddr_init_done;
    wire soc_resetn;
    // ================================================================
    // DebugCore / Fabric Inserter 观测点
    // ----------------------------------------------------------------
    // 这 5 根线在 board_top 顶层没有负载，ADS 综合会把它们整条链优化掉，
    // 导致 Fabric Inserter 找不到可插资源、生成的 .fic 为空、
    // dev_map 报 E: Flow-0037: Fic file is empty.
    // 加 PAP_MARK_DEBUG 后 ADS 会保留这些 net 并保持 RTL 原名。
    // 语法依据：Fabric Inserter 用户手册 4.1「在 RTL 中标记信号」。
    // ================================================================
    wire [31:0] debug_wb_pc        /* synthesis PAP_MARK_DEBUG="1" */;
    wire [31:0] debug_inst         /* synthesis PAP_MARK_DEBUG="2" */;
    wire [ 3:0] debug_wb_rf_we     /* synthesis PAP_MARK_DEBUG="3" */;
    wire [ 4:0] debug_wb_rf_wnum   /* synthesis PAP_MARK_DEBUG="4" */;
    wire [31:0] debug_wb_rf_wdata  /* synthesis PAP_MARK_DEBUG="5" */;

    // 若 Fabric Inserter 的 Clock 下拉框里找不到 core_clk，把下面两行注释打开，
    // 用"精确标记"直接指定 DebugCore0 的 clock / reset 通道
    // （t=trigger d=data c=clock r=reset）：
    //   wire core_clk    /* synthesis PAP_MARK_DEBUG="<0/c0/0>" */;
    //   wire soc_resetn  /* synthesis PAP_MARK_DEBUG="<0/r0/0>" */;

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
        .RESET_PC(RESET_PC), .DDR_BASE(DDR_BASE),
        .CORE_CLK_HZ(CORE_CLK_HZ),
        .SELFTEST_TIMEOUT_CYCLES(SELFTEST_TIMEOUT_CYCLES)
    ) u_soc (
        .ddr_ref_clk(ddr_ref_clk), .resetn(key_resetn),
        .uart_tx(uart_tx), .uart_rx(uart_rx),
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
        .mem_dq(mem_dq), .mem_dqs(mem_dqs), .mem_dqs_n(mem_dqs_n)
    );
endmodule
