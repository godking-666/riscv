// ============================================================================
// ooo_soc_top  --  用队友乱序核取代顺序核的 SoC 顶层
//
// 对外端口与 myriscv/soc_top.v **完全一致**，因此上层的 soc_ddr3_top_ooo /
// board_top_ooo / 视频子系统 / HDMI / OSD / 约束全部原样复用。
//
// 内部结构（依据 myriscv_ooo 源码逐信号核对）：
//   ooo_core --(64b I)--> ooo_ibus --+--> ooo_tcm(u_rom_tcm)   [0x0 + TCM_BYTES]
//                                    +--> ooo_icache --> ooo_ddr_port --> DDR
//            --(32b D)--> ooo_dbus --+--> ooo_tcm(u_ram_tcm)   [0x0 + TCM_BYTES]
//                                    +--> ooo_dcache --> ooo_ddr_port --> DDR
//                                    +--> data_bus_interconnect --> MMIO
//
// 关键设计点（都有源码依据，见 doc/ooo_integration/集成设计规格_20261026.md）：
//  1) 单时钟：CPU 与 DDR 同在 clk(core_clk 93.75MHz)。CoreMark/MHz 与频率无关，
//     所以不引入 135MHz PLL，也就没有新增时钟域和 CDC。
//  2) Harvard 同构：我们的 ROM 在指令总线的 0x0、RAM 在数据总线的 0x0，
//     他核的 TCM 窗口也正好在 0x0，用两个 ooo_tcm 实例分别承载，互不干扰。
//  3) ooo_dbus 的 T/C 端口**不传递写数据**（ooo_xbar.v:28-37 无 wdata 引脚），
//     所以 d_we/d_wdata/d_wstrb 必须从 dreq_* 越级接出（同 soc_ooo.v:121-122）。
//  4) ooo_dbus 的 I/O 口与 data_bus_interconnect 主口形状一致，且都是单笔在途，
//     所以 MMIO 直接用我们自己的互连（相机/PP/CNN 地址译码零改动）。
//  5) DDR 地址：ooo_ddr_port 取 addr[28:5]（ooo_ddr_port.v:136），
//     而 0x4000_0000 的位[28:5] 全为 0，等价于减基址，和我们的仲裁链同一约定。
// ============================================================================
`timescale 1ns / 1ps

module ooo_soc_top #(
    parameter [31:0]  RESET_PC          = 32'h0000_0000,
    parameter [31:0]  DDR_BASE          = 32'h4000_0000,
    parameter [31:0]  DDR_ADDR_MASK     = 32'hc000_0000,
    parameter integer DDR_MEM_DQ_WIDTH  = 32,
    parameter integer ENABLE_CNN        = 0,
    parameter integer ENABLE_PREPROCESS = 0,
    parameter integer ENABLE_CAMERA     = 0,
    parameter integer ENABLE_GPIO       = 0,
    // 仅为与 soc_top 的参数接口兼容而保留：本集成里 DDR 由 ooo_ddr_port 直连仲裁链，
    // 没有"可选 DDR"的分支，故该参数不参与逻辑。
    parameter integer ENABLE_DDR        = 1,
    parameter integer CLK_HZ            = 93_750_000,
    parameter integer UART_CLK_HZ       = 93_750_000,
    parameter [31:0]  UART_BASE         = 32'h1000_1000,
    parameter [31:0]  GPIO_BASE         = 32'h1000_5000,
    parameter integer GPIO_WIDTH        = 8,
    parameter [31:0]  MMIO_BASE         = 32'h1000_0000,
    // Loader 常驻区：指令侧 ROM 与数据侧 RAM 都是这么大（16 KiB = 4096 字）
    parameter integer TCM_BYTES         = 16384,
    parameter         ROM_INIT_EVEN     = "D:/riscv/RISCV/myriscv_ooo/img/rom_even.hex",
    parameter         ROM_INIT_ODD      = "D:/riscv/RISCV/myriscv_ooo/img/rom_odd.hex",
    parameter         RAM_INIT_EVEN     = "D:/riscv/RISCV/myriscv_ooo/img/ram_even.hex",
    parameter         RAM_INIT_ODD      = "D:/riscv/RISCV/myriscv_ooo/img/ram_odd.hex",
    parameter integer IC_SETS           = 128,
    parameter integer DC_SETS           = 128,
    parameter integer LINE              = 64,
    parameter integer CTRL_ADDR_WIDTH   = 28
) (
    // ---- 与 soc_top 一致的 MMIO 通道 ----
    output wire cnn_req_valid, cnn_req_write,
    output wire [1:0] cnn_req_size,
    output wire [31:0] cnn_req_addr, cnn_req_wdata,
    output wire [3:0] cnn_req_wstrb,
    input  wire cnn_req_ready, cnn_rsp_valid, cnn_rsp_error,
    input  wire [31:0] cnn_rsp_rdata,
    output wire pp_req_valid, pp_req_write,
    output wire [1:0] pp_req_size,
    output wire [31:0] pp_req_addr, pp_req_wdata,
    output wire [3:0] pp_req_wstrb,
    input  wire pp_req_ready, pp_rsp_valid, pp_rsp_error,
    input  wire [31:0] pp_rsp_rdata,
    input  wire preprocess_busy, preprocess_done,
    output wire cam_req_valid, cam_req_write,
    output wire [1:0] cam_req_size,
    output wire [31:0] cam_req_addr, cam_req_wdata,
    output wire [3:0] cam_req_wstrb,
    input  wire cam_req_ready, cam_rsp_valid, cam_rsp_error,
    input  wire [31:0] cam_rsp_rdata,
    input  wire camera_busy,
    input  wire camera_dual_mode,
    input  wire [1:0] camera_cpu_owned,
    // ---- 时钟/复位/中断 ----
    input  wire        clk,
    input  wire        resetn,
    input  wire        irq_external,
    input  wire        irq_software,
    input  wire        irq_timer,
    // ---- 调试观测 ----
    output wire [31:0] debug_wb_pc,
    output wire [ 3:0] debug_wb_rf_we,
    output wire [ 4:0] debug_wb_rf_wnum,
    output wire [31:0] debug_wb_rf_wdata,
    output wire [31:0] debug_inst,
    // ---- DDR3 IP 用户口（core_clk 域）----
    input  wire        ddr_init_done,
    output wire [27:0] ddr_axi_awaddr,
    output wire        ddr_axi_awuser_ap,
    output wire [ 3:0] ddr_axi_awuser_id,
    output wire [ 3:0] ddr_axi_awlen,
    input  wire        ddr_axi_awready,
    output wire        ddr_axi_awvalid,
    output wire [8*DDR_MEM_DQ_WIDTH-1:0] ddr_axi_wdata,
    output wire [DDR_MEM_DQ_WIDTH-1:0]   ddr_axi_wstrb,
    input  wire        ddr_axi_wready,
    input  wire [ 3:0] ddr_axi_wusero_id,
    input  wire        ddr_axi_wusero_last,
    output wire [27:0] ddr_axi_araddr,
    output wire        ddr_axi_aruser_ap,
    output wire [ 3:0] ddr_axi_aruser_id,
    output wire [ 3:0] ddr_axi_arlen,
    input  wire        ddr_axi_arready,
    output wire        ddr_axi_arvalid,
    input  wire [8*DDR_MEM_DQ_WIDTH-1:0] ddr_axi_rdata,
    input  wire [ 3:0] ddr_axi_rid,
    input  wire        ddr_axi_rlast,
    input  wire        ddr_axi_rvalid,
    // ---- 自检/串口/GPIO ----
    output wire [ 1:0] selftest_status,
    input  wire        uart_rx,
    output wire        uart_tx,
    input  wire [GPIO_WIDTH-1:0] gpio_in,
    output wire [GPIO_WIDTH-1:0] gpio_out,
    output wire [GPIO_WIDTH-1:0] gpio_dir,
    output wire        gpio_irq
);
    // TCM 窗口：0 起、TCM_BYTES 大小，掩码必须是 ~(size-1)（ooo_xbar.v:46/108 用掩码比基址）
    localparam [31:0] TCM_MASK = ~(TCM_BYTES - 1);
    localparam [31:0] DC_BASE  = DDR_BASE;
    localparam [31:0] DC_MASK  = DDR_ADDR_MASK;
    localparam [31:0] IO_BASE  = MMIO_BASE;
    localparam [31:0] IO_MASK  = 32'hffff_0000;

    // ---------------------------------------------------------------- 乱序核
    wire        ireq_valid, ireq_ready, irsp_valid, irsp_error;
    wire [31:0] ireq_addr;
    wire [63:0] irsp_data;
    wire        dreq_valid, dreq_we, dreq_ready, drsp_valid, drsp_error;
    wire [31:0] dreq_addr, dreq_wdata, drsp_rdata;
    wire [3:0]  dreq_wstrb;
    wire [1:0]  dreq_size;
    wire        irq_timer_i, irq_soft_i, uart_irq, gpio_irq_i;
    wire        cmo_req, cmo_done;

    ooo_core #(.RESET_PC(RESET_PC)) u_core (
        .clk(clk), .resetn(resetn),
        .irq_external(irq_external | uart_irq | gpio_irq_i),
        .irq_software(irq_software), .irq_timer(irq_timer),
        .ireq_valid(ireq_valid), .ireq_addr(ireq_addr), .ireq_ready(ireq_ready),
        .irsp_valid(irsp_valid), .irsp_data(irsp_data), .irsp_error(irsp_error),
        .dreq_valid(dreq_valid), .dreq_we(dreq_we), .dreq_addr(dreq_addr), .dreq_wdata(dreq_wdata),
        .dreq_wstrb(dreq_wstrb), .dreq_size(dreq_size), .dreq_ready(dreq_ready),
        .drsp_valid(drsp_valid), .drsp_rdata(drsp_rdata), .drsp_error(drsp_error),
        .cmo_req(cmo_req), .cmo_done(cmo_done),
        .dbg_cvalid(), .dbg_c0_pc(debug_wb_pc), .dbg_c1_pc(), .dbg_c0_wen(debug_wb_rf_we),
        .dbg_c1_wen(), .dbg_c0_rd(), .dbg_c1_rd(), .dbg_c0_pdst(debug_wb_rf_wnum),
        .dbg_c1_pdst(), .dbg_trap(), .perf_ev()
    );
    assign debug_wb_rf_wdata = 32'd0;
    assign debug_inst        = 32'd0;

    // ---------------------------------------------------------------- 指令侧
    wire        ti_valid, ti_rsp_valid;
    wire [31:0] ti_addr;
    wire [63:0] ti_rsp_data;
    wire        ic_valid, ic_ready, ic_rsp_valid, ic_rsp_error;
    wire [63:0] ic_rsp_data;

    ooo_ibus #(.TCM_BASE(RESET_PC), .TCM_MASK(TCM_MASK), .HAS_IC(1),
               .IC_BASE(DC_BASE), .IC_MASK(DC_MASK)) u_ibus (
        .clk(clk), .resetn(resetn),
        .m_valid(ireq_valid), .m_addr(ireq_addr), .m_ready(ireq_ready),
        .m_rsp_valid(irsp_valid), .m_rsp_data(irsp_data), .m_rsp_error(irsp_error),
        .t_valid(ti_valid), .t_addr(ti_addr), .t_rsp_valid(ti_rsp_valid), .t_rsp_data(ti_rsp_data),
        .c_valid(ic_valid), .c_ready(ic_ready), .c_rsp_valid(ic_rsp_valid), .c_rsp_data(ic_rsp_data),
        .c_rsp_error(ic_rsp_error)
    );

    // 指令侧 TCM = Loader ROM（只用 i_ 口，d_ 口关掉）
    ooo_tcm #(.BYTES(TCM_BYTES), .INIT_EVEN(ROM_INIT_EVEN), .INIT_ODD(ROM_INIT_ODD)) u_rom_tcm (
        .clk(clk), .resetn(resetn),
        .i_valid(ti_valid), .i_addr(ti_addr), .i_rsp_valid(ti_rsp_valid), .i_rsp_data(ti_rsp_data),
        .d_valid(1'b0), .d_we(1'b0), .d_addr(32'd0), .d_wdata(32'd0), .d_wstrb(4'd0),
        .d_rsp_valid(), .d_rsp_rdata()
    );

    // ---------------------------------------------------------------- 数据侧
    wire        td_valid, td_rsp_valid, o_valid, o_ready, o_rsp_valid, o_rsp_error;
    wire [31:0] td_addr, td_rsp_rdata, o_rsp_rdata;
    wire        dc_valid, dc_ready, dc_rsp_valid, dc_rsp_error;
    wire [31:0] dc_rsp_rdata;

    ooo_dbus #(.TCM_BASE(RESET_PC), .TCM_MASK(TCM_MASK), .HAS_DC(1),
               .DC_BASE(DC_BASE), .DC_MASK(DC_MASK),
               .IO_BASE(IO_BASE), .IO_MASK(IO_MASK)) u_dbus (
        .clk(clk), .resetn(resetn),
        .m_valid(dreq_valid), .m_we(dreq_we), .m_addr(dreq_addr), .m_wdata(dreq_wdata),
        .m_wstrb(dreq_wstrb), .m_size(dreq_size), .m_ready(dreq_ready),
        .m_rsp_valid(drsp_valid), .m_rsp_rdata(drsp_rdata), .m_rsp_error(drsp_error),
        .t_valid(td_valid), .t_addr(td_addr), .t_rsp_valid(td_rsp_valid), .t_rsp_rdata(td_rsp_rdata),
        .c_valid(dc_valid), .c_ready(dc_ready), .c_rsp_valid(dc_rsp_valid), .c_rsp_rdata(dc_rsp_rdata),
        .c_rsp_error(dc_rsp_error),
        .o_valid(o_valid), .o_ready(o_ready), .o_rsp_valid(o_rsp_valid), .o_rsp_rdata(o_rsp_rdata),
        .o_rsp_error(o_rsp_error)
    );

    // 数据侧 TCM = Loader 的数据 RAM。写数据/字节使能必须从 dreq_* 越级取
    // （ooo_dbus 的 T 口只有 t_valid/t_addr，没有 wdata，见 ooo_xbar.v:28-31）。
    ooo_tcm #(.BYTES(TCM_BYTES), .INIT_EVEN(RAM_INIT_EVEN), .INIT_ODD(RAM_INIT_ODD)) u_ram_tcm (
        .clk(clk), .resetn(resetn),
        .i_valid(1'b0), .i_addr(32'd0), .i_rsp_valid(), .i_rsp_data(),
        .d_valid(td_valid), .d_we(dreq_we), .d_addr(td_addr), .d_wdata(dreq_wdata),
        .d_wstrb(dreq_wstrb), .d_rsp_valid(td_rsp_valid), .d_rsp_rdata(td_rsp_rdata)
    );

    // ---------------------------------------------------------------- Cache + DDR
    wire              im_valid, im_ready, im_rsp_valid, im_rsp_error;
    wire [31:0]       im_addr;
    wire [LINE*8-1:0] im_rsp_data;
    wire              dm_valid, dm_we, dm_ready, dm_rsp_valid, dm_rsp_error;
    wire [31:0]       dm_addr;
    wire [LINE*8-1:0] dm_wdata, dm_rsp_data;
    wire              fl_done, inv_done;

    reg cmo_done_r;
    always @(posedge clk) cmo_done_r <= resetn && cmo_req && inv_done;
    assign cmo_done = cmo_done_r;

    ooo_icache #(.SETS(IC_SETS), .LINE(LINE)) u_ic (
        .clk(clk), .resetn(resetn),
        .c_valid(ic_valid), .c_addr(ireq_addr), .c_ready(ic_ready),
        .c_rsp_valid(ic_rsp_valid), .c_rsp_data(ic_rsp_data), .c_rsp_error(ic_rsp_error),
        .inv_req(cmo_req && fl_done), .inv_done(inv_done),
        .m_valid(im_valid), .m_addr(im_addr), .m_ready(im_ready),
        .m_rsp_valid(im_rsp_valid), .m_rsp_data(im_rsp_data), .m_rsp_error(im_rsp_error)
    );
    ooo_dcache #(.SETS(DC_SETS), .LINE(LINE)) u_dc (
        .clk(clk), .resetn(resetn),
        .c_valid(dc_valid), .c_we(dreq_we), .c_addr(dreq_addr), .c_wdata(dreq_wdata),
        .c_wstrb(dreq_wstrb), .c_ready(dc_ready),
        .c_rsp_valid(dc_rsp_valid), .c_rsp_rdata(dc_rsp_rdata), .c_rsp_error(dc_rsp_error),
        .fl_req(cmo_req), .fl_done(fl_done),
        .m_valid(dm_valid), .m_we(dm_we), .m_addr(dm_addr), .m_wdata(dm_wdata), .m_ready(dm_ready),
        .m_rsp_valid(dm_rsp_valid), .m_rsp_data(dm_rsp_data), .m_rsp_error(dm_rsp_error)
    );
    ooo_ddr_port #(.LINE(LINE), .CTRL_ADDR_WIDTH(CTRL_ADDR_WIDTH)) u_port (
        .clk(clk), .resetn(resetn),
        .i_valid(im_valid), .i_addr(im_addr), .i_ready(im_ready),
        .i_rsp_valid(im_rsp_valid), .i_rsp_data(im_rsp_data), .i_rsp_error(im_rsp_error),
        .d_valid(dm_valid), .d_we(dm_we), .d_addr(dm_addr), .d_wdata(dm_wdata), .d_ready(dm_ready),
        .d_rsp_valid(dm_rsp_valid), .d_rsp_data(dm_rsp_data), .d_rsp_error(dm_rsp_error),
        .ddr_clk(clk), .ddr_resetn(resetn), .ddr_init_done(ddr_init_done),
        .axi_awaddr(ddr_axi_awaddr), .axi_awuser_ap(ddr_axi_awuser_ap), .axi_awuser_id(ddr_axi_awuser_id),
        .axi_awlen(ddr_axi_awlen), .axi_awready(ddr_axi_awready), .axi_awvalid(ddr_axi_awvalid),
        .axi_wdata(ddr_axi_wdata), .axi_wstrb(ddr_axi_wstrb), .axi_wready(ddr_axi_wready),
        .axi_araddr(ddr_axi_araddr), .axi_aruser_ap(ddr_axi_aruser_ap), .axi_aruser_id(ddr_axi_aruser_id),
        .axi_arlen(ddr_axi_arlen), .axi_arready(ddr_axi_arready), .axi_arvalid(ddr_axi_arvalid),
        .axi_rdata(ddr_axi_rdata), .axi_rvalid(ddr_axi_rvalid)
    );
    // 本方案 CPU 不再经过 dual_sram_to_pango_ddr_bridge，这两个侧带输入用不到
    wire _unused_wusero = |{ddr_axi_wusero_id, ddr_axi_wusero_last, ddr_axi_rid, ddr_axi_rlast};

    // ---------------------------------------------------------------- MMIO 互连
    wire mmio_req_valid, mmio_req_write, mmio_req_ready, mmio_rsp_valid, mmio_rsp_error;
    wire [1:0] mmio_req_size;
    wire [31:0] mmio_req_addr, mmio_req_wdata, mmio_rsp_rdata;
    wire [3:0] mmio_req_wstrb;

    wire uart_req_valid, uart_req_write, uart_req_ready, uart_rsp_valid, uart_rsp_error;
    wire [1:0] uart_req_size;
    wire [31:0] uart_req_addr, uart_req_wdata, uart_rsp_rdata;
    wire [3:0] uart_req_wstrb;

    wire gpio_req_valid, gpio_req_write, gpio_req_ready, gpio_rsp_valid, gpio_rsp_error;
    wire [1:0] gpio_req_size;
    wire [31:0] gpio_req_addr, gpio_req_wdata, gpio_rsp_rdata;
    wire [3:0] gpio_req_wstrb;

    // 本互连的 RAM/DDR 通道在这里不会被选中：0x0 段已由 ooo_dbus 的 TCM 窗口吃掉，
    // 0x4000_0000 段已由 DC 窗口吃掉，CPU 侧看到的只有 MMIO。故把这两路响应拉死。
    wire ram_req_valid, ram_req_write, ram_req_ready, ram_rsp_valid, ram_rsp_error;
    wire [1:0] ram_req_size;
    wire [31:0] ram_req_addr, ram_req_wdata, ram_rsp_rdata;
    wire [3:0] ram_req_wstrb;
    wire ddr_req_valid, ddr_req_write, ddr_req_ready, ddr_rsp_valid, ddr_rsp_error;
    wire [1:0] ddr_req_size;
    wire [31:0] ddr_req_addr, ddr_req_wdata, ddr_rsp_rdata;
    wire [3:0] ddr_req_wstrb;

    data_bus_interconnect #(
        .RAM_BASE(RESET_PC),
        .RAM_ADDR_MASK(32'hffff_c000),
        .MMIO_BASE(MMIO_BASE),
        .MMIO_ADDR_MASK(32'hffff_f000),
        .ENABLE_DDR(0),
        .DDR_BASE(DDR_BASE),
        .DDR_ADDR_MASK(DDR_ADDR_MASK),
        .ENABLE_CNN(ENABLE_CNN),
        .ENABLE_PREPROCESS(ENABLE_PREPROCESS),
        .ENABLE_CAMERA(ENABLE_CAMERA),
        .ENABLE_UART(1),
        .UART_BASE(UART_BASE),
        .ENABLE_GPIO(ENABLE_GPIO),
        .GPIO_BASE(GPIO_BASE)
    ) u_interconnect (
        .clk(clk), .resetn(resetn),
        .ddr_write_buffer_busy(1'b0),
        .m_req_valid(o_valid), .m_req_write(dreq_we), .m_req_size(dreq_size),
        .m_req_addr(dreq_addr), .m_req_wdata(dreq_wdata), .m_req_wstrb(dreq_wstrb),
        .m_req_ready(o_ready), .m_rsp_valid(o_rsp_valid), .m_rsp_rdata(o_rsp_rdata),
        .m_rsp_error(o_rsp_error),
        .ram_req_valid(ram_req_valid), .ram_req_write(ram_req_write), .ram_req_size(ram_req_size),
        .ram_req_addr(ram_req_addr), .ram_req_wdata(ram_req_wdata), .ram_req_wstrb(ram_req_wstrb),
        .ram_req_ready(ram_req_ready), .ram_rsp_valid(ram_rsp_valid), .ram_rsp_rdata(ram_rsp_rdata),
        .ram_rsp_error(ram_rsp_error),
        .mmio_req_valid(mmio_req_valid), .mmio_req_write(mmio_req_write), .mmio_req_size(mmio_req_size),
        .mmio_req_addr(mmio_req_addr), .mmio_req_wdata(mmio_req_wdata), .mmio_req_wstrb(mmio_req_wstrb),
        .mmio_req_ready(mmio_req_ready), .mmio_rsp_valid(mmio_rsp_valid), .mmio_rsp_rdata(mmio_rsp_rdata),
        .mmio_rsp_error(mmio_rsp_error),
        .ddr_req_valid(ddr_req_valid), .ddr_req_write(ddr_req_write), .ddr_req_size(ddr_req_size),
        .ddr_req_addr(ddr_req_addr), .ddr_req_wdata(ddr_req_wdata), .ddr_req_wstrb(ddr_req_wstrb),
        .ddr_req_ready(ddr_req_ready), .ddr_rsp_valid(ddr_rsp_valid), .ddr_rsp_rdata(ddr_rsp_rdata),
        .ddr_rsp_error(ddr_rsp_error),
        .uart_req_valid(uart_req_valid), .uart_req_write(uart_req_write), .uart_req_size(uart_req_size),
        .uart_req_addr(uart_req_addr), .uart_req_wdata(uart_req_wdata), .uart_req_wstrb(uart_req_wstrb),
        .uart_req_ready(uart_req_ready), .uart_rsp_valid(uart_rsp_valid), .uart_rsp_rdata(uart_rsp_rdata),
        .uart_rsp_error(uart_rsp_error),
        .gpio_req_valid(gpio_req_valid), .gpio_req_write(gpio_req_write), .gpio_req_size(gpio_req_size),
        .gpio_req_addr(gpio_req_addr), .gpio_req_wdata(gpio_req_wdata), .gpio_req_wstrb(gpio_req_wstrb),
        .gpio_req_ready(gpio_req_ready), .gpio_rsp_valid(gpio_rsp_valid), .gpio_rsp_rdata(gpio_rsp_rdata),
        .gpio_rsp_error(gpio_rsp_error),
        .cnn_req_valid(cnn_req_valid), .cnn_req_write(cnn_req_write), .cnn_req_size(cnn_req_size),
        .cnn_req_addr(cnn_req_addr), .cnn_req_wdata(cnn_req_wdata), .cnn_req_wstrb(cnn_req_wstrb),
        .cnn_req_ready(cnn_req_ready), .cnn_rsp_valid(cnn_rsp_valid), .cnn_rsp_error(cnn_rsp_error),
        .cnn_rsp_rdata(cnn_rsp_rdata),
        .pp_req_valid(pp_req_valid), .pp_req_write(pp_req_write), .pp_req_size(pp_req_size),
        .pp_req_addr(pp_req_addr), .pp_req_wdata(pp_req_wdata), .pp_req_wstrb(pp_req_wstrb),
        .pp_req_ready(pp_req_ready), .pp_rsp_valid(pp_rsp_valid), .pp_rsp_error(pp_rsp_error),
        .pp_rsp_rdata(pp_rsp_rdata),
        .preprocess_busy(preprocess_busy), .preprocess_done(preprocess_done),
        .cam_req_valid(cam_req_valid), .cam_req_write(cam_req_write), .cam_req_size(cam_req_size),
        .cam_req_addr(cam_req_addr), .cam_req_wdata(cam_req_wdata), .cam_req_wstrb(cam_req_wstrb),
        .cam_req_ready(cam_req_ready), .cam_rsp_valid(cam_rsp_valid), .cam_rsp_error(cam_rsp_error),
        .cam_rsp_rdata(cam_rsp_rdata),
        .camera_busy(camera_busy), .camera_dual_mode(camera_dual_mode),
        .camera_cpu_owned(camera_cpu_owned)
    );
    // RAM/DDR 通道在本设计里不会被选中，响应恒 0 即可
    assign ram_req_ready = 1'b0; assign ram_rsp_valid = 1'b0;
    assign ram_rsp_rdata = 32'd0; assign ram_rsp_error = 1'b0;
    assign ddr_req_ready = 1'b0; assign ddr_rsp_valid = 1'b0;
    assign ddr_rsp_rdata = 32'd0; assign ddr_rsp_error = 1'b0;

    // ---------------------------------------------------------------- MMIO 从设备
    simple_mmio #(.PERF_ENABLE(0)) u_simple_mmio (
        .clk(clk), .resetn(resetn),
        .req_valid(mmio_req_valid), .req_write(mmio_req_write), .req_size(mmio_req_size),
        .req_addr(mmio_req_addr), .req_wdata(mmio_req_wdata), .req_wstrb(mmio_req_wstrb),
        .req_ready(mmio_req_ready), .rsp_valid(mmio_rsp_valid), .rsp_rdata(mmio_rsp_rdata),
        .rsp_error(mmio_rsp_error),
        .test_status(selftest_status),
        .perf_events(8'd0), .perf_retire_pc(32'd0),
        .perf_branch_target(32'd0), .perf_fetch_pc(32'd0),
        .perf_ar_fire(1'b0), .perf_aw_fire(1'b0),
        .perf_cache_events(6'd0), .perf_cache_enabled(2'd0),
        .perf_wait_events(3'd0), .perf_diag_flags(15'd0),
        .perf_diag_target_pc(32'd0), .perf_diag_pending_pc(32'd0), .perf_diag_buffer_pc(32'd0),
        .perf_detail_cpu(16'd0), .perf_detail_bridge(16'd0)
    );
    uart_mmio #(.CLK_HZ(UART_CLK_HZ)) u_uart_mmio (
        .clk(clk), .resetn(resetn), .req_valid(uart_req_valid),
        .req_write(uart_req_write), .req_size(uart_req_size),
        .req_addr(uart_req_addr), .req_wdata(uart_req_wdata), .req_wstrb(uart_req_wstrb),
        .req_ready(uart_req_ready), .rsp_valid(uart_rsp_valid),
        .rsp_rdata(uart_rsp_rdata), .rsp_error(uart_rsp_error),
        .uart_rx(uart_rx), .uart_tx(uart_tx), .uart_irq(uart_irq)
    );
    gpio_mmio #(.GPIO_WIDTH(GPIO_WIDTH)) u_gpio_mmio (
        .clk(clk), .resetn(resetn),
        .req_valid(gpio_req_valid), .req_write(gpio_req_write),
        .req_size(gpio_req_size), .req_addr(gpio_req_addr),
        .req_wdata(gpio_req_wdata), .req_wstrb(gpio_req_wstrb),
        .req_ready(gpio_req_ready), .rsp_valid(gpio_rsp_valid),
        .rsp_rdata(gpio_rsp_rdata), .rsp_error(gpio_rsp_error),
        .gpio_in(gpio_in), .gpio_out(gpio_out), .gpio_dir(gpio_dir),
        .gpio_irq(gpio_irq_i)
    );
    assign gpio_irq = gpio_irq_i;
endmodule
