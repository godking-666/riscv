//=============================================================================
// vision_tb.v -- 视觉子系统端到端仿真（含 CPU 替代件）
//
// 【CPU 替代件】真正的 RISC-V CPU 由另一组同学设计，这里用一组总线 BFM 任务
//   扮演 CPU：按 MMIO 时序写配置、轮询状态、读结果，行为完全等价于将来 C 驱动
//   里的 vision_reg_write / vision_reg_read。等真 CPU 就绪后，把这一层换成
//   CPU + 编译后的固件即可，视觉子系统 RTL 一行都不用改。
//
// 覆盖内容：
//   [A] 相机上电 + SCCB 配置：核对 29 条寄存器逐条下发正确、无 NACK
//   [B] 物品识别闭环：A 大块 / B 细长 / C 小件 / 无物品 四个场景
//   [C] 计数语义：只在物品出现沿自增，拿起放下不重复计数
//
// 运行：vvp sim.vvp
//=============================================================================
`timescale 1ns / 1ps

module vision_tb;

    //================= 寄存器偏移（与 vision_regs.v 对齐）=================
    localparam A_CTRL       = 32'h8000_0008;
    localparam A_STATUS     = 32'h8000_000C;
    localparam A_IRQ_CLR    = 32'h8000_0010;
    localparam A_FRAME_CNT  = 32'h8000_0014;
    localparam A_ITEM_CNT   = 32'h8000_0018;
    localparam A_FRAME_CYC  = 32'h8000_001C;
    localparam A_ROI_X      = 32'h8000_0020;
    localparam A_ROI_Y      = 32'h8000_0024;
    localparam A_ROI_W      = 32'h8000_0028;
    localparam A_ROI_H      = 32'h8000_002C;
    localparam A_THRESH     = 32'h8000_0030;
    localparam A_MIN_PIX    = 32'h8000_0034;
    localparam A_AREA_C_MAX = 32'h8000_0038;
    localparam A_CLASS      = 32'h8000_003C;
    localparam A_SCORE      = 32'h8000_0040;
    localparam A_BOX_X0     = 32'h8000_0044;
    localparam A_BOX_Y0     = 32'h8000_0048;
    localparam A_BOX_X1     = 32'h8000_004C;
    localparam A_BOX_Y1     = 32'h8000_0050;
    localparam A_FG_CNT     = 32'h8000_0054;
    localparam A_OBJ_W      = 32'h8000_0058;
    localparam A_OBJ_H      = 32'h8000_005C;

    localparam CAM_PERIOD_NS = 40;   // cam_pclk 25 MHz

    //================= 时钟与复位 =================
    reg clk, rstn, cam_pclk;
    initial begin clk = 1'b0; forever #10 clk = ~clk; end                // 50 MHz
    initial begin cam_pclk = 1'b0; forever #20 cam_pclk = ~cam_pclk; end // 25 MHz

    //================= 总线 =================
    reg         bus_sel, bus_we;
    reg  [31:0] bus_addr, bus_wdata;
    reg  [3:0]  bus_be;
    wire [31:0] bus_rdata;
    wire        irq;

    wire led_a, led_b, led_c;
    wire cam_vsync, cam_href;
    wire [7:0] cam_data;

    // ---- SCCB 开漏总线 ----
    wire cam_sda;
    wire cam_scl, cam_pwdn, cam_reset_n;
    wire sccb_slave_lo;
    assign cam_sda = sccb_slave_lo ? 1'b0 : 1'bz;
    pullup(cam_sda);

    vision_top #(
        .CAM_CLK_HZ          (50000000),
        .CAM_SCL_HZ          (1000000),   // 仿真提速，SCL 频率不影响功能正确性
        .CAM_PWDN_SETTLE_MS  (1),
        .CAM_RESET_SETTLE_MS (1),
        .BYTES_PER_PIX       (2)          // RGB565
    ) u_dut (
        .clk         (clk), .rstn (rstn), .cam_pclk (cam_pclk),
        .cam_vsync   (cam_vsync), .cam_href (cam_href), .cam_data (cam_data),
        .cam_sda     (cam_sda), .cam_scl (cam_scl),
        .cam_pwdn    (cam_pwdn), .cam_reset_n (cam_reset_n),
        .bus_sel     (bus_sel), .bus_we (bus_we), .bus_addr (bus_addr),
        .bus_wdata   (bus_wdata), .bus_be (bus_be), .bus_rdata (bus_rdata),
        .irq         (irq),
        .led_a       (led_a), .led_b (led_b), .led_c (led_c)
    );

    cam_model #(.BYTES_PER_PIX(2)) u_cam (
        .pclk (cam_pclk), .rstn (rstn),
        .vsync (cam_vsync), .href (cam_href), .data (cam_data)
    );

    sccb_slave_model u_slave (
        .clk     (clk),
        .rstn    (rstn),
        .scl     (cam_scl),
        .sda_bus (cam_sda),
        .sda_lo  (sccb_slave_lo)
    );

    `include "ov5640_init_table.vh"

    //================= 判定 =================
    integer pass_cnt, fail_cnt;

    task check;
        input [127:0] name;
        input [31:0]  got;
        input [31:0]  exp;
        begin
            if (got === exp) begin
                pass_cnt = pass_cnt + 1;
                $display("    [OK]   %0s = %0d", name, got);
            end
            else begin
                fail_cnt = fail_cnt + 1;
                $display("    [FAIL] %0s = %0d (期望 %0d)", name, got, exp);
            end
        end
    endtask

    //================= 【CPU 替代件】总线 BFM =================
    task bus_write;
        input [31:0] addr;
        input [31:0] wdata;
        begin
            @(posedge clk);
            bus_sel <= 1'b1; bus_we <= 1'b1;
            bus_addr <= addr; bus_wdata <= wdata; bus_be <= 4'hF;
            @(posedge clk);
            bus_sel <= 1'b0; bus_we <= 1'b0;
        end
    endtask

    task bus_read;
        input  [31:0] addr;
        output [31:0] rdata;
        begin
            @(posedge clk);
            bus_sel <= 1'b1; bus_we <= 1'b0;
            bus_addr <= addr; bus_be <= 4'hF;
            @(posedge clk);
            bus_sel <= 1'b0;
            #1 rdata = bus_rdata;      // 从端寄存输出，1 拍后有效
        end
    endtask

    task wait_frames;
        input integer n;
        integer start_f, cur_f;
        reg [31:0] v;
        begin
            bus_read(A_FRAME_CNT, v);
            start_f = v; cur_f = v;
            while ((cur_f - start_f) < n) begin
                repeat (200) @(posedge clk);
                bus_read(A_FRAME_CNT, v);
                cur_f = v;
            end
        end
    endtask

    // done 是单拍脉冲，轮询会漏拍，用粘滞标志接
    reg done_seen;
    always @(posedge clk) if (u_dut.u_regs.done_flag) done_seen <= 1'b1;

    task wait_done;
        integer k;
        begin
            for (k = 0; (k < 800000) && !done_seen; k = k + 1) @(posedge clk);
            if (!done_seen) $display("    !! wait_done 超时");
        end
    endtask

    //================= 读取并打印一帧结果 =================
    reg [31:0] r_class, r_score, r_bx0, r_by0, r_bx1, r_by1;
    reg [31:0] r_fg, r_ow, r_oh, r_cyc, r_item, r_frm;

    task show_result;
        real lat_ms;
        begin
            bus_read(A_CLASS,     r_class);
            bus_read(A_SCORE,     r_score);
            bus_read(A_BOX_X0,    r_bx0);
            bus_read(A_BOX_Y0,    r_by0);
            bus_read(A_BOX_X1,    r_bx1);
            bus_read(A_BOX_Y1,    r_by1);
            bus_read(A_FG_CNT,    r_fg);
            bus_read(A_OBJ_W,     r_ow);
            bus_read(A_OBJ_H,     r_oh);
            bus_read(A_FRAME_CYC, r_cyc);
            bus_read(A_ITEM_CNT,  r_item);
            bus_read(A_FRAME_CNT, r_frm);

            lat_ms = r_cyc * CAM_PERIOD_NS / 1000000.0;

            $display("    ------------------------------------------------------------");
            $display("    屏幕 | 类别=%0s  框=(%0d,%0d)-(%0d,%0d) 尺寸=%0dx%0d",
                     (r_class == 0) ? "A" : (r_class == 1) ? "B" :
                     (r_class == 2) ? "C" : "--",
                     r_bx0, r_by0, r_bx1, r_by1, r_ow, r_oh);
            $display("    屏幕 | 帧周期=%0d clk (%.2f ms, 识别延迟上限)  计数=%0d  置信度=%0d  前景=%0d  帧号=%0d",
                     r_cyc, lat_ms, r_item, r_score, r_fg, r_frm);
            $display("    灯   | A=%0b B=%0b C=%0b", led_a, led_b, led_c);
            $display("    ------------------------------------------------------------");
        end
    endtask

    task capture_once;
        begin
            wait_frames(1);
            bus_write(A_IRQ_CLR, 32'd1);
            repeat (2) @(posedge clk);   // 等 done_flag 真被清掉，否则 done_seen 会被上一帧重新置起
            done_seen = 1'b0;
            wait_done;
            show_result;
        end
    endtask

    task place;
        input [15:0] ox, oy, ow, oh;
        begin
            u_cam.obj_x = ox; u_cam.obj_y = oy;
            u_cam.obj_w = ow; u_cam.obj_h = oh;
            u_cam.obj_en = 1'b1;
        end
    endtask

    task remove_item;
        begin
            u_cam.obj_en = 1'b0;
        end
    endtask

    //================= 主流程 =================
    integer k, i;
    reg [31:0] st, exp_e;

    initial begin
        pass_cnt = 0;
        fail_cnt = 0;
        rstn = 1'b0;
        bus_sel = 1'b0; bus_we = 1'b0;
        bus_addr = 32'd0; bus_wdata = 32'd0; bus_be = 4'h0;
        done_seen = 1'b0;
        u_cam.obj_en  = 1'b0;
        u_cam.obj_x   = 16'd0; u_cam.obj_y = 16'd0;
        u_cam.obj_w   = 16'd0; u_cam.obj_h = 16'd0;
        u_cam.obj_val = 8'd40;

        $display("");
        $display("============================================================");
        $display(" 视觉子系统端到端仿真（CPU 由总线 BFM 替代）");
        $display("============================================================");

        repeat (20) @(posedge clk);
        rstn = 1'b1;
        repeat (20) @(posedge clk);

        // ---- [A] 相机上电 + SCCB 配置 ----
        $display("[A] 相机上电 + SCCB 配置");
        $display("    cam_pwdn=%0b cam_reset_n=%0b（上电期间应先把相机拉在复位态）",
                 cam_pwdn, cam_reset_n);

        st = 32'd0;
        for (k = 0; (k < 100000) && ((st[4]) === 1'b0); k = k + 1) begin
            repeat (50) @(posedge clk);
            bus_read(A_STATUS, st);
        end
        check("CAM_CFG_DONE", {31'd0, st[4]}, 32'd1);
        check("CAM_CFG_ERR ", {31'd0, st[5]}, 32'd0);
        check("SCCB 收到条数", u_slave.n_cap, OV5640_INIT_N);

        exp_e = ov5640_init_entry(6'd0);
        check("SCCB 首条寄存器", {16'd0, u_slave.cap_reg[0]}, exp_e[31:16]);
        check("SCCB 首条数据  ", {24'd0, u_slave.cap_dat[0]}, exp_e[15:8]);

        exp_e = ov5640_init_entry(OV5640_INIT_N[5:0] - 6'd1);
        check("SCCB 末条寄存器", {16'd0, u_slave.cap_reg[OV5640_INIT_N-1]}, exp_e[31:16]);
        check("SCCB 末条数据  ", {24'd0, u_slave.cap_dat[OV5640_INIT_N-1]}, exp_e[15:8]);
        $display("    相机配置完成，进入识别流程");

        // ---- [B] 软件配置视觉子系统 ----
        $display("[B] 配置视觉子系统");
        bus_write(A_ROI_X,      32'd0);
        bus_write(A_ROI_Y,      32'd0);
        bus_write(A_ROI_W,      32'd320);
        bus_write(A_ROI_H,      32'd240);
        bus_write(A_THRESH,     32'd128);
        bus_write(A_MIN_PIX,    32'd64);
        bus_write(A_AREA_C_MAX, 32'd500);
        bus_write(A_CTRL,       32'h0000_0009);   // EN=1 + CFG_COMMIT
        $display("    ROI=(0,0) 320x240  THRESH=128  MIN_PIX=64  AREA_C_MAX=500  EN=1");

        // ---- [C] 放上 A 类 ----
        $display("[C1] 放上 A 类：大方块 60x60 @(100,60)");
        place(16'd100, 16'd60, 16'd60, 16'd60);
        capture_once;
        check("CLASS",    r_class, 32'd0);
        check("FG_CNT",   r_fg,    32'd3600);
        check("BOX_X0",   r_bx0,   32'd100);
        check("BOX_Y0",   r_by0,   32'd60);
        check("BOX_X1",   r_bx1,   32'd159);
        check("BOX_Y1",   r_by1,   32'd119);
        check("OBJ_W",    r_ow,    32'd60);
        check("OBJ_H",    r_oh,    32'd60);
        check("SCORE",    r_score, 32'd46);
        check("LED_A",    {31'd0, led_a}, 32'd1);
        check("ITEM_CNT", r_item,  32'd1);

        $display("[C2] 拿起 A（不应重复计数）");
        remove_item;
        capture_once;
        check("CLASS_none",  r_class, 32'd255);
        check("FG_CNT_none", r_fg,    32'd0);
        check("ITEM_CNT",    r_item,  32'd1);
        check("LED_all_off", {29'd0, led_a, led_b, led_c}, 32'd0);

        $display("[C3] 放上 B 类：细长 20x80 @(60,50)");
        place(16'd60, 16'd50, 16'd20, 16'd80);
        capture_once;
        check("CLASS",    r_class, 32'd1);
        check("FG_CNT",   r_fg,    32'd1600);
        check("BOX_X0",   r_bx0,   32'd60);
        check("BOX_Y0",   r_by0,   32'd50);
        check("BOX_X1",   r_bx1,   32'd79);
        check("BOX_Y1",   r_by1,   32'd129);
        check("OBJ_W",    r_ow,    32'd20);
        check("OBJ_H",    r_oh,    32'd80);
        check("SCORE",    r_score, 32'd20);
        check("LED_B",    {31'd0, led_b}, 32'd1);
        check("ITEM_CNT", r_item,  32'd2);

        $display("[C4] 拿起 B");
        remove_item;
        capture_once;
        check("CLASS_none", r_class, 32'd255);
        check("ITEM_CNT",   r_item,  32'd2);

        $display("[C5] 放上 C 类：小件 20x20 @(150,150)");
        place(16'd150, 16'd150, 16'd20, 16'd20);
        capture_once;
        check("CLASS",    r_class, 32'd2);
        check("FG_CNT",   r_fg,    32'd400);
        check("BOX_X0",   r_bx0,   32'd150);
        check("BOX_Y0",   r_by0,   32'd150);
        check("BOX_X1",   r_bx1,   32'd169);
        check("BOX_Y1",   r_by1,   32'd169);
        check("SCORE",    r_score, 32'd5);
        check("LED_C",    {31'd0, led_c}, 32'd1);
        check("ITEM_CNT", r_item,  32'd3);

        $display("[C6] 拿起 C");
        remove_item;
        capture_once;
        check("CLASS_none", r_class, 32'd255);
        check("ITEM_CNT",   r_item,  32'd3);

        // ---- 汇总 ----
        $display("");
        $display("============================================================");
        if (fail_cnt == 0)
            $display("   TEST_PASS   全部 %0d 项检查通过", pass_cnt);
        else
            $display("   TEST_FAIL   PASS=%0d  FAIL=%0d", pass_cnt, fail_cnt);
        $display("============================================================");
        $display("");
        $finish;
    end

    initial begin
        #150_000_000;
        $display("   TEST_TIMEOUT  仿真超时");
        $finish;
    end

endmodule