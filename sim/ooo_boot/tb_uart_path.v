// ============================================================================
// tb_uart_path  --  真实 UART 打印路径的长时压力测试
//
// 路径：CPU 侧（135MHz）→ mmio_cdc_bridge → data_bus_interconnect → uart_mmio → uart_tx
// 完全按 BSP 的 putchar 语义驱动：
//   1) 轮询 STATUS(0x1000_1008) 的 bit0(tx_ready)
//   2) 用**字节写**（req_size=0）写 TX_DATA(0x1000_1000)
//
// 目的：复现在板上观察到的"打印中途停住"。若某次轮询永远等不到 tx_ready，
// 本测试会报出是第几个字符、以及当时的 STATUS 值。
// ============================================================================
`timescale 1ns / 1ps

module tb_uart_path;
    reg clk = 0, cpu_clk = 0, resetn = 0, cpu_resetn = 0;
    always #5.33 clk = ~clk;         // 93.75 MHz
    always #3.70 cpu_clk = ~cpu_clk; // ~135 MHz

    // ---- CPU 侧请求 ----
    reg         req_valid = 0, req_write = 0;
    reg  [1:0]  req_size = 2'd2;
    reg  [31:0] req_addr = 0, req_wdata = 0;
    reg  [3:0]  req_wstrb = 4'hf;
    wire        req_ready, rsp_valid, rsp_error;
    wire [31:0] rsp_rdata;

    // ---- 桥 ----
    wire        c_v, c_w, c_rdy, c_rv, c_re;
    wire [1:0]  c_sz;
    wire [31:0] c_a, c_d, c_rd;
    wire [3:0]  c_st;

    mmio_cdc_bridge u_bridge (
        .cpu_clk(cpu_clk), .cpu_resetn(cpu_resetn),
        .cpu_req_valid(req_valid), .cpu_req_write(req_write), .cpu_req_size(req_size),
        .cpu_req_addr(req_addr), .cpu_req_wdata(req_wdata), .cpu_req_wstrb(req_wstrb),
        .cpu_req_ready(req_ready),
        .cpu_rsp_valid(rsp_valid), .cpu_rsp_rdata(rsp_rdata), .cpu_rsp_error(rsp_error),
        .core_clk(clk), .core_resetn(resetn),
        .core_req_valid(c_v), .core_req_write(c_w), .core_req_size(c_sz),
        .core_req_addr(c_a), .core_req_wdata(c_d), .core_req_wstrb(c_st),
        .core_req_ready(c_rdy),
        .core_rsp_valid(c_rv), .core_rsp_rdata(c_rd), .core_rsp_error(c_re)
    );

    // ---- 互连（只启用 UART）----
    wire ua_v, ua_w, ua_rdy, ua_rv, ua_re;
    wire [1:0] ua_sz;
    wire [31:0] ua_a, ua_d, ua_rd;
    wire [3:0] ua_st;
    wire mm_v, mm_w, mm_rdy, mm_rv, mm_re;
    wire [1:0] mm_sz; wire [31:0] mm_a, mm_d, mm_rd; wire [3:0] mm_st;
    wire [1:0] test_status;
    wire uart_tx_w, uart_irq_w;

    data_bus_interconnect #(
        .RAM_BASE(32'h0), .RAM_ADDR_MASK(32'hffff_c000),
        .MMIO_BASE(32'h1000_0000), .MMIO_ADDR_MASK(32'hffff_f000),
        .ENABLE_DDR(0), .ENABLE_CNN(0), .ENABLE_PREPROCESS(0), .ENABLE_CAMERA(0),
        .ENABLE_UART(1), .UART_BASE(32'h1000_1000), .ENABLE_GPIO(0)
    ) u_ic (
        .clk(clk), .resetn(resetn), .ddr_write_buffer_busy(1'b0),
        .m_req_valid(c_v), .m_req_write(c_w), .m_req_size(c_sz),
        .m_req_addr(c_a), .m_req_wdata(c_d), .m_req_wstrb(c_st),
        .m_req_ready(c_rdy), .m_rsp_valid(c_rv), .m_rsp_rdata(c_rd), .m_rsp_error(c_re),
        .ram_req_valid(), .ram_req_write(), .ram_req_size(), .ram_req_addr(), .ram_req_wdata(),
        .ram_req_wstrb(), .ram_req_ready(1'b0), .ram_rsp_valid(1'b0), .ram_rsp_rdata(32'd0), .ram_rsp_error(1'b0),
        .mmio_req_valid(mm_v), .mmio_req_write(mm_w), .mmio_req_size(mm_sz), .mmio_req_addr(mm_a),
        .mmio_req_wdata(mm_d), .mmio_req_wstrb(mm_st), .mmio_req_ready(mm_rdy),
        .mmio_rsp_valid(mm_rv), .mmio_rsp_rdata(mm_rd), .mmio_rsp_error(mm_re),
        .ddr_req_valid(), .ddr_req_write(), .ddr_req_size(), .ddr_req_addr(), .ddr_req_wdata(),
        .ddr_req_wstrb(), .ddr_req_ready(1'b0), .ddr_rsp_valid(1'b0), .ddr_rsp_rdata(32'd0), .ddr_rsp_error(1'b0),
        .uart_req_valid(ua_v), .uart_req_write(ua_w), .uart_req_size(ua_sz), .uart_req_addr(ua_a),
        .uart_req_wdata(ua_d), .uart_req_wstrb(ua_st), .uart_req_ready(ua_rdy),
        .uart_rsp_valid(ua_rv), .uart_rsp_rdata(ua_rd), .uart_rsp_error(ua_re),
        .gpio_req_valid(), .gpio_req_write(), .gpio_req_size(), .gpio_req_addr(), .gpio_req_wdata(),
        .gpio_req_wstrb(), .gpio_req_ready(1'b0), .gpio_rsp_valid(1'b0), .gpio_rsp_rdata(32'd0), .gpio_rsp_error(1'b0),
        .cnn_req_valid(), .cnn_req_write(), .cnn_req_size(), .cnn_req_addr(), .cnn_req_wdata(),
        .cnn_req_wstrb(), .cnn_req_ready(1'b0), .cnn_rsp_valid(1'b0), .cnn_rsp_error(1'b0), .cnn_rsp_rdata(32'd0),
        .pp_req_valid(), .pp_req_write(), .pp_req_size(), .pp_req_addr(), .pp_req_wdata(),
        .pp_req_wstrb(), .pp_req_ready(1'b0), .pp_rsp_valid(1'b0), .pp_rsp_error(1'b0), .pp_rsp_rdata(32'd0),
        .preprocess_busy(1'b0), .preprocess_done(1'b0),
        .cam_req_valid(), .cam_req_write(), .cam_req_size(), .cam_req_addr(), .cam_req_wdata(),
        .cam_req_wstrb(), .cam_req_ready(1'b0), .cam_rsp_valid(1'b0), .cam_rsp_error(1'b0), .cam_rsp_rdata(32'd0),
        .camera_busy(1'b0), .camera_dual_mode(1'b0), .camera_cpu_owned(2'b0)
    );

    // uart_mmio 用较快的 BAUD，让 500 个字符能在可接受的仿真时间里跑完
    uart_mmio #(.CLK_HZ(93_750_000), .BAUD(500_000)) u_uart (
        .clk(clk), .resetn(resetn),
        .req_valid(ua_v), .req_write(ua_w), .req_size(ua_sz), .req_addr(ua_a),
        .req_wdata(ua_d), .req_wstrb(ua_st), .req_ready(ua_rdy),
        .rsp_valid(ua_rv), .rsp_rdata(ua_rd), .rsp_error(ua_re),
        .uart_rx(1'b1), .uart_tx(uart_tx_w), .uart_irq(uart_irq_w)
    );

    // ---- CPU 侧驱动：完全照 putchar 的语义 ----
    integer i, waited, chars = 0, stalls = 0, errs = 0;
    reg [31:0] st;

    task cpu_xfer(input reg w, input [1:0] sz, input [31:0] a, input [31:0] d,
                  output [31:0] rd, output err, input integer max_wait);
        integer w2;
        begin
            @(posedge cpu_clk);
            req_valid <= 1; req_write <= w; req_size <= sz; req_addr <= a; req_wdata <= d;
            req_wstrb <= (sz == 2'd0) ? 4'h1 : 4'hf;
            w2 = 0;
            while (!req_ready && w2 < max_wait) begin @(posedge cpu_clk); w2 = w2 + 1; end
            if (w2 >= max_wait) begin stalls = stalls + 1; err = 1; rd = 0; req_valid <= 0; end
            else begin
                @(posedge cpu_clk);
                req_valid <= 0;
                w2 = 0;
                while (!rsp_valid && w2 < max_wait) begin @(posedge cpu_clk); w2 = w2 + 1; end
                if (w2 >= max_wait) begin stalls = stalls + 1; err = 1; rd = 0; end
                else begin rd = rsp_rdata; err = rsp_error; end
                @(posedge cpu_clk);
            end
        end
    endtask

    reg err; reg [31:0] rd;
    initial begin
        repeat (8) @(posedge cpu_clk);
        resetn = 1; cpu_resetn = 1;
        repeat (8) @(posedge cpu_clk);

        for (i = 0; i < 500; i = i + 1) begin
            // 1) 轮询 tx_ready
            waited = 0;
            rd = 0;
            while (waited < 200000 && ((rd & 1) == 0)) begin
                cpu_xfer(1'b0, 2'd2, 32'h1000_1008, 32'd0, rd, err, 400);
                waited = waited + 1;
                if (stalls > 0) begin
                    $display("STALL at char %0d during status poll (i=%0d)", chars, i);
                    i = 500; waited = 200001;
                end
            end
            if (waited >= 200000) begin
                $display("TIMEOUT polling tx_ready at char %0d, last status=0x%08x", chars, rd);
                stalls = stalls + 1;
                i = 500;
            end else begin
                // 2) 字节写 TX_DATA
                cpu_xfer(1'b1, 2'd0, 32'h1000_1000, 32'h41 + i, rd, err, 400);
                if (err) begin
                    $display("BUS ERROR on TX write at char %0d", chars);
                    errs = errs + 1;
                    i = 500;
                end else chars = chars + 1;
            end
        end

        $display("=================================================");
        $display(" chars=%0d  stalls=%0d  errs=%0d", chars, stalls, errs);
        if (stalls == 0 && errs == 0) $display("PASS: UART 打印路径 %0d 个字符无停摆", chars);
        else                          $display("FAIL: stalls=%0d errs=%0d", stalls, errs);
        $finish;
    end
endmodule
