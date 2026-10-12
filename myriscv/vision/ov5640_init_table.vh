//======================================================================
// ov5640_init_table.vh -- OV5640 上电配置表（被 ov5640_sccb.v `include）
//
// 每条表项编码为 32 位：
//   [31:16] 寄存器地址（16 位，OV5640 用 16 位寄存器地址）
//   [15: 8] 写入数据
//   [ 7: 0] 本条目写完后需要等待的毫秒数（0 = 不等待）
//
// 函数式 case 实现，综合成一张小 ROM，PDS 可直接吃。
//
// ★★★ 数值需与厂商官方 OV5640 配置表核对 ★★★
//   本表的「结构」是正确的（软复位 -> 时钟/PLL -> 开输出 -> 时序 -> 分辨率 ->
//   输出格式 -> 唤醒），但具体数值受你手上的模组、XCLK 频率、上电时序影响。
//   上板第一步请用 ILA 抓 SCCB 波形确认写进去了，再用示波器看 PCLK/HREF。
//   当前目标：QVGA 320x240，RGB565，DVP 输出。
//
//   若你的模组出厂默认就能出图，也可以把 OV5640_SKIP_INIT 置 1 跳过整张表。
//======================================================================

localparam OV5640_INIT_N = 29;

function [31:0] ov5640_init_entry;
    input [5:0] idx;
    begin
        case (idx)
            6'd0 : ov5640_init_entry = {16'h3103, 8'h11, 8'd0 };  // 时钟来自 PAD
            6'd1 : ov5640_init_entry = {16'h3008, 8'h82, 8'd5 };  // 软复位，等 5ms
            6'd2 : ov5640_init_entry = {16'h3008, 8'h42, 8'd0 };  // 掉电，准备改时钟
            6'd3 : ov5640_init_entry = {16'h3103, 8'h03, 8'd0 };
            6'd4 : ov5640_init_entry = {16'h3017, 8'hff, 8'd0 };  // 打开全部输出
            6'd5 : ov5640_init_entry = {16'h3018, 8'hff, 8'd0 };
            6'd6 : ov5640_init_entry = {16'h3034, 8'h1a, 8'd0 };  // PLL 分频
            6'd7 : ov5640_init_entry = {16'h3037, 8'h13, 8'd0 };
            6'd8 : ov5640_init_entry = {16'h3108, 8'h01, 8'd0 };  // 系统时钟分频
            6'd9 : ov5640_init_entry = {16'h3035, 8'h21, 8'd0 };  // PLL 控制
            6'd10: ov5640_init_entry = {16'h3036, 8'h46, 8'd0 };
            6'd11: ov5640_init_entry = {16'h3820, 8'h46, 8'd0 };  // 时序
            6'd12: ov5640_init_entry = {16'h3821, 8'h00, 8'd0 };
            6'd13: ov5640_init_entry = {16'h3814, 8'h31, 8'd0 };  // 降采样
            6'd14: ov5640_init_entry = {16'h3815, 8'h31, 8'd0 };
            6'd15: ov5640_init_entry = {16'h3808, 8'h01, 8'd0 };  // H 宽 = 0x0140 = 320
            6'd16: ov5640_init_entry = {16'h3809, 8'h40, 8'd0 };
            6'd17: ov5640_init_entry = {16'h380A, 8'h00, 8'd0 };  // V 高 = 0x00F0 = 240
            6'd18: ov5640_init_entry = {16'h380B, 8'hF0, 8'd0 };
            6'd19: ov5640_init_entry = {16'h380C, 8'h07, 8'd0 };  // HTS
            6'd20: ov5640_init_entry = {16'h380D, 8'h68, 8'd0 };
            6'd21: ov5640_init_entry = {16'h380E, 8'h03, 8'd0 };  // VTS
            6'd22: ov5640_init_entry = {16'h380F, 8'h5C, 8'd0 };
            6'd23: ov5640_init_entry = {16'h3810, 8'h00, 8'd0 };  // ISP 开窗
            6'd24: ov5640_init_entry = {16'h3811, 8'h00, 8'd0 };
            6'd25: ov5640_init_entry = {16'h3812, 8'h00, 8'd0 };
            6'd26: ov5640_init_entry = {16'h3813, 8'h00, 8'd0 };
            6'd27: ov5640_init_entry = {16'h4300, 8'h6f, 8'd0 };  // 输出格式：RGB565
            6'd28: ov5640_init_entry = {16'h3008, 8'h02, 8'd0 };  // 唤醒
            default: ov5640_init_entry = {16'hFFFF, 8'hFF, 8'd0};
        endcase
    end
endfunction