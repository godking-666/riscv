// ============================================================================
// tb_ooo_soc_uart  --  整体 SoC 仿真：验证"Loader 能应答 PING"
//
// 实例化**完整的 ooo_soc_top**（乱序核 + 双 Cache + DDR 口 + 两个 TCM +
// MMIO 跨域桥 + 我们的 data_bus_interconnect + uart_mmio + gpio_mmio），
// 不例化任何厂家 IP（mul 用 simrtl/mul.v 行为模型），因此可直接用 ModelSim 跑。
//
// 时钟按同比例缩小以控制仿真周期数，**跨域比例与实物一致**：
//   实物 clk=93.75MHz / cpu_clk=135MHz  -> 比例 1.44
//   仿真 clk=6.25MHz (160ns) / cpu_clk=9MHz (111.1ns) -> 比例 1.44
//   UART_CLK_HZ 同步设为 6.25MHz，分频系数随之缩放，Loader 的周期级超时行为不变
//
// 判据：向 uart_rx 打入 36 字节 PING，uart_tx 必须回出 60 字节且开头为
//       'R''V''L''D' 01 80
// ============================================================================
`timescale 1ns / 1ps

module tb_ooo_soc_trace;
    // ---- 两个时钟：比例 1.44，与实物 135/93.75 一致 ----
    reg clk = 0, cpu_clk = 0;
    always #80   clk     = ~clk;        // 160 ns -> 6.25 MHz
    always #55.55 cpu_clk = ~cpu_clk;   // 111.1 ns -> 9 MHz

    reg resetn = 0, cpu_reset_req = 0;
    reg uart_rx = 1;

    wire uart_tx;
    wire [7:0] gpio_out, gpio_dir;
    wire gpio_irq, selftest0, selftest1;
    wire [1:0] selftest_status = {selftest1, selftest0};
    wire [31:0] dbg_pc;
    wire [3:0]  dbg_we;
    wire [4:0]  dbg_wnum;
    wire [31:0] dbg_wdata, dbg_inst;

    // MMIO 从设备通道（本仿真把相机/PP/CNN 关掉，互连不会选中它们）
    wire cnn_v, cnn_w, pp_v, pp_w, cam_v, cam_w;
    wire [1:0] cnn_sz, pp_sz, cam_sz;
    wire [31:0] cnn_a, cnn_d, pp_a, pp_d, cam_a, cam_d;
    wire [3:0] cnn_st, pp_st, cam_st;

    ooo_soc_top #(
        .RESET_PC(32'h0000_0000),
        .ENABLE_CNN(0), .ENABLE_PREPROCESS(0), .ENABLE_CAMERA(0), .ENABLE_GPIO(1),
        .CLK_HZ(6_250_000),
        .ROM_INIT_EVEN("D:/riscv/RISCV/myriscv_ooo/img_trace/rom_even.hex"),
        .ROM_INIT_ODD ("D:/riscv/RISCV/myriscv_ooo/img_trace/rom_odd.hex"),
        .RAM_INIT_EVEN("D:/riscv/RISCV/myriscv_ooo/img_trace/ram_even.hex"),
        .RAM_INIT_ODD ("D:/riscv/RISCV/myriscv_ooo/img_trace/ram_odd.hex"),
        .UART_CLK_HZ(6_250_000),
        .GPIO_WIDTH(8)
    ) u_soc (
        .cnn_req_valid(cnn_v), .cnn_req_write(cnn_w), .cnn_req_size(cnn_sz),
        .cnn_req_addr(cnn_a), .cnn_req_wdata(cnn_d), .cnn_req_wstrb(cnn_st),
        .cnn_req_ready(1'b0), .cnn_rsp_valid(1'b0), .cnn_rsp_error(1'b0), .cnn_rsp_rdata(32'd0),
        .pp_req_valid(pp_v), .pp_req_write(pp_w), .pp_req_size(pp_sz),
        .pp_req_addr(pp_a), .pp_req_wdata(pp_d), .pp_req_wstrb(pp_st),
        .pp_req_ready(1'b0), .pp_rsp_valid(1'b0), .pp_rsp_error(1'b0), .pp_rsp_rdata(32'd0),
        .preprocess_busy(1'b0), .preprocess_done(1'b0),
        .cam_req_valid(cam_v), .cam_req_write(cam_w), .cam_req_size(cam_sz),
        .cam_req_addr(cam_a), .cam_req_wdata(cam_d), .cam_req_wstrb(cam_st),
        .cam_req_ready(1'b0), .cam_rsp_valid(1'b0), .cam_rsp_error(1'b0), .cam_rsp_rdata(32'd0),
        .camera_busy(1'b0), .camera_dual_mode(1'b0), .camera_cpu_owned(2'b0),
        .clk(clk), .resetn(resetn),
        .cpu_clk(cpu_clk), .cpu_reset_req(cpu_reset_req),
        .irq_external(1'b0), .irq_software(1'b0), .irq_timer(1'b0),
        .debug_wb_pc(dbg_pc), .debug_wb_rf_we(dbg_we), .debug_wb_rf_wnum(dbg_wnum),
        .debug_wb_rf_wdata(dbg_wdata), .debug_inst(dbg_inst),
        .ddr_init_done(1'b1),
        .ddr_axi_awaddr(), .ddr_axi_awuser_ap(), .ddr_axi_awuser_id(), .ddr_axi_awlen(),
        .ddr_axi_awready(1'b1), .ddr_axi_awvalid(), .ddr_axi_wdata(), .ddr_axi_wstrb(),
        .ddr_axi_wready(1'b1), .ddr_axi_wusero_id(4'd0), .ddr_axi_wusero_last(1'b0),
        .ddr_axi_araddr(), .ddr_axi_aruser_ap(), .ddr_axi_aruser_id(), .ddr_axi_arlen(),
        .ddr_axi_arready(1'b1), .ddr_axi_arvalid(), .ddr_axi_rdata(256'd0), .ddr_axi_rid(4'd0),
        .ddr_axi_rlast(1'b0), .ddr_axi_rvalid(1'b0),
        .selftest_status(selftest_status),
        .uart_rx(uart_rx), .uart_tx(uart_tx),
        .gpio_in(8'd0), .gpio_out(gpio_out), .gpio_dir(gpio_dir), .gpio_irq(gpio_irq)
    );

    // ---------------------------------------------------------------- UART 收发模型
    // 6.25 MHz / 115200 ≈ 54.25 clk/bit，取 54 拍
    localparam integer BIT_CYCLES = 54;

    task send_byte(input [7:0] b);
        integer i;
        begin
            uart_rx = 1'b0;                       // start
            repeat (BIT_CYCLES) @(posedge clk);
            for (i = 0; i < 8; i = i + 1) begin
                uart_rx = b[i];
                repeat (BIT_CYCLES) @(posedge clk);
            end
            uart_rx = 1'b1;                       // stop
            repeat (BIT_CYCLES) @(posedge clk);
        end
    endtask

    // 收字节：在 start 位中点开始，逐位中点采样
    integer rx_count = 0;
    reg [7:0] rx_bytes [0:63];
    initial begin : rx_monitor
        reg [7:0] v;
        integer i;
        forever begin
            @(negedge uart_tx);                   // start 位
            repeat (BIT_CYCLES / 2) @(posedge clk);
            for (i = 0; i < 8; i = i + 1) begin
                repeat (BIT_CYCLES) @(posedge clk);
                v[i] = uart_tx;
            end
            if (rx_count < 64) begin
                rx_bytes[rx_count] = v;
                rx_count = rx_count + 1;
            end
        end
    end

    // ---------------------------------------------------------------- 主流程
    integer k;
    reg ok;
    initial begin
        resetn = 0; cpu_reset_req = 0;
        repeat (20) @(posedge clk);
        resetn = 1;
        repeat (20) @(posedge cpu_clk);
        cpu_reset_req = 1;
        $display("TB: 释放复位，等待 Loader 启动");
        repeat (2000) @(posedge clk);

        // PING 帧（36 字节，取自 tools/cnn_digits_stream/probe_loader.py）
        send_byte(8'h52); send_byte(8'h56); send_byte(8'h4c); send_byte(8'h44);
        send_byte(8'h01); send_byte(8'h01); send_byte(8'h00); send_byte(8'h00);
        send_byte(8'h01); send_byte(8'h00);
        for (k = 0; k < 22; k = k + 1) send_byte(8'h00);
        send_byte(8'h32); send_byte(8'hff); send_byte(8'h73); send_byte(8'h31);

        $display("TB: PING 已发出，等待应答...");
        repeat (4000) @(posedge clk);

        $display("--- CRC trace @0x60 (i=0:length, 1..n: per-byte crc, 16: next byte, 17: n) ---");
        for (k = 0; k < 18; k = k + 1) begin
            if ((k % 2) == 0)
                $display("  trace[%0d] = %08x", k, u_soc.u_ram_tcm.u_even.mem[12'h0C + (k/2)]);
            else
                $display("  trace[%0d] = %08x", k, u_soc.u_ram_tcm.u_odd.mem[12'h0C + (k/2)]);
        end        $display("=================================================");
        $display(" 收到字节数 = %0d（期望 60）", rx_count);
        $display(" 前 6 字节 : %02x %02x %02x %02x %02x %02x",
                 rx_bytes[0], rx_bytes[1], rx_bytes[2], rx_bytes[3], rx_bytes[4], rx_bytes[5]);
        $display(" last_pc   = 0x%08x", dbg_pc);
        // Loader 上电自检结果：0x10B0 = loader_boot_error（bit0=BSS, bit1=常量CRC, bit2=CRC32）
        $display(" boot_error= 0x%08x   (0x10B0)", u_soc.u_ram_tcm.u_even.mem[12'h216]);
        // loader_diagnostics 在 0x20：+0=XOR结果, +4=crc32("123456789"), +8=crc32(len=0), +12=boot_error副本
        $display(" diag[0x20]=%08x diag[0x24]=%08x diag[0x28]=%08x diag[0x2c]=%08x",
                 u_soc.u_ram_tcm.u_even.mem[12'h004], u_soc.u_ram_tcm.u_even.mem[12'h004],
                 u_soc.u_ram_tcm.u_odd.mem[12'h004], u_soc.u_ram_tcm.u_odd.mem[12'h004]);
        $display(" diag0=%08x diag1=%08x diag2=%08x",
                 u_soc.u_ram_tcm.u_even.mem[12'd4], u_soc.u_ram_tcm.u_odd.mem[12'd4],
                 u_soc.u_ram_tcm.u_even.mem[12'd5]);        $display(" bss_probe = %08x %08x %08x %08x", u_soc.u_ram_tcm.u_even.mem[12'h212],
                 u_soc.u_ram_tcm.u_odd.mem[12'h212], u_soc.u_ram_tcm.u_even.mem[12'h213],
                 u_soc.u_ram_tcm.u_odd.mem[12'h213]);
        $display(" const[0x100]=%08x const[0x104]=%08x const[0x108]=%08x const[0x10c]=%08x",
                 u_soc.u_ram_tcm.u_even.mem[12'h200], u_soc.u_ram_tcm.u_odd.mem[12'h200],
                 u_soc.u_ram_tcm.u_even.mem[12'h201], u_soc.u_ram_tcm.u_odd.mem[12'h201]);
        $display("--- CRC trace @0x60 (i=0:length, 1..n: per-byte crc, 16: next byte, 17: n) ---");
        for (k = 0; k < 18; k = k + 1) begin
            if ((k % 2) == 0)
                $display("  trace[%0d] = %08x", k, u_soc.u_ram_tcm.u_even.mem[12'h0C + (k/2)]);
            else
                $display("  trace[%0d] = %08x", k, u_soc.u_ram_tcm.u_odd.mem[12'h0C + (k/2)]);
        end        $display("=================================================");
        ok = (rx_count >= 60) &&
             (rx_bytes[0] == 8'h52) && (rx_bytes[1] == 8'h56) &&
             (rx_bytes[2] == 8'h4c) && (rx_bytes[3] == 8'h44) &&
             (rx_bytes[4] == 8'h01) && (rx_bytes[5] == 8'h80);
        if (ok) $display("PASS: Loader 正确应答 PING (RVLD 01 80 ...)");
        else    $display("FAIL: Loader 未正确应答");
        $finish;
    end
endmodule
