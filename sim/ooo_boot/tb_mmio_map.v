// ============================================================================
// tb_mmio_map  --  验证 data_bus_interconnect 的地址映射
//
// 固件依赖的地址表（与 tests/cnn_digits_stream/main.c 的 #define 一致）：
//   0x1000_0008  CYCLE（simple_mmio，只读、递增）
//   0x1000_1000  UART  数据口（uart_mmio）
//   0x1000_1004  UART  状态
//   0x1000_5000  GPIO
//   0x1000_2000  相机（本 TB 关掉 ENABLE_CAMERA -> 应返回 error）
//
// 判据：CYCLE 非零且两次读递增；UART 写不报错、状态读不报错；GPIO 读不报错；
//       未映射地址必须 rsp_error=1（固件靠这个行为判断设备存在）
// ============================================================================
`timescale 1ns / 1ps

module tb_mmio_map;
    reg clk = 0, resetn = 0;
    always #5 clk = ~clk;

    reg         req_valid = 0, req_write = 0;
    reg  [1:0]  req_size = 2'd2;
    reg  [31:0] req_addr = 0, req_wdata = 0;
    reg  [3:0]  req_wstrb = 4'hf;
    wire        req_ready, rsp_valid, rsp_error;
    wire [31:0] rsp_rdata;

    // 从设备通道
    wire mm_v, mm_w, mm_rdy, mm_rv, mm_re; wire [1:0] mm_sz; wire [31:0] mm_a, mm_d, mm_rd; wire [3:0] mm_st;
    wire ua_v, ua_w, ua_rdy, ua_rv, ua_re; wire [1:0] ua_sz; wire [31:0] ua_a, ua_d, ua_rd; wire [3:0] ua_st;
    wire gp_v, gp_w, gp_rdy, gp_rv, gp_re; wire [1:0] gp_sz; wire [31:0] gp_a, gp_d, gp_rd; wire [3:0] gp_st;
    wire ra_v, ra_w, ra_rdy, ra_rv, ra_re; wire [1:0] ra_sz; wire [31:0] ra_a, ra_d, ra_rd; wire [3:0] ra_st;
    wire dd_v, dd_w, dd_rdy, dd_rv, dd_re; wire [1:0] dd_sz; wire [31:0] dd_a, dd_d, dd_rd; wire [3:0] dd_st;
    wire cn_v, cn_w, cn_rdy, cn_rv, cn_re; wire [1:0] cn_sz; wire [31:0] cn_a, cn_d, cn_rd; wire [3:0] cn_st;
    wire pp_v, pp_w, pp_rdy, pp_rv, pp_re; wire [1:0] pp_sz; wire [31:0] pp_a, pp_d, pp_rd; wire [3:0] pp_st;
    wire cm_v, cm_w, cm_rdy, cm_rv, cm_re; wire [1:0] cm_sz; wire [31:0] cm_a, cm_d, cm_rd; wire [3:0] cm_st;

    wire [1:0] test_status;
    wire uart_tx, uart_irq, gpio_irq;
    wire [7:0] gpio_out, gpio_dir;

    data_bus_interconnect #(
        .RAM_BASE(32'h0), .RAM_ADDR_MASK(32'hffff_c000),
        .MMIO_BASE(32'h1000_0000), .MMIO_ADDR_MASK(32'hffff_f000),
        .ENABLE_DDR(0),
        .ENABLE_CNN(0), .ENABLE_PREPROCESS(0), .ENABLE_CAMERA(0),
        .ENABLE_UART(1), .UART_BASE(32'h1000_1000),
        .ENABLE_GPIO(1), .GPIO_BASE(32'h1000_5000)
    ) u_ic (
        .clk(clk), .resetn(resetn), .ddr_write_buffer_busy(1'b0),
        .m_req_valid(req_valid), .m_req_write(req_write), .m_req_size(req_size),
        .m_req_addr(req_addr), .m_req_wdata(req_wdata), .m_req_wstrb(req_wstrb),
        .m_req_ready(req_ready), .m_rsp_valid(rsp_valid), .m_rsp_rdata(rsp_rdata), .m_rsp_error(rsp_error),
        .ram_req_valid(ra_v), .ram_req_write(ra_w), .ram_req_size(ra_sz), .ram_req_addr(ra_a),
        .ram_req_wdata(ra_d), .ram_req_wstrb(ra_st), .ram_req_ready(ra_rdy),
        .ram_rsp_valid(ra_rv), .ram_rsp_rdata(ra_rd), .ram_rsp_error(ra_re),
        .mmio_req_valid(mm_v), .mmio_req_write(mm_w), .mmio_req_size(mm_sz), .mmio_req_addr(mm_a),
        .mmio_req_wdata(mm_d), .mmio_req_wstrb(mm_st), .mmio_req_ready(mm_rdy),
        .mmio_rsp_valid(mm_rv), .mmio_rsp_rdata(mm_rd), .mmio_rsp_error(mm_re),
        .ddr_req_valid(dd_v), .ddr_req_write(dd_w), .ddr_req_size(dd_sz), .ddr_req_addr(dd_a),
        .ddr_req_wdata(dd_d), .ddr_req_wstrb(dd_st), .ddr_req_ready(dd_rdy),
        .ddr_rsp_valid(dd_rv), .ddr_rsp_rdata(dd_rd), .ddr_rsp_error(dd_re),
        .uart_req_valid(ua_v), .uart_req_write(ua_w), .uart_req_size(ua_sz), .uart_req_addr(ua_a),
        .uart_req_wdata(ua_d), .uart_req_wstrb(ua_st), .uart_req_ready(ua_rdy),
        .uart_rsp_valid(ua_rv), .uart_rsp_rdata(ua_rd), .uart_rsp_error(ua_re),
        .gpio_req_valid(gp_v), .gpio_req_write(gp_w), .gpio_req_size(gp_sz), .gpio_req_addr(gp_a),
        .gpio_req_wdata(gp_d), .gpio_req_wstrb(gp_st), .gpio_req_ready(gp_rdy),
        .gpio_rsp_valid(gp_rv), .gpio_rsp_rdata(gp_rd), .gpio_rsp_error(gp_re),
        .cnn_req_valid(cn_v), .cnn_req_write(cn_w), .cnn_req_size(cn_sz), .cnn_req_addr(cn_a),
        .cnn_req_wdata(cn_d), .cnn_req_wstrb(cn_st), .cnn_req_ready(1'b0),
        .cnn_rsp_valid(1'b0), .cnn_rsp_error(1'b0), .cnn_rsp_rdata(32'd0),
        .pp_req_valid(pp_v), .pp_req_write(pp_w), .pp_req_size(pp_sz), .pp_req_addr(pp_a),
        .pp_req_wdata(pp_d), .pp_req_wstrb(pp_st), .pp_req_ready(1'b0),
        .pp_rsp_valid(1'b0), .pp_rsp_error(1'b0), .pp_rsp_rdata(32'd0),
        .preprocess_busy(1'b0), .preprocess_done(1'b0),
        .cam_req_valid(cm_v), .cam_req_write(cm_w), .cam_req_size(cm_sz), .cam_req_addr(cm_a),
        .cam_req_wdata(cm_d), .cam_req_wstrb(cm_st), .cam_req_ready(1'b0),
        .cam_rsp_valid(1'b0), .cam_rsp_error(1'b0), .cam_rsp_rdata(32'd0),
        .camera_busy(1'b0), .camera_dual_mode(1'b0), .camera_cpu_owned(2'b0)
    );

    simple_mmio #(.PERF_ENABLE(0)) u_sys (
        .clk(clk), .resetn(resetn),
        .req_valid(mm_v), .req_write(mm_w), .req_size(mm_sz), .req_addr(mm_a),
        .req_wdata(mm_d), .req_wstrb(mm_st), .req_ready(mm_rdy),
        .rsp_valid(mm_rv), .rsp_rdata(mm_rd), .rsp_error(mm_re),
        .test_status(test_status),
        .perf_events(8'd0), .perf_retire_pc(32'd0), .perf_branch_target(32'd0), .perf_fetch_pc(32'd0),
        .perf_ar_fire(1'b0), .perf_aw_fire(1'b0), .perf_cache_events(6'd0), .perf_cache_enabled(2'd0),
        .perf_wait_events(3'd0), .perf_diag_flags(15'd0), .perf_diag_target_pc(32'd0),
        .perf_diag_pending_pc(32'd0), .perf_diag_buffer_pc(32'd0),
        .perf_detail_cpu(16'd0), .perf_detail_bridge(16'd0)
    );
    uart_mmio #(.CLK_HZ(100_000_000)) u_uart (
        .clk(clk), .resetn(resetn),
        .req_valid(ua_v), .req_write(ua_w), .req_size(ua_sz), .req_addr(ua_a),
        .req_wdata(ua_d), .req_wstrb(ua_st), .req_ready(ua_rdy),
        .rsp_valid(ua_rv), .rsp_rdata(ua_rd), .rsp_error(ua_re),
        .uart_rx(1'b1), .uart_tx(uart_tx), .uart_irq(uart_irq)
    );
    gpio_mmio #(.GPIO_WIDTH(8)) u_gpio (
        .clk(clk), .resetn(resetn),
        .req_valid(gp_v), .req_write(gp_w), .req_size(gp_sz), .req_addr(gp_a),
        .req_wdata(gp_d), .req_wstrb(gp_st), .req_ready(gp_rdy),
        .rsp_valid(gp_rv), .rsp_rdata(gp_rd), .rsp_error(gp_re),
        .gpio_in(8'd0), .gpio_out(gpio_out), .gpio_dir(gpio_dir), .gpio_irq(gpio_irq)
    );

    // ---------------- 激励 ----------------
    integer errs = 0;
    reg [31:0] d0, d1, dv;
    reg        e0, e1, e2, e3, e4;

    task acc(input [31:0] a, input wr, input [31:0] d, output [31:0] rd, output err);
        begin
            @(posedge clk);
            req_valid <= 1; req_write <= wr; req_addr <= a; req_wdata <= d;
            req_size <= 2'd2; req_wstrb <= 4'hf;
            @(posedge clk);
            while (!req_ready) @(posedge clk);
            req_valid <= 0;
            while (!rsp_valid) @(posedge clk);
            rd = rsp_rdata; err = rsp_error;
            @(posedge clk);
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        resetn = 1;
        repeat (20) @(posedge clk);

        acc(32'h1000_0008, 0, 0, d0, e0);        // CYCLE
        repeat (50) @(posedge clk);
        acc(32'h1000_0008, 0, 0, d1, e1);        // CYCLE 再读
        $display("CYCLE 读1=0x%08x err=%b   读2=0x%08x err=%b", d0, e0, d1, e1);
        if (e0 || e1) begin errs = errs + 1; $display("  -> CYCLE 不应报错"); end
        if (d1 <= d0) begin errs = errs + 1; $display("  -> CYCLE 应递增"); end

        acc(32'h1000_1004, 0, 0, dv, e2);        // UART 状态读（窗口内：0x1000_1000..F）
        $display("UART 状态 读=0x%08x err=%b", dv, e2);
        if (e2) begin errs = errs + 1; $display("  -> UART 读不应报错"); end

        acc(32'h1000_5000, 0, 0, dv, e3);        // GPIO 读
        $display("GPIO 读=0x%08x err=%b", dv, e3);
        if (e3) begin errs = errs + 1; $display("  -> GPIO 读不应报错"); end

        acc(32'h1000_2000, 0, 0, dv, e4);        // 相机关闭 -> 应 error
        $display("相机(未使能) 读=0x%08x err=%b  (期望 err=1)", dv, e4);
        if (!e4) begin errs = errs + 1; $display("  -> 未映射地址应返回 error"); end

        if (errs == 0) $display("PASS: MMIO 地址映射与固件 #define 一致");
        else           $display("FAIL: %0d 项不符", errs);
        $finish;
    end
endmodule
