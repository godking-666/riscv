//======================================================================
// ov5640_capture.v -- OV5640 DVP 接收（cam_pclk 域）
//
// 输入：DVP 标准的 pclk / vsync / href / data[7:0]
//   * vsync 高电平脉冲 = 帧起始
//   * href  高电平     = 该拍 data 是有效字节
//
// 输出：与 pix / pix_x / pix_y 严格对齐的「像素」流。
//
// 字节到像素的换算由 BYTES_PER_PIX 决定：
//   BYTES_PER_PIX = 1：每字节一个像素（RAW/灰度模式），pix 就是 data
//   BYTES_PER_PIX = 2：RGB565，两个字节一个像素。取绿通道作为亮度近似：
//                        G6 = {byte0[2:0], byte1[7:5]}
//                        pix = {G6, 2'b00}
//                      人眼亮度里绿占约 0.59，哑光背景 + 明暗分割的场合
//                      足够用，且不需要任何乘法器。若日后要更准的灰度，
//                      在这里换成 R*77+G*151+B*28>>8 即可，下游不用动。
//
// 时序约定：DVP 的 data 与 href 同拍有效。为了不让下游出现"数据与坐标差一拍"，
//   本模块把 href/data 寄存一级，坐标计数器在输入端推进，再把 x/y 寄存一级与之
//   对齐。因此下游看到的 pix_de / pix / pix_x / pix_y 始终描述同一个像素。
//======================================================================
`timescale 1ns / 1ps

module ov5640_capture #(
    parameter BYTES_PER_PIX = 2
)(
    input  wire        pclk,
    input  wire        rstn,
    input  wire        vsync,
    input  wire        href,
    input  wire [7:0]  data,

    output reg         pix_de,
    output reg  [7:0]  pix,
    output reg  [15:0] pix_x,
    output reg  [15:0] pix_y,
    output reg         pix_sof
);
    reg        vsync_d;
    reg        href_d;
    reg [15:0] bx;        // 行内字节序号
    reg [15:0] ycnt;      // 行号
    reg        sof_i;
    reg [7:0]  b0;        // 每像素的第一个字节（RGB565 时用它拼绿通道）

    // ---------------- 输入侧：与 DVP 同拍 ----------------
    always @(posedge pclk) begin
        if (!rstn) begin
            vsync_d <= 1'b0;
            href_d  <= 1'b0;
            bx      <= 16'd0;
            ycnt    <= 16'd0;
            sof_i   <= 1'b0;
            b0      <= 8'd0;
        end
        else begin
            vsync_d <= vsync;
            href_d  <= href;
            sof_i   <= vsync & ~vsync_d;

            if (vsync & ~vsync_d) begin
                bx   <= 16'd0;
                ycnt <= 16'd0;
            end
            else if (href) begin
                // 行内第一个 href 拍，bx 此刻是 0，处理完再 +1
                if (!href_d) bx <= 16'd1;
                else         bx <= bx + 16'd1;
                // 偶数序号字节是每像素的第一个字节
                if (bx[0] == 1'b0) b0 <= data;
            end
            else if (href_d) begin
                bx   <= 16'd0;
                ycnt <= ycnt + 16'd1;
            end
        end
    end

    // ---------------- 字节 -> 像素 ----------------
    wire        second_byte = (BYTES_PER_PIX == 1) ? 1'b1 : bx[0];
    wire [15:0] px_out      = (BYTES_PER_PIX == 1) ? bx : {1'b0, bx[15:1]};
    wire [7:0]  gray_out    = (BYTES_PER_PIX == 1) ? data
                                                    : {b0[2:0], data[7:5], 2'b00};

    // ---------------- 输出侧：统一寄存一级 ----------------
    always @(posedge pclk) begin
        if (!rstn) begin
            pix_de  <= 1'b0;
            pix     <= 8'd0;
            pix_x   <= 16'd0;
            pix_y   <= 16'd0;
            pix_sof <= 1'b0;
        end
        else begin
            pix_de  <= href & second_byte;
            pix     <= gray_out;
            pix_x   <= px_out;
            pix_y   <= ycnt;
            pix_sof <= sof_i;
        end
    end
endmodule