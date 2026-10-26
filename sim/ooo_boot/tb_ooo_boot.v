// ============================================================================
// tb_ooo_boot  --  验证乱序核能从我们的 ROM 取指、能读写我们的 RAM
//
// 只实例化最容易出错、且不依赖任何厂家 IP 的部分：
//   ooo_core + ooo_ibus + ooo_dbus + ooo_tcm(ROM 镜像) + ooo_tcm(RAM 镜像)
// Cache 口打桩为"永不就绪"（Loader 前半段不访问 DDR），I/O 口打桩为
// "下一拍固定返回 0"，这样 Loader 轮询 UART 时不会卡死。
//
// 通过判据（仿真结束时打印 + assert）：
//   1. 指令取指响应次数 > 50        （ROM 初始化 + 64 位取指 + 偶/奇配对正确）
//   2. RAM 写次数 > 0               （数据侧 TCM 与 dreq_* 越级接线正确）
//   3. 没有进入 trap                （取指/数据通路没有异常）
//   4. PC 落在 0x0~0x3FFF 内        （确实在 ROM 里跑 Loader）
// ============================================================================
`timescale 1ns / 1ps

module tb_ooo_boot;
    reg clk = 0, resetn = 0;
    always #5 clk = ~clk;              // 100 MHz 级别，只是跑逻辑

    // ---- core 接口 ----
    wire        ireq_valid, ireq_ready, irsp_valid, irsp_error;
    wire [31:0] ireq_addr;
    wire [63:0] irsp_data;
    wire        dreq_valid, dreq_we, dreq_ready, drsp_valid, drsp_error;
    wire [31:0] dreq_addr, dreq_wdata, drsp_rdata;
    wire [3:0]  dreq_wstrb;
    wire [1:0]  dreq_size;
    wire        cmo_req, cmo_done;
    wire        dbg_trap;
    wire [4:0]  dbg_c0_pdst;
    wire [3:0]  dbg_c0_wen;

    // ---- 统计 ----
    integer fetch_rsp = 0, ram_wr = 0, mmio_acc = 0, trap_count = 0, i_valid_cnt = 0;
    integer fetch_err = 0, data_err = 0, pc_prints = 0, pc_hist_n = 0, k;
    reg [31:0] pc_hist [0:63];
    reg [31:0] prev_pc = 32'hffffffff;
    wire [31:0] last_pc;

    // ---- ibus ----
    wire        ti_valid, ti_rsp_valid;
    wire [31:0] ti_addr;
    wire [63:0] ti_rsp_data;
    wire        ic_valid, ic_ready, ic_rsp_valid, ic_rsp_error;
    wire [63:0] ic_rsp_data;

    // ---- dbus ----
    wire        td_valid, td_rsp_valid, o_valid, o_ready, o_rsp_valid, o_rsp_error;
    wire [31:0] td_addr, td_rsp_rdata, o_rsp_rdata;
    wire        dc_valid, dc_ready, dc_rsp_valid, dc_rsp_error;
    wire [31:0] dc_rsp_rdata;

    // I/O 口打桩：接受请求，下一拍返回 0（模拟"寄存器读回 0"）
    reg o_rsp_valid_q = 0;
    reg [31:0] o_rsp_rdata_q = 0;
    always @(posedge clk) begin
        o_rsp_valid_q <= o_valid && o_ready;
        o_rsp_rdata_q <= 32'd0;
    end
    assign o_ready     = 1'b1;
    assign o_rsp_valid = o_rsp_valid_q;
    assign o_rsp_rdata = o_rsp_rdata_q;
    assign o_rsp_error = 1'b0;
    always @(posedge clk) if (o_valid && o_ready) mmio_acc <= mmio_acc + 1;

    ooo_core #(.RESET_PC(32'h0000_0000)) u_core (
        .clk(clk), .resetn(resetn),
        .irq_external(1'b0), .irq_software(1'b0), .irq_timer(1'b0),
        .ireq_valid(ireq_valid), .ireq_addr(ireq_addr), .ireq_ready(ireq_ready),
        .irsp_valid(irsp_valid), .irsp_data(irsp_data), .irsp_error(irsp_error),
        .dreq_valid(dreq_valid), .dreq_we(dreq_we), .dreq_addr(dreq_addr), .dreq_wdata(dreq_wdata),
        .dreq_wstrb(dreq_wstrb), .dreq_size(dreq_size), .dreq_ready(dreq_ready),
        .drsp_valid(drsp_valid), .drsp_rdata(drsp_rdata), .drsp_error(drsp_error),
        .cmo_req(cmo_req), .cmo_done(cmo_done),
        .dbg_cvalid(), .dbg_c0_pc(last_pc), .dbg_c1_pc(), .dbg_c0_wen(dbg_c0_wen),
        .dbg_c1_wen(), .dbg_c0_rd(), .dbg_c1_rd(), .dbg_c0_pdst(dbg_c0_pdst),
        .dbg_c1_pdst(), .dbg_trap(dbg_trap), .perf_ev()
    );
    // FENCE.I 的 CMO：Cache 打桩里没有 flush，直接放行
    assign cmo_done = cmo_req;

    ooo_ibus #(.TCM_BASE(32'h0), .TCM_MASK(32'hffff_c000), .HAS_IC(1),
               .IC_BASE(32'h4000_0000), .IC_MASK(32'he000_0000)) u_ibus (
        .clk(clk), .resetn(resetn),
        .m_valid(ireq_valid), .m_addr(ireq_addr), .m_ready(ireq_ready),
        .m_rsp_valid(irsp_valid), .m_rsp_data(irsp_data), .m_rsp_error(irsp_error),
        .t_valid(ti_valid), .t_addr(ti_addr), .t_rsp_valid(ti_rsp_valid), .t_rsp_data(ti_rsp_data),
        .c_valid(ic_valid), .c_ready(ic_ready), .c_rsp_valid(ic_rsp_valid), .c_rsp_data(ic_rsp_data),
        .c_rsp_error(ic_rsp_error)
    );
    // Cache 口：永不就绪（本仿真不该有 DDR 访问）
    assign ic_ready = 1'b0; assign ic_rsp_valid = 1'b0;
    assign ic_rsp_data = 64'd0; assign ic_rsp_error = 1'b0;

    ooo_dbus #(.TCM_BASE(32'h0), .TCM_MASK(32'hffff_c000), .HAS_DC(1),
               .DC_BASE(32'h4000_0000), .DC_MASK(32'he000_0000),
               .IO_BASE(32'h1000_0000), .IO_MASK(32'hffff_0000)) u_dbus (
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
    assign dc_ready = 1'b0; assign dc_rsp_valid = 1'b0;
    assign dc_rsp_rdata = 32'd0; assign dc_rsp_error = 1'b0;

    // ROM：Loader 指令（只用指令口）
    ooo_tcm #(.BYTES(16384),
              .INIT_EVEN("D:/riscv/RISCV/myriscv_ooo/img/rom_even.hex"),
              .INIT_ODD ("D:/riscv/RISCV/myriscv_ooo/img/rom_odd.hex")) u_rom (
        .clk(clk), .resetn(resetn),
        .i_valid(ti_valid), .i_addr(ti_addr), .i_rsp_valid(ti_rsp_valid), .i_rsp_data(ti_rsp_data),
        .d_valid(1'b0), .d_we(1'b0), .d_addr(32'd0), .d_wdata(32'd0), .d_wstrb(4'd0),
        .d_rsp_valid(), .d_rsp_rdata()
    );

    // RAM：Loader 的 .rodata/.bss/栈（只用数据口，写数据从 dreq_* 越级接）
    ooo_tcm #(.BYTES(16384),
              .INIT_EVEN("D:/riscv/RISCV/myriscv_ooo/img/ram_even.hex"),
              .INIT_ODD ("D:/riscv/RISCV/myriscv_ooo/img/ram_odd.hex")) u_ram (
        .clk(clk), .resetn(resetn),
        .i_valid(1'b0), .i_addr(32'd0), .i_rsp_valid(), .i_rsp_data(),
        .d_valid(td_valid), .d_we(dreq_we), .d_addr(td_addr), .d_wdata(dreq_wdata),
        .d_wstrb(dreq_wstrb), .d_rsp_valid(td_rsp_valid), .d_rsp_rdata(td_rsp_rdata)
    );

    // ---- 统计与判据 ----
    always @(posedge clk) begin
        if (resetn) begin
            if (ti_valid) i_valid_cnt <= i_valid_cnt + 1;
            if (last_pc !== prev_pc) begin
                pc_hist[pc_hist_n % 64] <= last_pc;
                pc_hist_n = pc_hist_n + 1;
                prev_pc <= last_pc;
                if (pc_prints < 0) begin
                    pc_prints <= pc_prints + 1;
                    $display("  PC[%0d] = 0x%08x  (t=%0t)", pc_prints, last_pc, $time);
                end
            end
            if (irsp_error) begin
                fetch_err <= fetch_err + 1;
                if (fetch_err < 6) $display("FETCH_ERR #%0d addr=0x%08x", fetch_err, ireq_addr);
            end
            if (drsp_error) begin
                data_err <= data_err + 1;
                if (data_err < 6) $display("DATA_ERR  #%0d addr=0x%08x we=%b", data_err, dreq_addr, dreq_we);
            end
            if (irsp_valid) fetch_rsp <= fetch_rsp + 1;
            if (td_valid && dreq_we) ram_wr <= ram_wr + 1;
            if (dbg_trap) trap_count <= trap_count + 1;
        end
    end

    integer i;
    initial begin
        if ($test$plusargs("dump")) begin end
        $display("TB: 复位中...");
        repeat (8) @(posedge clk);
        resetn = 1;
        $display("TB: 释放复位，开始执行");
        repeat (100000) @(posedge clk);

        $display("--- trap diagnostics @0x1080 ---");
        $display(" [0x1080] cause = 0x%08x", tb_ooo_boot.u_ram.u_even.mem[12'h210]);
        $display(" [0x1084] tval  = 0x%08x", tb_ooo_boot.u_ram.u_odd.mem[12'h210]);
        $display(" [0x1088] epc   = 0x%08x", tb_ooo_boot.u_ram.u_even.mem[12'h211]);
        $display(" [0x108c]      = 0x%08x", tb_ooo_boot.u_ram.u_odd.mem[12'h211]);        $display("--- last PCs (oldest->newest) ---");
        for (k = 0; k < 64; k = k + 1)
            $display("  pc_hist[%0d] = 0x%08x", k, pc_hist[(pc_hist_n + k) % 64]);
        $display("=================================================");
        $display(" fetch_rsp = %0d", fetch_rsp);
        $display(" last_pc   = 0x%08x", last_pc);
        $display(" ram_wr    = %0d", ram_wr);
        $display(" mmio_acc  = %0d", mmio_acc);
        $display(" trap_cnt  = %0d  fetch_err = %0d  data_err = %0d", trap_count, fetch_err, data_err);
        $display(" last_pc   = 0x%08x", last_pc);
        $display(" i_valid_c = %0d  ireq_addr = 0x%08x", i_valid_cnt, ireq_addr);
        $display(" rom_even[0]=0x%08x rom_odd[0]=0x%08x", tb_ooo_boot.u_rom.u_even.mem[0], tb_ooo_boot.u_rom.u_odd.mem[0]);
        $display(" rom_even[1]=0x%08x rom_odd[1]=0x%08x", tb_ooo_boot.u_rom.u_even.mem[1], tb_ooo_boot.u_rom.u_odd.mem[1]);
        $display(" ram_even[0]=0x%08x ram_odd[0]=0x%08x", tb_ooo_boot.u_ram.u_even.mem[0], tb_ooo_boot.u_ram.u_odd.mem[0]);
        $display("--- trap diagnostics @0x1080 ---");
        $display(" [0x1080] cause = 0x%08x", tb_ooo_boot.u_ram.u_even.mem[12'h210]);
        $display(" [0x1084] tval  = 0x%08x", tb_ooo_boot.u_ram.u_odd.mem[12'h210]);
        $display(" [0x1088] epc   = 0x%08x", tb_ooo_boot.u_ram.u_even.mem[12'h211]);
        $display(" [0x108c]      = 0x%08x", tb_ooo_boot.u_ram.u_odd.mem[12'h211]);        $display("--- last PCs (oldest->newest) ---");
        for (k = 0; k < 64; k = k + 1)
            $display("  pc_hist[%0d] = 0x%08x", k, pc_hist[(pc_hist_n + k) % 64]);
        $display("=================================================");
        if (fetch_rsp < 50)  $display("FAIL: 取指太少，ROM 初始化或 64 位取指有问题");
        else if (ram_wr == 0) $display("FAIL: 没有任何 RAM 写，数据侧接线有问题");
        else if (trap_count != 0) $display("FAIL: 进入了 trap");
        else if (last_pc > 32'h3fff) $display("FAIL: PC 跑出 ROM 窗口");
        else $display("PASS: 从 ROM 取指并读写 RAM 正常");
        $finish;
    end
endmodule
