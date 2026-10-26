`timescale 1ns / 1ps
// ============================================================================
// board_top_ooo_ddr  --  MINI-(200H) / PG2L200H-6IFBG676, DDR build of soc_ooo
//   boot TCM (0x0) + 2-way I$/D$ + DDR3 at 0x4000_0000.
// Same ports as the existing board_top and the DDR IP at u_soc.u_ddr3, so the
// existing constraint file (pins + DDR PHY clocks/locations) applies as is.
// CPU_CLK_SEL 0: CPU on the DDR IP core_clk (93.75 MHz)
//             1: CPU on the 125 MHz board reference clock (default; the existing
//                constraint file already makes ddr_ref_clk asynchronous to the
//                DDR clocks, and ooo_ddr_port handles the crossing)
//             2: CPU on clk_cpu PLL output clkout0 (default; PDS IP "clk_cpu",
//                CLKIN1 125 MHz, CLKOUT0 135 MHz, no output buffer).  The PLL is
//                instantiated here as u_cpu_pll so the constraint file can name
//                its output (create_generated_clock ... u_cpu_pll/clkout0); the
//                CPU clock is asynchronous to every DDR clock (fdc/ooo_ddr.fdc).
// CPU_CLK_HZ must equal the real CPU clock (UART divisor, CoreMark timer), and
// the program image must be built for the same frequency.
// ============================================================================
module board_top_ooo_ddr #(
    parameter integer CPU_CLK_SEL = 2,
    parameter integer CPU_CLK_HZ  = 135_000_000,
    parameter         INIT_EVEN   = "D:/riscv/ooo_riscv_ddr3/source/ooo_img/ddr135_perf/tcm_even.dat",
    parameter         INIT_ODD    = "D:/riscv/ooo_riscv_ddr3/source/ooo_img/ddr135_perf/tcm_odd.dat",
    parameter integer TCM_BYTES   = 65536,
    parameter integer KEY_DEBOUNCE_CYCLES = 2_500_000      // 20 ms at 125 MHz
) (
    input  wire        camera_pclk, camera_vsync, camera_href,
    input  wire [7:0]  camera_data,
    inout  wire        camera_scl, camera_sda,
    output wire        camera_resetn,
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
    input  wire        uart_rx
);
    // camera connector unused
    assign camera_resetn = 1'b0;
    assign camera_scl = 1'bz;
    assign camera_sda = 1'bz;

    // ------------------------------------------------------------ reference clock + KEY0
    wire ref_clk, ref_clk_g, key_resetn;
    GTP_INBUFDS u_ref_buf (.O(ref_clk), .I(ddr_ref_clk_p), .IB(ddr_ref_clk_n));
    GTP_CLKBUFG u_ref_bufg (.CLKIN(ref_clk), .CLKOUT(ref_clk_g));
    reset_button_debounce #(.STABLE_CYCLES(KEY_DEBOUNCE_CYCLES)) u_key (
        .clk(ref_clk_g), .keyn(resetn), .resetn_out(key_resetn));

    // ------------------------------------------------------------ CPU PLL (used when CPU_CLK_SEL == 2)
    wire pll_out, pll_clk, pll_lock;
    clk_cpu u_cpu_pll (.clkin1(ref_clk), .clkout0(pll_out), .lock(pll_lock));
    GTP_CLKBUFG u_cpu_bufg (.CLKIN(pll_out), .CLKOUT(pll_clk));

    ooo_ddr_soc #(.CPU_CLK_SEL(CPU_CLK_SEL), .CPU_CLK_HZ(CPU_CLK_HZ), .INIT_EVEN(INIT_EVEN),
                  .INIT_ODD(INIT_ODD), .TCM_BYTES(TCM_BYTES)) u_soc (
        .ref_clk(ref_clk), .ref_clk_g(ref_clk_g), .key_resetn(key_resetn),
        .pll_clk(pll_clk), .pll_lock(pll_lock),
        .uart_rx(uart_rx), .uart_tx(uart_tx),
        .led_clk_alive(led_clk_alive), .led_ddr_ready(led_ddr_ready), .led_selftest(led_selftest),
        .mem_cs_n(mem_cs_n), .mem_rst_n(mem_rst_n), .mem_ck(mem_ck), .mem_ck_n(mem_ck_n),
        .mem_cke(mem_cke), .mem_ras_n(mem_ras_n), .mem_cas_n(mem_cas_n), .mem_we_n(mem_we_n),
        .mem_odt(mem_odt), .mem_a(mem_a), .mem_ba(mem_ba), .mem_dqs(mem_dqs), .mem_dqs_n(mem_dqs_n),
        .mem_dq(mem_dq), .mem_dm(mem_dm));
endmodule

// ----------------------------------------------------------------------------
// ooo_ddr_soc -- DDR3 IP (u_ddr3) + clocks/resets + soc_ooo (u_ooo)
// ----------------------------------------------------------------------------
module ooo_ddr_soc #(
    parameter integer CPU_CLK_SEL = 1,
    parameter integer CPU_CLK_HZ  = 125_000_000,
    parameter         INIT_EVEN   = "D:/riscv/ooo_riscv_ddr3/source/ooo_img/ddr125_perf/tcm_even.dat",
    parameter         INIT_ODD    = "D:/riscv/ooo_riscv_ddr3/source/ooo_img/ddr125_perf/tcm_odd.dat",
    parameter integer TCM_BYTES   = 65536
) (
    input  wire ref_clk, ref_clk_g, key_resetn,
    input  wire pll_clk, pll_lock,           // CPU PLL (board top), CPU_CLK_SEL == 2
    input  wire uart_rx,
    output wire uart_tx,
    output wire led_clk_alive, led_ddr_ready, led_selftest,
    output wire mem_cs_n, mem_rst_n, mem_ck, mem_ck_n, mem_cke, mem_ras_n, mem_cas_n, mem_we_n, mem_odt,
    output wire [14:0] mem_a,
    output wire [2:0]  mem_ba,
    inout  wire [3:0]  mem_dqs, mem_dqs_n,
    inout  wire [31:0] mem_dq,
    output wire [3:0]  mem_dm
);
    wire        core_clk, ddr_pll_lock, ddr_init_done;
    wire [27:0] axi_awaddr, axi_araddr;
    wire        axi_awuser_ap, axi_aruser_ap, axi_awready, axi_awvalid, axi_wready;
    wire        axi_arready, axi_arvalid, axi_rvalid, axi_rlast, axi_wusero_last;
    wire [3:0]  axi_awuser_id, axi_aruser_id, axi_awlen, axi_arlen, axi_rid, axi_wusero_id;
    wire [255:0] axi_wdata, axi_rdata;
    wire [31:0] axi_wstrb;
    ddr3 u_ddr3 (
        .ref_clk(ref_clk), .resetn(key_resetn), .core_clk(core_clk), .pll_lock(ddr_pll_lock),
        .phy_pll_lock(), .gpll_lock(), .rst_gpll_lock(), .ddrphy_cpd_lock(),
        .ddr_init_done(ddr_init_done),
        .axi_awaddr(axi_awaddr), .axi_awuser_ap(axi_awuser_ap), .axi_awuser_id(axi_awuser_id),
        .axi_awlen(axi_awlen), .axi_awready(axi_awready), .axi_awvalid(axi_awvalid),
        .axi_wdata(axi_wdata), .axi_wstrb(axi_wstrb), .axi_wready(axi_wready),
        .axi_wusero_id(axi_wusero_id), .axi_wusero_last(axi_wusero_last),
        .axi_araddr(axi_araddr), .axi_aruser_ap(axi_aruser_ap), .axi_aruser_id(axi_aruser_id),
        .axi_arlen(axi_arlen), .axi_arready(axi_arready), .axi_arvalid(axi_arvalid),
        .axi_rdata(axi_rdata), .axi_rid(axi_rid), .axi_rlast(axi_rlast), .axi_rvalid(axi_rvalid),
        .apb_clk(1'b0), .apb_rst_n(1'b0), .apb_sel(1'b0), .apb_enable(1'b0), .apb_addr(8'b0),
        .apb_write(1'b0), .apb_ready(), .apb_wdata(16'b0), .apb_rdata(),
        .mem_cs_n(mem_cs_n), .mem_rst_n(mem_rst_n), .mem_ck(mem_ck), .mem_ck_n(mem_ck_n),
        .mem_cke(mem_cke), .mem_ras_n(mem_ras_n), .mem_cas_n(mem_cas_n), .mem_we_n(mem_we_n),
        .mem_odt(mem_odt), .mem_a(mem_a), .mem_ba(mem_ba), .mem_dqs(mem_dqs), .mem_dqs_n(mem_dqs_n),
        .mem_dq(mem_dq), .mem_dm(mem_dm),
        .dbg_gate_start(1'b0), .dbg_cpd_start(1'b0), .dbg_ddrphy_rst_n(1'b1), .dbg_gpll_scan_rst(1'b0),
        .samp_position_dyn_adj(1'b0), .init_samp_position_even(32'b0), .wrcal_position_dyn_adj(1'b0),
        .init_wrcal_position(32'b0), .force_read_clk_ctrl(1'b0), .init_slip_step(16'b0),
        .init_read_clk_ctrl(12'b0), .debug_calib_ctrl(), .dbg_slice_status(), .dbg_slice_state(),
        .debug_data(), .dbg_dll_upd_state(), .debug_gpll_dps_phase(), .dbg_rst_dps_state(),
        .dbg_tran_err_rst_cnt(), .dbg_ddrphy_init_fail(), .debug_cpd_offset_adj(1'b0),
        .debug_cpd_offset_dir(1'b0), .debug_cpd_offset(10'b0), .debug_dps_cnt_dir0(),
        .debug_dps_cnt_dir1(), .ck_dly_en(1'b1), .init_ck_dly_step(8'b0), .ck_dly_set_bin(),
        .align_error(), .debug_rst_state(), .debug_cpd_state());
    // ------------------------------------------------------------ CPU clock
    wire cpu_clk, cpu_clk_ok;
    generate if (CPU_CLK_SEL == 0) begin : g_clk_core
        assign cpu_clk = core_clk; assign cpu_clk_ok = ddr_pll_lock;
    end else if (CPU_CLK_SEL == 1) begin : g_clk_ref
        assign cpu_clk = ref_clk_g; assign cpu_clk_ok = 1'b1;
    end else begin : g_clk_pll
        assign cpu_clk = pll_clk; assign cpu_clk_ok = pll_lock;
    end endgenerate

    // ------------------------------------------------------------ resets (synchronised release)
    reg [2:0] cpu_rst_s, ddr_rst_s;
    always @(posedge cpu_clk or negedge key_resetn)
        if (!key_resetn) cpu_rst_s <= 3'b000;
        else cpu_rst_s <= {cpu_rst_s[1:0], cpu_clk_ok};
    wire cpu_resetn = cpu_rst_s[2];
    always @(posedge core_clk or negedge key_resetn)
        if (!key_resetn) ddr_rst_s <= 3'b000;
        else ddr_rst_s <= {ddr_rst_s[1:0], ddr_pll_lock};
    wire ddr_resetn = ddr_rst_s[2];

    // ------------------------------------------------------------ SoC
    wire [1:0] test_status;
    wire [7:0] led;
    soc_ooo #(
        .CLK_HZ(CPU_CLK_HZ), .USE_DDR(1), .RESET_PC(32'h0000_0000), .TCM_BASE(32'h0000_0000),
        .TCM_BYTES(TCM_BYTES), .INIT_EVEN(INIT_EVEN), .INIT_ODD(INIT_ODD)
    ) u_ooo (
        .clk(cpu_clk), .resetn(cpu_resetn), .uart_rx(uart_rx), .uart_tx(uart_tx),
        .gpio_in(16'd0), .gpio_out(), .gpio_dir(), .irq_ext(1'b0),
        .test_status(test_status), .led(led),
        .ddr_clk(core_clk), .ddr_resetn(ddr_resetn), .ddr_init_done(ddr_init_done),
        .axi_awaddr(axi_awaddr), .axi_awuser_ap(axi_awuser_ap), .axi_awuser_id(axi_awuser_id),
        .axi_awlen(axi_awlen), .axi_awready(axi_awready), .axi_awvalid(axi_awvalid),
        .axi_wdata(axi_wdata), .axi_wstrb(axi_wstrb), .axi_wready(axi_wready),
        .axi_araddr(axi_araddr), .axi_aruser_ap(axi_aruser_ap), .axi_aruser_id(axi_aruser_id),
        .axi_arlen(axi_arlen), .axi_arready(axi_arready), .axi_arvalid(axi_arvalid),
        .axi_rdata(axi_rdata), .axi_rvalid(axi_rvalid));

    // ------------------------------------------------------------ LEDs
    reg [26:0] hb;
    always @(posedge cpu_clk) hb <= hb + 1'b1;
    assign led_clk_alive = hb[26];                                   // ~1 Hz blink
    assign led_ddr_ready = ddr_init_done;
    assign led_selftest  = led[0] | (test_status == 2'd2);
endmodule
