//======================================================================
// cnn_pe_array.v -- 16 路 int8 MAC 阵列（8 个输出通道 x 2 个像素）
//
// 为什么是「8 通道 x 2 像素」：
//   权重 ROM 一拍只能吐出 1 个字（64 位 = 8 个通道在同一个 tap 上的权重），
//   激活图一拍能读 2 个字节（双口 BRAM）。于是每个 PE 的
//     w 分量 = 通道 o（0..7，来自权重字）
//     a 分量 = 像素 p（0..1，来自两次激活读）
//   16 个乘法器恰好跑到「权重带宽 = 激活带宽」的平衡点。
//
// 一个乘法器身兼两职（省 DSP，这是本模块存在的核心理由）：
//   累加模式（mac_en=1）：mul_a = a（int8->24 位符号扩展）, mul_b = w（->17 位）
//                         acc += prod[23:0]
//   量化模式（mac_en=0）：mul_a = acc（24 位）, mul_b = {1'b0,m}（17 位）
//                         cnn_quant 拿 prod = acc*m 去做四舍五入 + 算术右移
//   同一个 `*`，综合只出 1 个乘法器；所以「量化那一拍」mac_en 必须是 0
//   （用 vision_cnn_top 的 S_CSTO / S_FCQ 时序保证，见那边的注释）。
//
// 踩过的坑：
//   * 累加器只给 24 位：最坏 144 tap x 127x127 ≈ 2.3e6 < 2^23 ✓。
//     （24 位 x 16 位 = 40 位积，所以 prod 取 41 位有符号，留符号位。）
//   * q_flat 用 generate 里的 assign 拼，避免用 reg 数组当端口。
//   * bias 的 part-select 不能直接当 l-value，先接一根 wire 出来。
//======================================================================
`timescale 1ns / 1ps

module cnn_pe_array (
    input  wire               clk,
    input  wire               rstn,

    input  wire               clr,        // 1 拍：把 bias 装进 16 个累加器
    input  wire               mac_en,     // 1 拍：acc += w*a
    input  wire               q_en,       // 1 拍：把量化结果锁进 q_flat（mac_en 必须为 0）
    input  wire               relu,       // 1 = 量化后做 ReLU（卷积层用）

    input  wire [255:0]       bias_flat,  // 8 个 int32，lane 的 o 分量取用
    input  wire [63:0]        w_word,     // 8 个 int8 权重（本 tap）
    input  wire [15:0]        a_pair,     // 2 个 int8 激活（两个像素）
    input  wire [15:0]        m,
    input  wire [7:0]         sh,

    output wire [127:0]       q_flat,     // 16 个 int8，lane l = o*2+p
    output wire               sat_any
);
    wire [15:0] sat_vec;

    genvar gi;
    generate
    for (gi = 0; gi < 16; gi = gi + 1) begin : g_lane
        wire [2:0] oc = gi / 2;          // 通道 0..7
        wire       pc = gi % 2;          // 像素 0..1

        wire signed [7:0] w_l = $signed(w_word[oc * 8 +: 8]);
        wire signed [7:0] a_l = $signed(a_pair[pc * 8 +: 8]);

        reg  signed [31:0] acc;
        reg  signed [7:0]  q_r;

        // ---- 唯一的那个乘法器：两用 ----
        wire signed [31:0] a_ext = {{24{a_l[7]}}, a_l};
        wire signed [16:0] w_ext = {{9{w_l[7]}}, w_l};
        wire signed [31:0] mul_a = mac_en ? a_ext : acc;
        wire signed [16:0] mul_b = mac_en ? w_ext : $signed({1'b0, m});
        wire signed [40:0] prod  = mul_a * mul_b;
        wire signed [31:0] prod32 = prod[31:0];

        wire signed [7:0] q_val;
        wire              q_sat;
        cnn_quant u_q (.prod(prod), .sh(sh), .y(q_val), .sat(q_sat));

        wire [31:0]        bias_w   = bias_flat[oc * 32 +: 32];
        wire signed [31:0] acc_next = mac_en ? (acc + prod32) : acc;
        wire signed [7:0]  q_eff    = (relu && (q_val < 8'sd0)) ? 8'sd0 : q_val;

        always @(posedge clk) begin
            if (!rstn) begin
                acc <= 32'sd0;
                q_r <= 8'sd0;
            end
            else begin
                if (clr)  acc <= bias_w;
                else      acc <= acc_next;

                if (q_en) q_r <= q_eff;
            end
        end

        assign q_flat[gi * 8 +: 8] = q_r;
        assign sat_vec[gi]         = q_sat;
    end
    endgenerate

    assign sat_any = |sat_vec;
endmodule