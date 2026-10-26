// ============================================================================
// tb_mmio_cdc  --  mmio_cdc_bridge 的独立单元验证
//
// 两个异步时钟（135 MHz / 93.75 MHz，比例 1.44），core 侧挂一个 8 深度的
// 简单寄存器堆作为从设备，CPU 侧依次做：
//   1) 写 4 个寄存器
//   2) 读回 4 个寄存器并比对
//   3) 读一个未写过的地址（应得 0）
// 覆盖：单笔在途握手、写/读、可变延迟（从设备随机 1~3 拍响应）、跨域数据稳定
// ============================================================================
`timescale 1ns / 1ps

module tb_mmio_cdc;
    reg cpu_clk = 0, core_clk = 0, cpu_resetn = 0, core_resetn = 0;
    always #3.7  cpu_clk  = ~cpu_clk;    // ~135 MHz
    always #5.33 core_clk = ~core_clk;   // ~93.75 MHz

    reg         cpu_req_valid = 0, cpu_req_write = 0;
    reg  [1:0]  cpu_req_size = 2'd2;
    reg  [31:0] cpu_req_addr = 0, cpu_req_wdata = 0;
    reg  [3:0]  cpu_req_wstrb = 4'hf;
    wire        cpu_req_ready, cpu_rsp_valid, cpu_rsp_error;
    wire [31:0] cpu_rsp_rdata;

    wire        core_req_valid, core_req_write, core_req_ready, core_rsp_valid, core_rsp_error;
    wire [1:0]  core_req_size;
    wire [31:0] core_req_addr, core_req_wdata, core_rsp_rdata;
    wire [3:0]  core_req_wstrb;

    mmio_cdc_bridge u_dut (
        .cpu_clk(cpu_clk), .cpu_resetn(cpu_resetn),
        .cpu_req_valid(cpu_req_valid), .cpu_req_write(cpu_req_write), .cpu_req_size(cpu_req_size),
        .cpu_req_addr(cpu_req_addr), .cpu_req_wdata(cpu_req_wdata), .cpu_req_wstrb(cpu_req_wstrb),
        .cpu_req_ready(cpu_req_ready),
        .cpu_rsp_valid(cpu_rsp_valid), .cpu_rsp_rdata(cpu_rsp_rdata), .cpu_rsp_error(cpu_rsp_error),
        .core_clk(core_clk), .core_resetn(core_resetn),
        .core_req_valid(core_req_valid), .core_req_write(core_req_write), .core_req_size(core_req_size),
        .core_req_addr(core_req_addr), .core_req_wdata(core_req_wdata), .core_req_wstrb(core_req_wstrb),
        .core_req_ready(core_req_ready),
        .core_rsp_valid(core_rsp_valid), .core_rsp_rdata(core_rsp_rdata), .core_rsp_error(core_rsp_error)
    );

    // ---------------- core 侧从设备：8 个 32 位寄存器，1~3 拍随机延迟 ----------------
    reg [31:0] regs [0:7];
    reg        pend = 0;
    reg [31:0] pend_rdata;
    reg [1:0]  delay_cnt = 0;
    integer seed = 12345;
    integer k;

    assign core_req_ready = !pend;
    assign core_rsp_valid = pend && (delay_cnt == 0);
    assign core_rsp_rdata = pend_rdata;
    assign core_rsp_error = 1'b0;

    always @(posedge core_clk) begin
        if (!core_resetn) begin
            pend <= 0; delay_cnt <= 0; pend_rdata <= 32'd0;
            for (k = 0; k < 8; k = k + 1) regs[k] <= 32'd0;
        end else if (!pend && core_req_valid && core_req_ready) begin
            pend <= 1'b1;
            delay_cnt <= ($unsigned($random(seed)) % 3);   // 0/1/2 -> 1~3 拍
            if (core_req_write) begin
                regs[core_req_addr[4:2]] <= core_req_wdata;
                pend_rdata <= core_req_wdata;
            end else begin
                pend_rdata <= regs[core_req_addr[4:2]];
            end
        end else if (pend) begin
            if (delay_cnt != 0) delay_cnt <= delay_cnt - 1'b1;
            else pend <= 1'b0;
        end
    end

    // ---------------- CPU 侧激励 ----------------
    integer errs = 0;
    reg [31:0] got;

    task cpu_write(input [31:0] a, input [31:0] d);
        begin
            @(posedge cpu_clk);
            cpu_req_valid <= 1'b1; cpu_req_write <= 1'b1;
            cpu_req_addr <= a; cpu_req_wdata <= d; cpu_req_wstrb <= 4'hf;
            cpu_req_size <= 2'd2;
            @(posedge cpu_clk);
            while (!cpu_req_ready) @(posedge cpu_clk);
            cpu_req_valid <= 1'b0; cpu_req_write <= 1'b0;
            while (!cpu_rsp_valid) @(posedge cpu_clk);
            @(posedge cpu_clk);
        end
    endtask

    task cpu_read(input [31:0] a, output [31:0] d);
        begin
            @(posedge cpu_clk);
            cpu_req_valid <= 1'b1; cpu_req_write <= 1'b0;
            cpu_req_addr <= a; cpu_req_size <= 2'd2;
            @(posedge cpu_clk);
            while (!cpu_req_ready) @(posedge cpu_clk);
            cpu_req_valid <= 1'b0;
            while (!cpu_rsp_valid) @(posedge cpu_clk);
            d = cpu_rsp_rdata;
            @(posedge cpu_clk);
        end
    endtask

    initial begin
        repeat (6) @(posedge cpu_clk);
        cpu_resetn = 1; core_resetn = 1;
        repeat (6) @(posedge cpu_clk);

        cpu_write(32'h1000_0000, 32'hDEADBEEF);
        cpu_write(32'h1000_0004, 32'h12345678);
        cpu_write(32'h1000_0008, 32'hA5A5A5A5);
        cpu_write(32'h1000_000C, 32'h00000001);

        cpu_read(32'h1000_0000, got);
        if (got !== 32'hDEADBEEF) begin errs = errs + 1; $display("MISMATCH @0: got %08x", got); end
        cpu_read(32'h1000_0004, got);
        if (got !== 32'h12345678) begin errs = errs + 1; $display("MISMATCH @4: got %08x", got); end
        cpu_read(32'h1000_0008, got);
        if (got !== 32'hA5A5A5A5) begin errs = errs + 1; $display("MISMATCH @8: got %08x", got); end
        cpu_read(32'h1000_000C, got);
        if (got !== 32'h00000001) begin errs = errs + 1; $display("MISMATCH @C: got %08x", got); end
        cpu_read(32'h1000_0010, got);   // 未写过 -> 0
        if (got !== 32'h00000000) begin errs = errs + 1; $display("MISMATCH @10: got %08x", got); end

        if (errs == 0) $display("PASS: mmio_cdc_bridge 8 次跨域读写全部正确");
        else           $display("FAIL: %0d 处不符", errs);
        $finish;
    end

    initial begin
        #500000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
