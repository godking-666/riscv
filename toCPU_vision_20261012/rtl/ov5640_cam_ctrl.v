//======================================================================
// ov5640_cam_ctrl.v -- OV5640 上电时序 + SCCB 配置控制（clk 域）
//
// 上电顺序（照 OV5640 数据手册的常规做法）：
//   PWDN=1 -> 等 -> PWDN=0 -> RESET=0 -> 等 -> RESET=1 -> 等 -> 跑 SCCB 配置表
//
// 为什么必须走这一步：OV5640 上电后处在默认状态，默认分辨率/输出格式/时钟
// 都不是我们要的；不配就是「DVP 时序对着但画面不对」。这是采集链路点亮
// （M1）的必经关卡。
//
// 触发：rstn 释放后自动跑一次；之后可由寄存器 CTRL.CAM_RESTART 再触发。
// 本模块不含 XCLK 生成——相机主时钟由板载晶振或 PLL 提供，属板级事项。
//======================================================================
`timescale 1ns / 1ps

module ov5640_cam_ctrl #(
    parameter CLK_HZ          = 93750000,   // 与 CPU 组 core_clk 一致
    parameter SCL_HZ          = 100000,
    parameter PWDN_SETTLE_MS  = 10,
    parameter RESET_SETTLE_MS = 20
)(
    input  wire clk,
    input  wire rstn,

    input  wire restart,          // 1 拍脉冲：重跑一次上电 + 配置

    // 相机控制引脚
    output reg  cam_pwdn,
    output reg  cam_reset_n,
    output wire cam_scl,
    output wire cam_sda_out,
    output wire cam_sda_oe,
    input  wire cam_sda_in,

    output wire cfg_busy,
    output wire cfg_done,         // 电平：配置表已跑完
    output wire cfg_err           // 电平：SCCB 过程中出现过 NACK
);
    localparam MS_DIV = (CLK_HZ + 500) / 1000;

    localparam S_IDLE   = 3'd0;
    localparam S_PWDN   = 3'd1;   // 拉高 PWDN，等
    localparam S_REL    = 3'd2;   // 释放 PWDN、拉低 RESET，等
    localparam S_RST    = 3'd3;   // 释放 RESET，等
    localparam S_SCCB   = 3'd4;   // 跑配置表
    localparam S_DONE   = 3'd5;

    reg [2:0]  st;
    reg [31:0] dly;
    reg        sccb_start;
    reg        done_r;
    reg        err_r;
    reg        auto_run;
    reg        booted;       // 自动触发只允许发生一次

    wire       sccb_busy, sccb_done, sccb_ack_err;
    wire [31:0] dly_pwdn  = PWDN_SETTLE_MS  * MS_DIV;
    wire [31:0] dly_reset = RESET_SETTLE_MS * MS_DIV;

    ov5640_sccb #(.CLK_HZ(CLK_HZ), .SCL_HZ(SCL_HZ)) u_sccb (
        .clk       (clk),
        .rstn      (rstn),
        .start     (sccb_start),
        .busy      (sccb_busy),
        .done      (sccb_done),
        .ack_err   (sccb_ack_err),
        .clear_err (1'b0),
        .scl       (cam_scl),
        .sda_out   (cam_sda_out),
        .sda_oe    (cam_sda_oe),
        .sda_in    (cam_sda_in)
    );

    always @(posedge clk) begin
        if (!rstn) begin
            st          <= S_IDLE;
            dly         <= 32'd0;
            sccb_start  <= 1'b0;
            cam_pwdn    <= 1'b0;
            cam_reset_n <= 1'b1;
            done_r      <= 1'b0;
            err_r       <= 1'b0;
            auto_run    <= 1'b0;
            booted      <= 1'b0;
        end
        else begin
            sccb_start <= 1'b0;

            // 复位释放后延时一小段再自动跑，等时钟与电源稳定
            if (!booted) begin
                if (dly >= 32'd100000) begin
                    auto_run <= 1'b1;
                    booted   <= 1'b1;   // 只触发一次；否则 dly 继续上涨会反复重新武装
                end
                dly <= dly + 32'd1;
            end

            case (st)
                S_IDLE: begin
                    // 注意：这里不能清 done_r。S_DONE 打完 done 就回 S_IDLE，
                    // 若在 IDLE 里清零，cfg_done 只会存在一个周期，软件轮询必然漏掉。
                    if (auto_run || restart) begin
                        auto_run    <= 1'b0;   // 消费掉自动触发，否则回到 IDLE 会无限重启
                        done_r      <= 1'b0;
                        cam_pwdn    <= 1'b1;
                        cam_reset_n <= 1'b0;
                        dly         <= dly_pwdn;
                        st          <= S_PWDN;
                    end
                end

                S_PWDN: begin
                    if (dly == 32'd0) begin
                        cam_pwdn <= 1'b0;      // 释放掉电
                        dly      <= 32'd50000; // 等电源稳定
                        st       <= S_REL;
                    end
                    else dly <= dly - 32'd1;
                end

                S_REL: begin
                    if (dly == 32'd0) begin
                        cam_reset_n <= 1'b1;   // 释放复位
                        dly         <= dly_reset;
                        st          <= S_RST;
                    end
                    else dly <= dly - 32'd1;
                end

                S_RST: begin
                    if (dly == 32'd0) begin
                        sccb_start <= 1'b1;    // 开始下发配置表
                        st         <= S_SCCB;
                    end
                    else dly <= dly - 32'd1;
                end

                S_SCCB: begin
                    if (sccb_done) begin
                        err_r <= sccb_ack_err;
                        st    <= S_DONE;
                    end
                end

                S_DONE: begin
                    done_r <= 1'b1;
                    st     <= S_IDLE;
                end

                default: st <= S_IDLE;
            endcase
        end
    end

    assign cfg_busy = (st != S_IDLE) || sccb_busy;
    assign cfg_done = done_r;
    assign cfg_err  = err_r;
endmodule
