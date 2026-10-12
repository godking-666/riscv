//======================================================================
// sccb_slave_model.v -- OV5640 SCCB 从机模型（仅仿真用）
//
// 开漏总线语义：sda_lo=1 表示从机把 SDA 拉低，0 表示释放。
//
// 这里踩过两个坑，都写清楚，免得以后重犯：
//
// (1) 字节边界。每个字节占 9 个 SCL 时钟 —— 8 个数据位 + 1 个应答位。
//     位计数 clkc 在「下降沿」推进：
//       rise 且 clkc<8 : 采样一位
//       rise 且 clkc==8: 第 9 拍（应答），不采样
//       fall 且 clkc==8: 第 9 拍结束 -> 收尾字节, clkc 归零
//       fall 且 clkc<8 : clkc++
//     若改成在上升沿推进 clkc，第 8 个数据位的下降沿就会被误当成第 9 拍结束，
//     应答位会被收成下一字节的首位，整包右移一格（0x31 会读成 0x98）。
//
// (2) START 之后的那个下降沿。I2C/SCCB 的 START 是「SCL 高时 SDA 下降」，
//     紧接着 SCL 才下降到低电平。这个下降沿不是一个完整时钟，绝不能计数，
//     否则整包左移一格。所以必须用 in_bit 标志：只有「先升后降」才算一个时钟。
//
// 应答驱动：clkc==8 期间组合拉低 SDA，正好覆盖第 9 拍高电平期。
//======================================================================
`timescale 1ns / 1ps

module sccb_slave_model (
    input  wire clk,
    input  wire rstn,
    input  wire scl,
    input  wire sda_bus,
    output wire sda_lo
);
    reg [3:0]  clkc;          // 0..8：当前字节内的第几个 SCL 时钟
    reg        in_bit;        // 已经看到上升沿、还没等到下降沿
    reg [7:0]  sh;
    reg [2:0]  bytec;
    reg [15:0] reg_addr;
    reg [7:0]  data_val;
    reg        scl_d, sda_d;

    integer    n_cap;
    reg [15:0] cap_reg [0:127];
    reg [7:0]  cap_dat [0:127];

    assign sda_lo = (clkc == 4'd8);

    wire scl_rise =  scl & ~scl_d;
    wire scl_fall = ~scl &  scl_d;
    wire start_c  =  scl & scl_d &  sda_d & ~sda_bus;
    wire stop_c   =  scl & scl_d & ~sda_d &  sda_bus;

    always @(posedge clk) begin
        if (!rstn) begin
            scl_d    <= 1'b1;
            sda_d    <= 1'b1;
            clkc     <= 4'd0;
            in_bit   <= 1'b0;
            sh       <= 8'd0;
            bytec    <= 3'd0;
            reg_addr <= 16'd0;
            data_val <= 8'd0;
            n_cap    <= 0;
        end
        else begin
            scl_d <= scl;
            sda_d <= sda_bus;

            if (start_c) begin
                clkc   <= 4'd0;
                in_bit <= 1'b0;
                sh     <= 8'd0;
                bytec  <= 3'd0;
            end
            else if (stop_c) begin
                if (bytec == 3'd4) begin
                    cap_reg[n_cap] <= reg_addr;
                    cap_dat[n_cap] <= data_val;
                    n_cap          <= n_cap + 1;
                end
                clkc   <= 4'd0;
                in_bit <= 1'b0;
                bytec  <= 3'd0;
            end
            else if (scl_rise) begin
                in_bit <= 1'b1;
                if (clkc < 4'd8)
                    sh <= {sh[6:0], sda_bus};
            end
            else if (scl_fall) begin
                if (in_bit) begin          // 只认「先升后降」的完整时钟
                    in_bit <= 1'b0;
                    if (clkc == 4'd8) begin
                        case (bytec)
                            3'd1:    reg_addr[15:8] <= sh;
                            3'd2:    reg_addr[7:0]  <= sh;
                            3'd3:    data_val       <= sh;
                            default: ;
                        endcase
                        clkc  <= 4'd0;
                        bytec <= bytec + 3'd1;
                    end
                    else begin
                        clkc <= clkc + 4'd1;
                    end
                end
                // in_bit==0：START 之后那个下降沿，忽略
            end
        end
    end
endmodule