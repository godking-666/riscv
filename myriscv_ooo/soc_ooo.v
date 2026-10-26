// ============================================================================
// soc_ooo  --  SoC around the 2-wide out-of-order core
//
//   ooo_core --(64b I)--> ooo_ibus --> TCM | I-cache --+
//            --(32b D)--> ooo_dbus --> TCM | D-cache --+--> ooo_ddr_port --> DDR3 IP
//                                   \-> I/O                (core_clk domain)
//   I/O: 0x1000_0000 system regs (cycle counter, timer, LEDs)
//        0x1000_1000 UART (existing uart_mmio), 0x1000_5000 GPIO (gpio_mmio)
//
// USE_DDR = 0 (BRAM build): program + data in the TCM at TCM_BASE (default
//   0x4000_0000); the core boots there.  No DDR logic is elaborated.
// USE_DDR = 1 (DDR build): TCM at 0x0000_0000 holds the boot loader and the
//   program image; the loader copies the image to DDR at 0x4000_0000 through
//   the D-cache, executes FENCE.I (clean D$, invalidate I$) and jumps there.
//   0x4000_0000..0x5fff_ffff is cached (2-way I$ and D$, line = LINE bytes,
//   one DDR burst per line).
// ============================================================================
module soc_ooo #(
    parameter integer CLK_HZ    = 100_000_000,
    parameter integer USE_DDR   = 0,
    parameter [31:0]  RESET_PC  = 32'h4000_0000,
    parameter [31:0]  TCM_BASE  = 32'h4000_0000,
    parameter integer TCM_BYTES = 131072,
    parameter         INIT_EVEN = "",
    parameter         INIT_ODD  = "",
    parameter integer GPIO_WIDTH = 16,
    parameter integer UART_BAUD  = 115_200,
    parameter integer IC_SETS = 128, parameter integer DC_SETS = 128,
    parameter integer LINE = 64,
    parameter integer CTRL_ADDR_WIDTH = 28
) (
    input  wire        clk,
    input  wire        resetn,          // synchronous to clk
    input  wire        uart_rx,
    output wire        uart_tx,
    input  wire [GPIO_WIDTH-1:0] gpio_in,
    output wire [GPIO_WIDTH-1:0] gpio_out,
    output wire [GPIO_WIDTH-1:0] gpio_dir,
    input  wire        irq_ext,
    output wire [1:0]  test_status,
    output wire [7:0]  led,
    // DDR3 IP user port (core_clk domain); unused when USE_DDR = 0
    input  wire        ddr_clk,
    input  wire        ddr_resetn,
    input  wire        ddr_init_done,
    output wire [CTRL_ADDR_WIDTH-1:0] axi_awaddr,
    output wire        axi_awuser_ap,
    output wire [3:0]  axi_awuser_id,
    output wire [3:0]  axi_awlen,
    input  wire        axi_awready,
    output wire        axi_awvalid,
    output wire [255:0] axi_wdata,
    output wire [31:0] axi_wstrb,
    input  wire        axi_wready,
    output wire [CTRL_ADDR_WIDTH-1:0] axi_araddr,
    output wire        axi_aruser_ap,
    output wire [3:0]  axi_aruser_id,
    output wire [3:0]  axi_arlen,
    input  wire        axi_arready,
    output wire        axi_arvalid,
    input  wire [255:0] axi_rdata,
    input  wire        axi_rvalid
);
    localparam [31:0] TCM_MASK = ~(TCM_BYTES - 1);

    // ---------------------------------------------------------------- core
    wire        ireq_valid, ireq_ready, irsp_valid, irsp_error;
    wire [31:0] ireq_addr;
    wire [63:0] irsp_data;
    wire        dreq_valid, dreq_we, dreq_ready, drsp_valid, drsp_error;
    wire [31:0] dreq_addr, dreq_wdata, drsp_rdata;
    wire [3:0]  dreq_wstrb;
    wire [1:0]  dreq_size;
    wire        irq_timer, irq_soft, uart_irq, gpio_irq;
    wire        cmo_req, cmo_done;
    ooo_core #(.RESET_PC(RESET_PC)) u_core (
        .clk(clk), .resetn(resetn),
        .irq_external(irq_ext | uart_irq | gpio_irq), .irq_software(irq_soft), .irq_timer(irq_timer),
        .ireq_valid(ireq_valid), .ireq_addr(ireq_addr), .ireq_ready(ireq_ready),
        .irsp_valid(irsp_valid), .irsp_data(irsp_data), .irsp_error(irsp_error),
        .dreq_valid(dreq_valid), .dreq_we(dreq_we), .dreq_addr(dreq_addr), .dreq_wdata(dreq_wdata),
        .dreq_wstrb(dreq_wstrb), .dreq_size(dreq_size), .dreq_ready(dreq_ready),
        .drsp_valid(drsp_valid), .drsp_rdata(drsp_rdata), .drsp_error(drsp_error),
        .cmo_req(cmo_req), .cmo_done(cmo_done),
        .dbg_cvalid(), .dbg_c0_pc(), .dbg_c1_pc(), .dbg_c0_wen(), .dbg_c1_wen(),
        .dbg_c0_rd(), .dbg_c1_rd(), .dbg_c0_pdst(), .dbg_c1_pdst(), .dbg_trap(), .perf_ev());

    // ---------------------------------------------------------------- instruction side
    wire        ti_valid, ti_rsp_valid;
    wire [31:0] ti_addr;
    wire [63:0] ti_rsp_data;
    wire        ic_valid, ic_ready, ic_rsp_valid, ic_rsp_error;
    wire [63:0] ic_rsp_data;
    ooo_ibus #(.TCM_BASE(TCM_BASE), .TCM_MASK(TCM_MASK), .HAS_IC(USE_DDR)) u_ibus (
        .clk(clk), .resetn(resetn),
        .m_valid(ireq_valid), .m_addr(ireq_addr), .m_ready(ireq_ready),
        .m_rsp_valid(irsp_valid), .m_rsp_data(irsp_data), .m_rsp_error(irsp_error),
        .t_valid(ti_valid), .t_addr(ti_addr), .t_rsp_valid(ti_rsp_valid), .t_rsp_data(ti_rsp_data),
        .c_valid(ic_valid), .c_ready(ic_ready), .c_rsp_valid(ic_rsp_valid), .c_rsp_data(ic_rsp_data),
        .c_rsp_error(ic_rsp_error));

    // ---------------------------------------------------------------- data side
    wire        td_valid, td_rsp_valid, o_valid, o_ready, o_rsp_valid, o_rsp_error;
    wire [31:0] td_addr, td_rsp_rdata, o_rsp_rdata;
    wire        dc_valid, dc_ready, dc_rsp_valid, dc_rsp_error;
    wire [31:0] dc_rsp_rdata;
    ooo_dbus #(.TCM_BASE(TCM_BASE), .TCM_MASK(TCM_MASK), .HAS_DC(USE_DDR)) u_dbus (
        .clk(clk), .resetn(resetn),
        .m_valid(dreq_valid), .m_we(dreq_we), .m_addr(dreq_addr), .m_wdata(dreq_wdata),
        .m_wstrb(dreq_wstrb), .m_size(dreq_size), .m_ready(dreq_ready),
        .m_rsp_valid(drsp_valid), .m_rsp_rdata(drsp_rdata), .m_rsp_error(drsp_error),
        .t_valid(td_valid), .t_addr(td_addr), .t_rsp_valid(td_rsp_valid), .t_rsp_rdata(td_rsp_rdata),
        .c_valid(dc_valid), .c_ready(dc_ready), .c_rsp_valid(dc_rsp_valid), .c_rsp_rdata(dc_rsp_rdata),
        .c_rsp_error(dc_rsp_error),
        .o_valid(o_valid), .o_ready(o_ready), .o_rsp_valid(o_rsp_valid), .o_rsp_rdata(o_rsp_rdata),
        .o_rsp_error(o_rsp_error));

    ooo_tcm #(.BYTES(TCM_BYTES), .INIT_EVEN(INIT_EVEN), .INIT_ODD(INIT_ODD)) u_tcm (
        .clk(clk), .resetn(resetn),
        .i_valid(ti_valid), .i_addr(ti_addr), .i_rsp_valid(ti_rsp_valid), .i_rsp_data(ti_rsp_data),
        .d_valid(td_valid), .d_we(dreq_we), .d_addr(td_addr), .d_wdata(dreq_wdata), .d_wstrb(dreq_wstrb),
        .d_rsp_valid(td_rsp_valid), .d_rsp_rdata(td_rsp_rdata));

    // ---------------------------------------------------------------- caches + DDR
    generate if (USE_DDR != 0) begin : g_ddr
        wire              im_valid, im_ready, im_rsp_valid, im_rsp_error;
        wire [31:0]       im_addr;
        wire [LINE*8-1:0] im_rsp_data;
        wire              dm_valid, dm_we, dm_ready, dm_rsp_valid, dm_rsp_error;
        wire [31:0]       dm_addr;
        wire [LINE*8-1:0] dm_wdata, dm_rsp_data;
        wire              fl_done, inv_done;
        ooo_icache #(.SETS(IC_SETS), .LINE(LINE)) u_ic (
            .clk(clk), .resetn(resetn),
            .c_valid(ic_valid), .c_addr(ireq_addr), .c_ready(ic_ready),
            .c_rsp_valid(ic_rsp_valid), .c_rsp_data(ic_rsp_data), .c_rsp_error(ic_rsp_error),
            .inv_req(cmo_req && fl_done), .inv_done(inv_done),
            .m_valid(im_valid), .m_addr(im_addr), .m_ready(im_ready),
            .m_rsp_valid(im_rsp_valid), .m_rsp_data(im_rsp_data), .m_rsp_error(im_rsp_error));
        ooo_dcache #(.SETS(DC_SETS), .LINE(LINE)) u_dc (
            .clk(clk), .resetn(resetn),
            .c_valid(dc_valid), .c_we(dreq_we), .c_addr(dreq_addr), .c_wdata(dreq_wdata),
            .c_wstrb(dreq_wstrb), .c_ready(dc_ready),
            .c_rsp_valid(dc_rsp_valid), .c_rsp_rdata(dc_rsp_rdata), .c_rsp_error(dc_rsp_error),
            .fl_req(cmo_req), .fl_done(fl_done),
            .m_valid(dm_valid), .m_we(dm_we), .m_addr(dm_addr), .m_wdata(dm_wdata), .m_ready(dm_ready),
            .m_rsp_valid(dm_rsp_valid), .m_rsp_data(dm_rsp_data), .m_rsp_error(dm_rsp_error));
        reg cmo_done_r;                  // registered: keeps the caches out of commit timing
        always @(posedge clk) cmo_done_r <= resetn && cmo_req && inv_done;
        assign cmo_done = cmo_done_r;
        ooo_ddr_port #(.LINE(LINE), .CTRL_ADDR_WIDTH(CTRL_ADDR_WIDTH)) u_port (
            .clk(clk), .resetn(resetn),
            .i_valid(im_valid), .i_addr(im_addr), .i_ready(im_ready),
            .i_rsp_valid(im_rsp_valid), .i_rsp_data(im_rsp_data), .i_rsp_error(im_rsp_error),
            .d_valid(dm_valid), .d_we(dm_we), .d_addr(dm_addr), .d_wdata(dm_wdata), .d_ready(dm_ready),
            .d_rsp_valid(dm_rsp_valid), .d_rsp_data(dm_rsp_data), .d_rsp_error(dm_rsp_error),
            .ddr_clk(ddr_clk), .ddr_resetn(ddr_resetn), .ddr_init_done(ddr_init_done),
            .axi_awaddr(axi_awaddr), .axi_awuser_ap(axi_awuser_ap), .axi_awuser_id(axi_awuser_id),
            .axi_awlen(axi_awlen), .axi_awready(axi_awready), .axi_awvalid(axi_awvalid),
            .axi_wdata(axi_wdata), .axi_wstrb(axi_wstrb), .axi_wready(axi_wready),
            .axi_araddr(axi_araddr), .axi_aruser_ap(axi_aruser_ap), .axi_aruser_id(axi_aruser_id),
            .axi_arlen(axi_arlen), .axi_arready(axi_arready), .axi_arvalid(axi_arvalid),
            .axi_rdata(axi_rdata), .axi_rvalid(axi_rvalid));
    end else begin : g_noddr
        assign ic_ready = 1'b0; assign ic_rsp_valid = 1'b0; assign ic_rsp_data = 64'd0; assign ic_rsp_error = 1'b0;
        assign dc_ready = 1'b0; assign dc_rsp_valid = 1'b0; assign dc_rsp_rdata = 32'd0; assign dc_rsp_error = 1'b0;
        assign cmo_done = cmo_req;
        assign axi_awaddr = 0; assign axi_awuser_ap = 1'b0; assign axi_awuser_id = 4'd0; assign axi_awlen = 4'd0;
        assign axi_awvalid = 1'b0; assign axi_wdata = 256'd0; assign axi_wstrb = 32'd0;
        assign axi_araddr = 0; assign axi_aruser_ap = 1'b0; assign axi_aruser_id = 4'd0; assign axi_arlen = 4'd0;
        assign axi_arvalid = 1'b0;
    end endgenerate

    // ---------------------------------------------------------------- I/O
    wire        s_valid, s_rsp_valid, u_valid, u_ready, u_rsp_valid, u_rsp_error;
    wire        g_valid, g_ready, g_rsp_valid, g_rsp_error;
    wire [31:0] s_rsp_rdata, u_rsp_rdata, g_rsp_rdata;
    ooo_iobus u_iobus (
        .clk(clk), .resetn(resetn),
        .m_valid(o_valid), .m_we(dreq_we), .m_addr(dreq_addr), .m_wdata(dreq_wdata), .m_wstrb(dreq_wstrb),
        .m_size(dreq_size), .m_ready(o_ready),
        .m_rsp_valid(o_rsp_valid), .m_rsp_rdata(o_rsp_rdata), .m_rsp_error(o_rsp_error),
        .s_valid(s_valid), .s_rsp_valid(s_rsp_valid), .s_rsp_rdata(s_rsp_rdata),
        .u_valid(u_valid), .u_ready(u_ready), .u_rsp_valid(u_rsp_valid), .u_rsp_rdata(u_rsp_rdata),
        .u_rsp_error(u_rsp_error),
        .g_valid(g_valid), .g_ready(g_ready), .g_rsp_valid(g_rsp_valid), .g_rsp_rdata(g_rsp_rdata),
        .g_rsp_error(g_rsp_error));
    ooo_mmio #(.CLK_HZ(CLK_HZ)) u_sys (
        .clk(clk), .resetn(resetn),
        .req_valid(s_valid), .req_write(dreq_we), .req_addr(dreq_addr[11:0]), .req_wdata(dreq_wdata),
        .req_wstrb(dreq_wstrb), .rsp_valid(s_rsp_valid), .rsp_rdata(s_rsp_rdata),
        .test_status(test_status), .led(led), .irq_timer(irq_timer), .irq_soft(irq_soft));
    uart_mmio #(.CLK_HZ(CLK_HZ), .BAUD(UART_BAUD)) u_uart (
        .clk(clk), .resetn(resetn),
        .req_valid(u_valid), .req_write(dreq_we), .req_size(dreq_size), .req_addr({28'd0, dreq_addr[3:0]}),
        .req_wdata(dreq_wdata), .req_wstrb(dreq_wstrb), .req_ready(u_ready), .rsp_valid(u_rsp_valid),
        .rsp_rdata(u_rsp_rdata), .rsp_error(u_rsp_error),
        .uart_rx(uart_rx), .uart_tx(uart_tx), .uart_irq(uart_irq));
    gpio_mmio #(.GPIO_WIDTH(GPIO_WIDTH)) u_gpio (
        .clk(clk), .resetn(resetn),
        .req_valid(g_valid), .req_write(dreq_we), .req_size(dreq_size), .req_addr({20'd0, dreq_addr[11:0]}),
        .req_wdata(dreq_wdata), .req_wstrb(dreq_wstrb), .req_ready(g_ready), .rsp_valid(g_rsp_valid),
        .rsp_rdata(g_rsp_rdata), .rsp_error(g_rsp_error),
        .gpio_in(gpio_in), .gpio_out(gpio_out), .gpio_dir(gpio_dir), .gpio_irq(gpio_irq));
endmodule
