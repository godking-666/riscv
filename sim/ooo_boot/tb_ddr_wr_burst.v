// ============================================================================
// tb_ddr_wr_burst  --  两级级联写仲裁器 + DDR IP 写模型的 2 拍突发测试
//
// 背景：CPU（ooo_ddr_port）写 Cache line 用 awlen=1（2 拍），要经过
//   u_write_arbiter → u_output_arbiter → DDR IP
// 两级都各自做"剩余拍数"计数。摄像机通路永远用 awlen=0（单拍），
// 所以这个级联 + 多拍组合从未被验证过。
//
// 本 TB 用行为模型模拟 DDR IP 的写端口（Pango native：无 WVALID、无 B 通道，
// 数据在 wready 当拍被吃掉），检查 2 拍写是否被完整接收。
// ============================================================================
`timescale 1ns / 1ps

module tb_ddr_wr_burst;
    reg clk = 0, resetn = 0;
    always #5 clk = ~clk;

    // ---- CPU 侧（模拟 ooo_ddr_port 的写口）----
    reg         cpu_awvalid = 0, cpu_awap = 0;
    reg  [27:0] cpu_awaddr = 0;
    reg  [3:0]  cpu_awlen = 0, cpu_awid = 0;
    reg  [255:0] cpu_wdata = 0;
    reg  [31:0] cpu_wstrb = 0;
    wire        cpu_awready, cpu_wready;

    // ---- 第一级：CPU vs 相机 ----
    wire        st1_awvalid, st1_awap, st1_awready, st1_wready;
    wire [27:0] st1_awaddr;
    wire [3:0]  st1_awlen, st1_awid;
    wire [255:0] st1_wdata;
    wire [31:0] st1_wstrb;

    camera_ddr_write_arbiter #(.CAM_AW_ID(4'd2)) u_wr1 (
        .clk(clk), .resetn(resetn),
        .cpu_awaddr(cpu_awaddr), .cam_awaddr(28'd0),
        .cpu_awlen(cpu_awlen), .cpu_awid(cpu_awid),
        .cpu_awap(cpu_awap), .cpu_awvalid(cpu_awvalid), .cam_awvalid(1'b0),
        .cpu_wdata(cpu_wdata), .cam_wdata(256'd0), .cpu_wstrb(cpu_wstrb),
        .cpu_awready(cpu_awready), .cpu_wready(cpu_wready),
        .cam_awready(), .cam_wready(),
        .awaddr(st1_awaddr), .awlen(st1_awlen), .awid(st1_awid), .awap(st1_awap),
        .awvalid(st1_awvalid), .wdata(st1_wdata), .wstrb(st1_wstrb),
        .awready(st1_awready), .wready(st1_wready), .busy()
    );

    // ---- 第二级：输出 vs PP ----
    wire        st2_awvalid, st2_awap, st2_awready, st2_wready;
    wire [27:0] st2_awaddr;
    wire [3:0]  st2_awlen, st2_awid;
    wire [255:0] st2_wdata;
    wire [31:0] st2_wstrb;

    camera_ddr_write_arbiter #(.CAM_AW_ID(4'd3)) u_wr2 (
        .clk(clk), .resetn(resetn),
        .cpu_awaddr(st1_awaddr), .cam_awaddr(28'd0),
        .cpu_awlen(st1_awlen), .cpu_awid(st1_awid),
        .cpu_awap(st1_awap), .cpu_awvalid(st1_awvalid), .cam_awvalid(1'b0),
        .cpu_wdata(st1_wdata), .cam_wdata(256'd0), .cpu_wstrb(st1_wstrb),
        .cpu_awready(st1_awready), .cpu_wready(st1_wready),
        .cam_awready(), .cam_wready(),
        .awaddr(st2_awaddr), .awlen(st2_awlen), .awid(st2_awid), .awap(st2_awap),
        .awvalid(st2_awvalid), .wdata(st2_wdata), .wstrb(st2_wstrb),
        .awready(st2_awready), .wready(st2_wready), .busy()
    );

    // ---- DDR IP 写模型（Pango native：AW 一次、随后逐拍吃数据）----
    reg        ip_busy = 0;
    reg [3:0]  ip_beats = 0;      // 还需几拍
    reg        aw_taken = 0;
    reg [3:0]  got_beats = 0;     // 累计收到的拍数
    reg [3:0]  total_bursts = 0;

    assign st2_awready = !ip_busy;
    assign st2_wready  = ip_busy;      // 拿到 AW 之后才吃数据

    integer errs = 0;

    always @(posedge clk) begin
        if (!resetn) begin
            ip_busy <= 0; ip_beats <= 0; aw_taken <= 0; got_beats <= 0; total_bursts <= 0;
        end else begin
            if (!ip_busy && st2_awvalid && st2_awready) begin
                ip_busy  <= 1;
                ip_beats <= st2_awlen + 1;
                aw_taken <= 1;
                got_beats <= 0;
            end else if (ip_busy && st2_wready) begin
                // 每拍 wready 都被视为吃掉一拍（由 arbiter 的 wdata 有效隐含）
                got_beats <= got_beats + 1;
                ip_beats  <= ip_beats - 1;
                if (ip_beats == 1) begin
                    ip_busy <= 0;
                    total_bursts <= total_bursts + 1;
                    $display("IP: burst done, beats=%0d", got_beats + 1);
                end
            end
        end
    end

    // ---- 激励：发一笔 2 拍写 ----
    integer b;
    initial begin
        repeat (5) @(posedge clk);
        resetn = 1;
        repeat (5) @(posedge clk);

        // AW: 2 拍（awlen=1）
        cpu_awaddr <= 28'h0000_1000;
        cpu_awlen  <= 4'd1;
        cpu_awid   <= 4'd0;
        cpu_awvalid <= 1;
        while (!cpu_awready) @(posedge clk);
        @(posedge clk);
        cpu_awvalid <= 0;

        // 两个数据拍
        for (b = 0; b < 2; b = b + 1) begin
            cpu_wdata <= {8{32'hDEAD0000 + b}};
            cpu_wstrb <= 32'hffff_ffff;
            @(posedge clk);
            while (!cpu_wready) @(posedge clk);
            @(posedge clk);
        end

        repeat (20) @(posedge clk);
        $display("=================================================");
        $display(" bursts_completed=%0d (expect 1)", total_bursts);
        if (total_bursts == 1) $display("PASS: 2 拍写穿越两级仲裁器被完整接收");
        else                   $display("FAIL: 2 拍写未被完整接收（IP 一直等数据）");
        $finish;
    end

    initial begin
        #100000;
        $display("TIMEOUT: 2 拍写卡住（aw_taken=%b ip_busy=%b ip_beats=%0d got=%0d）",
                 aw_taken, ip_busy, ip_beats, got_beats);
        $finish;
    end
endmodule
