//======================================================================
// viz_pix_buf.v -- 32x32 int8 像素缓冲（1 KB，跨时钟域：cam 域写、clk 域读）
//
// 为什么是「一个写口 + 两个组合读口」而不是标准真双口：
//   * 写口在 cam_pclk 域（viz_pix_crop 采样 + 归一化都要写）；
//   * cam 域自己还要读回来做「减去帧均值」（读-改-写），所以给它一个组合读口；
//   * clk 域（CNN 的 S_LOAD 状态）也要一个组合读口。
//   只有 1 KB，PDS 会推成分布式 RAM/小 BRAM，组合读没有问题；
//   真正的跨域同步靠 frame_toggle 握手（见 viz_pix_crop.v），
//   即「一帧写完才翻一次」，读的那一侧整帧数据都是稳定的，不会读到半新半旧。
//
// 踩过的坑：
//   * 同一拍对同一地址「读+写」拿到的是旧值（写是时钟沿生效），
//     viz_pix_crop 的归一化那一遍正是靠这个做 RMW 的。
//   * 别把读口做成时序读：CNN 的 S_LOAD 是「一拍取一个字节」，
//     组合读才能让 pix_rd_data 与 pix_rd_addr 同拍对齐。
//======================================================================
`timescale 1ns / 1ps

module viz_pix_buf (
    // ---- cam 域 ----
    input  wire        pclk,
    input  wire        we,
    input  wire [9:0]  waddr,
    input  wire [7:0]  wdata,
    input  wire [9:0]  raddr,      // cam 域组合读（归一化用）
    output wire [7:0]  rdata,

    // ---- clk 域 ----
    input  wire [9:0]  baddr,      // CNN LOAD 用
    output wire [7:0]  bdata
);
    reg [7:0] mem [0:1023];

    always @(posedge pclk) begin
        if (we) mem[waddr] <= wdata;
    end

    assign rdata = mem[raddr];
    assign bdata = mem[baddr];
endmodule