// ============================================================================
// tb_mmio_cdc_stress  --  mmio_cdc_bridge 的压力测试（找偶发死锁）
//
// 背景：板上实测发现应用在 printf 输出中途停住（MMIO 访问挂死），
// 怀疑是四相 toggle 握手在某些时序组合下丢失或重复响应。
// 本测试连续发 N 笔事务（读写混合、随机间隔、从设备随机 1~6 拍延迟），
// 每笔都带超时保护；一旦超时就报出"第几笔、什么方向"，用于定位。
// ============================================================================
`timescale 1ns / 1ps

module tb_mmio_cdc_stress;
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

    // ---------------- core 侧从设备：随机 1~6 拍延迟 ----------------
    reg [31:0] mem [0:255];
    reg        pend = 0;
    reg [31:0] pend_rdata;
    reg [2:0]  delay_cnt = 0;
    integer    seed = 20261027;
    integer    k;
    integer    lat;

    assign core_req_ready = !pend;
    assign core_rsp_valid = pend && (delay_cnt == 0);
    assign core_rsp_rdata = pend_rdata;
    assign core_rsp_error = 1'b0;

    always @(posedge core_clk) begin
        if (!core_resetn) begin
            pend <= 0; delay_cnt <= 0; pend_rdata <= 0;
            for (k = 0; k < 256; k = k + 1) mem[k] <= 32'd0;
        end else if (!pend && core_req_valid && core_req_ready) begin
            pend <= 1;
            lat = ($unsigned($random(seed)) % 6);
            delay_cnt <= lat[2:0];
            if (core_req_write) begin
                mem[core_req_addr[9:2]] <= core_req_wdata;
                pend_rdata <= core_req_wdata;
            end else pend_rdata <= mem[core_req_addr[9:2]];
        end else if (pend) begin
            if (delay_cnt != 0) delay_cnt <= delay_cnt - 1;
            else pend <= 0;
        end
    end

    // ---------------- CPU 侧：连续 N 笔，每笔带超时 ----------------
    integer i, errs = 0, timeouts = 0, gap;
    reg [31:0] expect_val, got;
    reg        wr;

    task one_xfer(input integer idx, input reg w, input [31:0] a, input [31:0] d,
                  input integer max_wait);
        integer waited;
        begin
            wr = w;
            @(posedge cpu_clk);
            cpu_req_valid <= 1; cpu_req_write <= w; cpu_req_addr <= a; cpu_req_wdata <= d;
            cpu_req_size <= 2'd2; cpu_req_wstrb <= 4'hf;
            waited = 0;
            // 等 ready
            while (!cpu_req_ready && waited < max_wait) begin @(posedge cpu_clk); waited = waited + 1; end
            if (waited >= max_wait) begin
                $display("TIMEOUT waiting ready: idx=%0d wr=%b addr=0x%08x", idx, w, a);
                timeouts = timeouts + 1;
                cpu_req_valid <= 0;
            end else begin
                @(posedge cpu_clk);
                cpu_req_valid <= 0;
                waited = 0;
                while (!cpu_rsp_valid && waited < max_wait) begin @(posedge cpu_clk); waited = waited + 1; end
                if (waited >= max_wait) begin
                    $display("TIMEOUT waiting rsp:   idx=%0d wr=%b addr=0x%08x", idx, w, a);
                    timeouts = timeouts + 1;
                end else begin
                    got = cpu_rsp_rdata;
                    @(posedge cpu_clk);
                end
            end
        end
    endtask

    initial begin
        repeat (6) @(posedge cpu_clk);
        cpu_resetn = 1; core_resetn = 1;
        repeat (6) @(posedge cpu_clk);

        for (i = 0; i < 4000; i = i + 1) begin
            if ((i % 2) == 0) begin
                expect_val = 32'hA5000000 + i;
                one_xfer(i, 1'b1, i % 256, expect_val, 400);
            end else begin
                one_xfer(i, 1'b0, (i - 1) % 256, 32'd0, 400);
            end
            gap = ($unsigned($random(seed)) % 4);
            repeat (gap) @(posedge cpu_clk);
            if (timeouts > 3) begin
                $display("aborting after %0d timeouts at i=%0d", timeouts, i);
                i = 4000;
            end
        end

        $display("=================================================");
        $display(" stress done: xfers=4000  timeouts=%0d  errs=%0d", timeouts, errs);
        if (timeouts == 0 && errs == 0) $display("PASS: mmio_cdc_bridge 4000 笔事务无死锁");
        else                            $display("FAIL: 检测到 %0d 次超时 / %0d 次错误", timeouts, errs);
        $finish;
    end
endmodule
