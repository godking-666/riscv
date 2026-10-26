// ============================================================================
// tb_mmio_cdc_wd  --  验证 mmio_cdc_bridge 的看门狗与恢复
//
// 场景：从设备故意对第 3 笔事务不作答（模拟实板上观察到的停摆）。
// 期望：
//   1) 第 3 笔在有限周期内返回 **错误**（而不是永远等待）
//   2) 桥随后能"排空"那笔迟到响应，第 4 笔及以后恢复正常
// ============================================================================
`timescale 1ns / 1ps

module tb_mmio_cdc_wd;
    reg cpu_clk = 0, core_clk = 0, cpu_resetn = 0, core_resetn = 0;
    always #3.70 cpu_clk  = ~cpu_clk;
    always #5.33 core_clk = ~core_clk;

    reg         req_valid = 0, req_write = 0;
    reg  [1:0]  req_size = 2'd2;
    reg  [31:0] req_addr = 0, req_wdata = 0;
    reg  [3:0]  req_wstrb = 4'hf;
    wire        req_ready, rsp_valid, rsp_error;
    wire [31:0] rsp_rdata;

    wire        c_v, c_w, c_rdy, c_rv, c_re;
    wire [1:0]  c_sz;
    wire [31:0] c_a, c_d, c_rd;
    wire [3:0]  c_st;

    mmio_cdc_bridge u_dut (
        .cpu_clk(cpu_clk), .cpu_resetn(cpu_resetn),
        .cpu_req_valid(req_valid), .cpu_req_write(req_write), .cpu_req_size(req_size),
        .cpu_req_addr(req_addr), .cpu_req_wdata(req_wdata), .cpu_req_wstrb(req_wstrb),
        .cpu_req_ready(req_ready),
        .cpu_rsp_valid(rsp_valid), .cpu_rsp_rdata(rsp_rdata), .cpu_rsp_error(rsp_error),
        .core_clk(core_clk), .core_resetn(core_resetn),
        .core_req_valid(c_v), .core_req_write(c_w), .core_req_size(c_sz),
        .core_req_addr(c_a), .core_req_wdata(c_d), .core_req_wstrb(c_st),
        .core_req_ready(c_rdy),
        .core_rsp_valid(c_rv), .core_rsp_rdata(c_rd), .core_rsp_error(c_re)
    );

    // 从设备：平时 1 拍后响应；第 3 笔故意吞掉（不响应）
    integer xfer_no = 0;
    reg       pend = 0;
    reg       swallowed = 0;
    reg [31:0] pend_rd;

    assign c_rdy = 1'b1;                 // 总是接受
    assign c_rv  = pend;
    assign c_rd  = pend_rd;
    assign c_re  = 1'b0;

    always @(posedge core_clk) begin
        if (!core_resetn) begin pend <= 0; xfer_no <= 0; swallowed <= 0; pend_rd <= 0; end
        else begin
            if (c_v && c_rdy && !pend) begin
                xfer_no <= xfer_no + 1;
                if (xfer_no == 2) begin
                    // 第 3 笔：吞掉，不置 pend
                    swallowed <= 1;
                    $display("SLAVE: swallowing transaction #3");
                end else begin
                    pend <= 1;
                    pend_rd <= c_a + 32'h1000;
                end
            end else if (pend) begin
                pend <= 0;
            end
        end
    end

    // CPU 侧驱动
    integer i, waited;
    reg [31:0] got;
    reg        got_err;
    integer    n_err = 0, n_ok = 0;

    task xfer(input integer idx);
        begin
            @(posedge cpu_clk);
            req_valid <= 1; req_write <= 0; req_addr <= idx; req_size <= 2'd2;
            waited = 0;
            while (!req_ready && waited < 100000) begin @(posedge cpu_clk); waited = waited + 1; end
            @(posedge cpu_clk);
            req_valid <= 0;
            waited = 0;
            while (!rsp_valid && waited < 100000) begin @(posedge cpu_clk); waited = waited + 1; end
            if (waited >= 100000) begin
                $display("FAIL: xfer %0d 永远没有响应（看门狗没起作用）", idx);
                n_err = n_err + 99;
            end else begin
                got = rsp_rdata; got_err = rsp_error;
                if (got_err) begin
                    n_err = n_err + 1;
                    $display("  xfer #%0d -> ERROR (waited %0d cycles)  <= 预期（被吞的那笔）", idx + 1, waited);
                end else begin
                    n_ok = n_ok + 1;
                    $display("  xfer #%0d -> ok data=0x%08x", idx + 1, got);
                end
            end
            @(posedge cpu_clk);
        end
    endtask

    initial begin
        repeat (8) @(posedge cpu_clk);
        cpu_resetn = 1; core_resetn = 1;
        repeat (8) @(posedge cpu_clk);
        for (i = 0; i < 6; i = i + 1) xfer(i);
        repeat (50) @(posedge cpu_clk);
        $display("=================================================");
        $display(" ok=%0d error=%0d（期望 5 或 6 个 ok、1 个 error）", n_ok, n_err);
        if (n_err == 1 && n_ok >= 4) $display("PASS: 看门狗把挂死变成一次可恢复的总线错误");
        else                         $display("FAIL: n_err=%0d n_ok=%0d", n_err, n_ok);
        $finish;
    end
endmodule
