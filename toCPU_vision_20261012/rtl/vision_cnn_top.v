//======================================================================
// vision_cnn_top.v -- LiteNet-3 整网推理（clk 域）
//
// 位置：vision_top 里与 vision_classifier「二选一」（参数 USE_CNN）。
//       端口是 vision_classifier 的**超集**，下游 vision_regs 一行都不用改。
//
// 数据通路（图像不进 CPU、不进 Cache）：
//   viz_pix_crop（cam 域）--双口 BRAM--> 本模块 LOAD -> L0..L7 -> 结果寄存器
//
// 激活图存储约定：**通道后置** [y][x][c]，每像素 ci 个字节。
//   为什么：卷积/池化的写回天然是「同一像素的相邻若干通道」，
//   通道后置才能整字写；读的时候两个端口各取所需的那 1 个字节。
//
// 双缓冲（ping-pong，按层交替，省一半 BRAM）：
//   memA: 网络输入 / L1 输出 / L3 输出 / L5 输出
//   memB: L0 输出 / L2 输出 / L4 输出
//   深度由 cnn_defs.vh 的 `CNN_MEMA_AW/`CNN_MEMB_AW 决定（生成器按层输出字节数算），
//   换网络结构（--channels）重新生成权重即自动适配，本文件不再写死容量。
//   规律：in_sel = cur[0]（第 1/3/5 层读 memB），输出恒为另一张。
//
// 卷积循环：og（8 通道一组）-> y -> pg（2 像素一组）-> tap
//   一拍一个 tap：16 个 PE 同时算 8 通道 x 2 像素；
//   权重来自 cnn_rom 的 64 位字（同一 tap 的 8 个通道），
//   激活来自两个读口（像素 x0 与 x0+1 各 1 个字节）。
//   地址用「增量 + 常量步长」推，每拍不做乘法：
//     t_off                   : c/kx 边界都是 +1，tky 边界 +(iw-k)*ci+1
//     pix_base / out_pix_base : 每步 +2*ci / +2*co（跨行/跨列同一步长）
//
// 层参数全部来自 cnn_defs.vh / cnn_weights.vh 的 cfg 表（单一真源），
// 本文件里不写死任何一层网络形状。
//
// 卷积的一次输出（2 像素 x 8 通道 = 16 字节）的收尾时序（S_CSTO 的 4 拍）：
//   cst=0  等最后一个 MAC 落进 acc（这一拍 mac_en 还是 1）
//   cst=1  量化：mac_en=0，PE 里那个共用乘法器算出 acc*m -> q_r
//   cst=2  mem 端口 1/2 写像素 0 的 8 个通道
//   cst=3  写像素 1 的 8 个通道，然后推进 pg / 行 / og 的循环
//   （量化必须单独占一拍，因为「共用乘法器」模式下 mac 和量化不能同拍。）
//
// 踩过的坑：
//   * 累加器只给 24 位：最坏 288 tap（L4 输入 32ch x 3x3）x 127x127 ≈ 4.6e6 < 2^23
//     （见 cnn_pe_array.v）；tcnt 已扩 16 位，taps>255 不再截断（原来 [7:0] 会把
//     288 截成 32，循环提前停）。
//   * 权重 ROM 与激活 BRAM 都是 1 拍读延迟：同一拍发两个地址、下一拍 mac_en。
//     tcnt=0 那一拍顺便 clr（装 bias），省一个状态。
//   * 权重**不能**再插一级寄存器：ROM 的读出寄存器本身就是那 1 拍延迟，
//     再串一级 w 就比激活慢 1 拍，每个 tap 都错位（校验和会整层不匹配）。
//   * t_off/tky/tkx/tc 必须每个像素对清零：它们是一路累加出来的，
//     不清零就会把上一对的偏移带进来。
//   * pix_base/out_pix_base 是「og 组内相对」的，换 og 组要回到 pix_base_init/0。
//   * 池化的 ppb 是**字**地址：每 4 个通道 +1，每跨 2 列 +2*(ci/4)，换行再加
//     (2*prow - 2*ow*(ci/4))。pob 每写 1 个字 +1（行首自动对齐，不用额外修）。
//   * GAP 换通道时 gpair 要清零，否则第二个通道只累加 1 个像素。
//   * c0_ok 里带 (tcnt < taps)：最后一个"多出来"的拍不去读内存，
//     免得把相邻层的数据当成激活读进来（仿真里表现为 X 或脏数据）。
//   * 写回字节序：lane = o*2+p，q[o][p] = pe_q_flat[8*(o*2+p)]，
//     一个字里 byte0 是通道 o%4 最小者。写反了 TB 会立刻报校验和不符。
//   * 端口地址是「组合」的（由状态与计数器算），读数据 1 拍后才回来；
//     所以字节选择 dsel 必须自己延后一拍。
//   * 调试读口借用 memA/memB 的端口 1（dbg_rd_en=1 时接管地址），
//     只能在引擎 IDLE 时用 —— TB 就是这么用的。
//   * LOAD 的字节使能必须组合（见 a1_be）：它若晚一拍，1024 个输入字节整体错位 1，
//     L0 校验和从第一层就对不上。
//   * 新的一帧开始时 cur 必须清零：漏了的话第一帧之后只跑最后一层（"只能跑一次"的坑）。
//   * 层参数（rom_cfg_addr）也必须组合驱动：cnn_rom 的 cfg 是组合读，
//     地址晚一拍会让 ci/co/k/ih/iw/oh/ow/taps/m/sh 整列错位一个字段。
//   * 逐层比对靠 dbg_halt/dbg_at_halt：每层算完停在 S_HALT，TB 用 dbg 读口读整张图。
//   * GAP 的 >>6 用算术右移，和 Python 的 >> 在负数上一致。
//======================================================================
`timescale 1ns / 1ps

module vision_cnn_top (
    input  wire        clk,
    input  wire        rstn,

    // ---- 与 vision_classifier 同义的统计结果 ----
    input  wire        frame_new,
    input  wire [31:0] fg_cnt,
    input  wire [31:0] box_x0,
    input  wire [31:0] box_y0,
    input  wire [31:0] box_x1,
    input  wire [31:0] box_y1,
    input  wire [31:0] roi_w,
    input  wire [31:0] roi_h,
    input  wire [31:0] min_pix,
    input  wire [31:0] area_c_max,     // CNN 版用不到，保留端口以对齐替换点

    // ---- 图像入口（cam 域写完一帧翻 pix_frame_toggle，这里打两拍取边沿）----
    input  wire        pix_frame_toggle,
    output wire [9:0]  pix_rd_addr,
    input  wire [7:0]  pix_rd_data,

    // ---- 结果 ----
    output reg  [31:0] cls,
    output reg  [31:0] score,
    output reg  [31:0] obj_w,
    output reg  [31:0] obj_h,
    output reg         valid,
    output reg         done,
    output reg  [31:0] cycles,

    input  wire         dbg_rd_en,
    input  wire [1:0]   dbg_sel,
    input  wire [15:0]  dbg_addr,
    input  wire         dbg_halt,
    output reg          dbg_at_halt,
    output wire [7:0]   dbg_data
);

    `include "cnn_defs.vh"
    localparam KIND_CONV = 2'd0;
    localparam KIND_POOL = 2'd1;
    localparam KIND_GAP  = 2'd2;
    localparam KIND_FC   = 2'd3;

    localparam S_IDLE  = 5'd0;
    localparam S_LOAD  = 5'd1;
    localparam S_LCFG  = 5'd2;
    localparam S_LCFG2 = 5'd3;
    localparam S_CBIAS = 5'd4;
    localparam S_CTAP  = 5'd5;
    localparam S_CSTO  = 5'd6;
    localparam S_CMAC  = 5'd19;
    localparam S_POOLR = 5'd7;
    localparam S_POOLW = 5'd8;
    localparam S_GAPR  = 5'd9;
    localparam S_GAPW  = 5'd10;
    localparam S_FCB   = 5'd11;
    localparam S_FCM   = 5'd12;
    localparam S_FCQ   = 5'd13;
    localparam S_FCQ2  = 5'd14;
    localparam S_FIN   = 5'd15;
    localparam S_DIV   = 5'd16;
    localparam S_OUT   = 5'd17;
    localparam S_HALT  = 5'd18;        // 层边界调试暂停点

    // 激活缓冲深度由 cnn_defs.vh 给出（生成器按层输出字节数算好，换结构不用改 RTL）
    localparam AW  = `CNN_MEMA_AW;      // memA 地址位宽（生成器按最大 pool 层输出算）
    localparam BW  = `CNN_MEMB_AW;      // memB 地址位宽（生成器按最大 conv 层输出算）
    localparam BWA = (BW > AW) ? BW : AW;   // 两缓冲字地址位宽的较大者（字节地址用 BWA+1 位）

    //==================================================================
    // 激活图存储：两张，各两个读写端口（字节写使能）
    //==================================================================
    reg [31:0] memA [0:(1<<AW)-1];
    reg [31:0] memB [0:(1<<BW)-1];

    reg           a1_we,   a2_we;
    reg  [31:0]   a1_wdata, a2_wdata;
    reg  [3:0]    a1_wstrb, a2_wstrb;
    wire [31:0]   a1_rdata, a2_rdata;
    reg           b1_we,   b2_we;
    reg  [31:0]   b1_wdata, b2_wdata;
    reg  [3:0]    b1_wstrb, b2_wstrb;
    wire [31:0]   b1_rdata, b2_rdata;

    reg  [AW-1:0] a1_addr, a2_addr;
    reg  [BW-1:0] b1_addr, b2_addr;

    // LOAD 期间 a1_addr/a1_wdata 都是组合的，byte enable 也必须组合：
    // 它是寄存器的话「使能位置」会比「地址/数据」晚一拍，整段输入整体错位 1 字节
    // （逐层校验和会从 L0 就整层不对）。其余状态都是整字写，用 4 hF。
    wire [3:0] a1_be = (state == S_LOAD) ? (4'h1 << cyc_cnt[1:0]) : a1_wstrb;

    always @(posedge clk) begin
        if (a1_we) begin
            if (a1_be[0]) memA[a1_addr][7:0]   <= a1_wdata[7:0];
            if (a1_be[1]) memA[a1_addr][15:8]  <= a1_wdata[15:8];
            if (a1_be[2]) memA[a1_addr][23:16] <= a1_wdata[23:16];
            if (a1_be[3]) memA[a1_addr][31:24] <= a1_wdata[31:24];
        end
    end

    always @(posedge clk) begin
        if (a2_we) begin
            if (a2_wstrb[0]) memA[a2_addr][7:0]   <= a2_wdata[7:0];
            if (a2_wstrb[1]) memA[a2_addr][15:8]  <= a2_wdata[15:8];
            if (a2_wstrb[2]) memA[a2_addr][23:16] <= a2_wdata[23:16];
            if (a2_wstrb[3]) memA[a2_addr][31:24] <= a2_wdata[31:24];
        end
    end

    always @(posedge clk) begin
        if (b1_we) begin
            if (b1_wstrb[0]) memB[b1_addr][7:0]   <= b1_wdata[7:0];
            if (b1_wstrb[1]) memB[b1_addr][15:8]  <= b1_wdata[15:8];
            if (b1_wstrb[2]) memB[b1_addr][23:16] <= b1_wdata[23:16];
            if (b1_wstrb[3]) memB[b1_addr][31:24] <= b1_wdata[31:24];
        end
    end

    always @(posedge clk) begin
        if (b2_we) begin
            if (b2_wstrb[0]) memB[b2_addr][7:0]   <= b2_wdata[7:0];
            if (b2_wstrb[1]) memB[b2_addr][15:8]  <= b2_wdata[15:8];
            if (b2_wstrb[2]) memB[b2_addr][23:16] <= b2_wdata[23:16];
            if (b2_wstrb[3]) memB[b2_addr][31:24] <= b2_wdata[31:24];
        end
    end

    assign a1_rdata = memA[a1_addr];
    assign a2_rdata = memA[a2_addr];
    assign b1_rdata = memB[b1_addr];
    assign b2_rdata = memB[b2_addr];

    //==================================================================
    // 权重 ROM
    //==================================================================
    wire [15:0]  rom_cfg_addr;      // ★ 组合驱动，见下面 assign 与文件头踩过的坑
    wire [31:0]  rom_cfg_data;
    reg  [`CNN_W_AW-1:0]  rom_w_addr;
    wire [63:0]  rom_w_data;
    reg  [`CNN_B_AW-1:0]  rom_b_addr;
    wire [255:0] rom_b_data;
    reg  [`CNN_FC_AW-1:0] rom_fc_addr;
    wire [31:0]  rom_fc_data;
    localparam integer FC_BW = `CNN_FC_GROUPS * 128;
    wire [FC_BW-1:0] rom_fc_bias;

    cnn_rom #(.FC_BW(FC_BW)) u_rom (
        .clk(clk), .w_addr(rom_w_addr), .w_data(rom_w_data),
        .b_addr(rom_b_addr), .b_data(rom_b_data),
        .cfg_addr(rom_cfg_addr[7:0]), .cfg_data(rom_cfg_data),
        .fc_addr(rom_fc_addr), .fc_data(rom_fc_data), .fc_bias(rom_fc_bias)
    );

    //==================================================================
    // PE 阵列 + 定点除法
    //==================================================================
    reg          pe_clr, pe_mac, pe_q, pe_relu;
    reg  [255:0] pe_bias;
    reg  [63:0]  pe_w;
    reg  [15:0]  pe_a;
    reg  [15:0]  pe_m;
    reg  [7:0]   pe_sh;
    wire [127:0] pe_q_flat;
    wire         pe_sat;

    // PE 阵列的控制 mux：★ 声明必须在例化之前。
    // 放在例化之后时，iverilog 会把例化处的引用当成隐式 wire 并给 -Wall 告警，
    // 宽度也按 1 位推断（踩过的坑）。赋值统一写在下面的组合逻辑区。
    wire         pe_clr_mux, pe_mac_mux, pe_q_mux;
    wire [63:0]  pe_w_mux;
    wire [15:0]  pe_a_mux;

    cnn_pe_array u_pe (
        .clk(clk), .rstn(rstn), .clr(pe_clr_mux), .mac_en(pe_mac_mux), .q_en(pe_q_mux), .relu(pe_relu),
        .bias_flat(pe_bias), .w_word(pe_w_mux), .a_pair(pe_a_mux), .m(pe_m), .sh(pe_sh),
        .q_flat(pe_q_flat), .sat_any(pe_sat)
    );

    reg         div_start;
    reg  [31:0] div_a, div_b;
    wire [31:0] div_q;
    wire        div_busy, div_dn;

    div_u32_seq u_div (
        .clk(clk), .rstn(rstn), .start(div_start),
        .dividend(div_a), .divisor(div_b),
        .quotient(div_q), .busy(div_busy), .done(div_dn)
    );

    //==================================================================
    // 状态、层参数、循环计数器
    //==================================================================
    reg [4:0]  state;
    reg [4:0]  lcf;
    reg [3:0]  cur;      // 层号：0..CNN_NLAYER-1（10 层结构需 4 位）
    reg        in_sel;

    reg [1:0]  kind;
    reg [15:0] ci, co, kk, ih, iw, oh, ow, taps;
    reg [15:0] wbase, w_grp, bbase, pad;
    reg [31:0] pix_base_init;          // 每个 og 组开始 pix_base 要回到这里
    reg [15:0] qm;
    reg [7:0]  qsh;
    reg [31:0] pix_base, out_pix_base, pix_delta, out_delta, tky_delta;

    reg [15:0] og, loy, lopg;
    reg [15:0] tcnt;
    reg [15:0] tky, tkx, tc, t_off;
    reg [1:0]  cst;

    reg [15:0] poy, pox, pk;
    reg [1:0]  pph;
    reg [15:0] ppb, pob, pci4, prow;
    reg [31:0] pdelta_ox, pdelta_oy;
    reg [31:0] pool_a, pool_b;

    reg [7:0]  gci;   // 8 位：gap 输出通道可达 96（6 位到 63 会溢出死循环，加深版踩坑）
    reg [15:0] gpair;
    reg [31:0] gb;
    reg signed [23:0] gacc;
    reg [`CNN_FC_IN*8-1:0] gap_flat;

    reg [7:0]  fci;    // 8 位：fc 输入通道数可达 144（7 位到 127 会卡死，见 S_FCM 死循环坑；deep 96 恰好够、wider3 144 必现）
    reg [4:0]  fc_group;
    reg [`CNN_CLASSES*8-1:0] logit_flat;
    reg [31:0] fg_l, bx0_l, bx1_l, by0_l, by1_l, minpix_l;
    reg [31:0] cyc_cnt, conf_l;
    reg [6:0]  am_l;
    reg signed [7:0] best_l, second_l, min_l;

    reg [1:0]  dselA, dselB;
    reg        v0_d, v1_d;

    wire in_from_b = in_sel;
    wire out_in_a  = in_sel;
    wire [AW-1:0] dbgA_word = dbg_addr[AW+1:2];
    wire [BW-1:0] dbgB_word = dbg_addr[BW+1:2];

    reg  [BWA+1:0] in_p1_addr, in_p2_addr;
    reg  [BW-1:0] in_p1_word, in_p2_word;
    reg         use_word_addr;
    reg  [AW-1:0] out_p1_addr_w, out_p2_addr_w;
    reg  [BW-1:0] out_p1_addr_b, out_p2_addr_b;
    reg           out_p1_we, out_p2_we;
    reg  [31:0]   out_p1_data, out_p2_data;
    reg  [BW-1:0] ld_word;
    reg           ld_we;

    wire [31:0] in_r1 = in_from_b ? b1_rdata : a1_rdata;
    wire [31:0] in_r2 = in_from_b ? b2_rdata : a2_rdata;
    wire [7:0]  byte0 = in_r1 >> {dselA, 3'b000};
    wire [7:0]  byte1 = in_r2 >> {dselB, 3'b000};
    wire [15:0] act_pair = { (v1_d ? byte1 : 8'd0), (v0_d ? byte0 : 8'd0) };
    wire [7:0]  byte0_now = in_r1 >> {in_addr0[1:0], 3'b000};
    wire [7:0]  byte1_now = in_r2 >> {in_addr1[1:0], 3'b000};
    wire [15:0] act_pair_now = { (c1_ok ? byte1_now : 8'd0),
                                 (c0_ok ? byte0_now : 8'd0) };
    wire [1:0] gap_sel_b = gb[1:0] + ci[1:0];
    wire [7:0] gap_byte0 = in_r1 >> {gb[1:0], 3'b000};
    wire [7:0] gap_byte1 = in_r2 >> {gap_sel_b, 3'b000};
    assign pe_w_mux   = (state == S_CMAC) ? rom_w_data :
                        (state == S_FCM) ? {32'd0, rom_fc_data} : pe_w;
    assign pe_clr_mux = ((state == S_CTAP) && (tcnt == 16'd0)) ||
                        ((state == S_FCM) && (fci == 8'd0));
    assign pe_mac_mux = (state == S_CMAC) ||
                        ((state == S_FCM) && (fci >= 8'd1));
    assign pe_q_mux   = ((state == S_CSTO) && (cst == 2'd0)) ||
                        (state == S_FCQ);
    assign pe_a_mux   = (state == S_CMAC) ? act_pair_now :
                        (state == S_FCM) ? {8'd0, gap_flat[fcw_i*8 +: 8]} : pe_a;

    wire [15:0] in_row  = loy + tky;
    wire [15:0] in_col0 = {lopg, 1'b0} + tkx;
    wire        row_ok  = (in_row >= pad) && ((in_row - pad) < ih);
    wire        tap_ok  = (tcnt < taps);
    wire        c0_ok   = row_ok && tap_ok && (in_col0 >= pad) && ((in_col0 - pad) < iw);
    wire        c1_ok   = row_ok && tap_ok && ((in_col0 + 16'd1) >= pad) &&
                          ((in_col0 + 16'd1 - pad) < iw);
    wire [31:0] in_addr0 = pix_base + t_off;
    wire [31:0] in_addr1 = in_addr0 + {16'd0, ci};
    wire [31:0] gap_addr2 = gb + ci;      // iverilog 不支持 (expr)[msb:lsb]，先算出再选

    wire [31:0] out_word_base = (out_pix_base >> 2) + {25'd0, og[6:0], 1'b0};
    wire [31:0] ow_a = out_word_base;
    wire [31:0] ow_b = out_word_base + 32'd1;
    wire [31:0] ow_c = out_word_base + {26'd0, co[7:2]};
    wire [31:0] ow_d = ow_c + 32'd1;

    wire [31:0] qw_a = {pe_q_flat[8*6+:8],  pe_q_flat[8*4+:8],  pe_q_flat[8*2+:8],  pe_q_flat[8*0+:8]};
    wire [31:0] qw_b = {pe_q_flat[8*14+:8], pe_q_flat[8*12+:8], pe_q_flat[8*10+:8], pe_q_flat[8*8+:8]};
    wire [31:0] qw_c = {pe_q_flat[8*7+:8],  pe_q_flat[8*5+:8],  pe_q_flat[8*3+:8],  pe_q_flat[8*1+:8]};
    wire [31:0] qw_d = {pe_q_flat[8*15+:8], pe_q_flat[8*13+:8], pe_q_flat[8*11+:8], pe_q_flat[8*9+:8]};

    wire signed [7:0] lg0 = pe_q_flat[8*0+:8];
    wire signed [7:0] lg1 = pe_q_flat[8*2+:8];
    wire signed [7:0] lg2 = pe_q_flat[8*4+:8];
    wire signed [7:0] lg3 = pe_q_flat[8*6+:8];

    // ★ 必须是有符号比较：激活是 int8，负数用无符号比会取错（pool 层整层错）
    function signed [7:0] fmax8;
        input signed [7:0] x, y;
        begin fmax8 = (x > y) ? x : y; end
    endfunction

    function signed [7:0] sat8;
        input signed [23:0] v;
        begin
            sat8 = (v > 24'sd127) ? 8'sd127 : (v < -24'sd128) ? -8'sd128 : v[7:0];
        end
    endfunction

    wire [31:0] pool_wmax = {
        fmax8(fmax8(pool_a[31:24], pool_b[31:24]), fmax8(in_r1[31:24], in_r2[31:24])),
        fmax8(fmax8(pool_a[23:16], pool_b[23:16]), fmax8(in_r1[23:16], in_r2[23:16])),
        fmax8(fmax8(pool_a[15:8],  pool_b[15:8]),  fmax8(in_r1[15:8],  in_r2[15:8])),
        fmax8(fmax8(pool_a[7:0],   pool_b[7:0]),   fmax8(in_r1[7:0],   in_r2[7:0])) };

    wire signed [23:0] gsum = gacc + $signed({{16{gap_byte0[7]}}, gap_byte0}) +
                               $signed({{16{gap_byte1[7]}}, gap_byte1});

    wire [7:0] fcw_i = (fci >= 8'd1) ? (fci - 8'd1) : 8'd0;
    wire [6:0] fc_base = {fc_group, 2'b00};

    reg [1:0] ft_sync;
    always @(posedge clk or negedge rstn) begin
        if (!rstn) ft_sync <= 2'b00;
        else       ft_sync <= {ft_sync[0], pix_frame_toggle};
    end
    wire ft_edge = ft_sync[0] ^ ft_sync[1];

    wire [15:0] pg_lim  = ow >> 1;
    wire [15:0] og_lim  = co >> 3;
    wire [15:0] gn_pair = (ih * iw) >> 1;

    reg [1:0] am_c;
    reg signed [7:0] amax_c, asec_c, amin_c;
    always @(*) begin
        am_c = 2'd0; amax_c = lg0;
        if (lg1 > amax_c) begin am_c = 2'd1; amax_c = lg1; end
        if (lg2 > amax_c) begin am_c = 2'd2; amax_c = lg2; end
        if (lg3 > amax_c) begin am_c = 2'd3; amax_c = lg3; end
        asec_c = -8'sd128;
        if ((am_c != 2'd0) && (lg0 > asec_c)) asec_c = lg0;
        if ((am_c != 2'd1) && (lg1 > asec_c)) asec_c = lg1;
        if ((am_c != 2'd2) && (lg2 > asec_c)) asec_c = lg2;
        if ((am_c != 2'd3) && (lg3 > asec_c)) asec_c = lg3;
        amin_c = lg0;
        if (lg1 < amin_c) amin_c = lg1;
        if (lg2 < amin_c) amin_c = lg2;
        if (lg3 < amin_c) amin_c = lg3;
    end

    // 合并当前 4-lane FC 结果，严格使用 > 保持 golden 的先出现类别优先。
    reg signed [7:0] best_c, second_c, min_c;
    reg [6:0] best_idx_c;
    always @(*) begin
        if (fc_group == 5'd0) begin
            best_c = -8'sd128;
            second_c = -8'sd128;
            min_c = 8'sd127;
            best_idx_c = 7'd0;
        end
        else begin
            best_c = best_l;
            second_c = second_l;
            min_c = min_l;
            best_idx_c = am_l;
        end
        if (lg0 > best_c) begin second_c = best_c; best_c = lg0; best_idx_c = fc_base; end
        else if (lg0 > second_c) second_c = lg0;
        if (lg1 > best_c) begin second_c = best_c; best_c = lg1; best_idx_c = fc_base + 7'd1; end
        else if (lg1 > second_c) second_c = lg1;
        if (lg2 > best_c) begin second_c = best_c; best_c = lg2; best_idx_c = fc_base + 7'd2; end
        else if (lg2 > second_c) second_c = lg2;
        if (lg3 > best_c) begin second_c = best_c; best_c = lg3; best_idx_c = fc_base + 7'd3; end
        else if (lg3 > second_c) second_c = lg3;
        if (lg0 < min_c) min_c = lg0;
        if (lg1 < min_c) min_c = lg1;
        if (lg2 < min_c) min_c = lg2;
        if (lg3 < min_c) min_c = lg3;
    end
    //==================================================================
    // 端口请求（组合）：把「引擎想要什么」翻译成端口地址/写使能
    //==================================================================
    always @(*) begin
        in_p1_addr = 13'd0; in_p2_addr = 13'd0;
        in_p1_word = {BW{1'b0}}; in_p2_word = {BW{1'b0}};
        use_word_addr = 1'b0;
        out_p1_addr_w = {AW{1'b0}}; out_p2_addr_w = {AW{1'b0}};
        out_p1_addr_b = {BW{1'b0}}; out_p2_addr_b = {BW{1'b0}};
        out_p1_we = 1'b0; out_p2_we = 1'b0; out_p1_data = 32'd0; out_p2_data = 32'd0;
        ld_word = {BW{1'b0}}; ld_we = 1'b0;

        case (state)
        S_LOAD: begin
            // 一拍读一个字节（pix_rd_data 是组合读），只写它所在的那条字节道；
            // 4 拍拼满一个字，1024 拍正好把 32x32 的 int8 输入铺进 memA[0..255]
            ld_word     = cyc_cnt[9:2];
            ld_we       = (cyc_cnt < 32'd1024);
            out_p1_data = {4{pix_rd_data}};
        end
        S_CTAP: begin
            in_p1_addr = c0_ok ? in_addr0[BWA+1:0] : {BWA+2{1'b0}};
            in_p2_addr = c1_ok ? in_addr1[BWA+1:0] : {BWA+2{1'b0}};
        end
        S_CMAC: begin
            in_p1_addr = c0_ok ? in_addr0[BWA+1:0] : {BWA+2{1'b0}};
            in_p2_addr = c1_ok ? in_addr1[BWA+1:0] : {BWA+2{1'b0}};
        end
        S_CSTO: begin
            // 写回分两拍：第 2 拍写 qw_a/qw_b（像素 0 的 8 个通道），
            //             第 3 拍写 qw_c/qw_d（像素 1 的 8 个通道）
            if (cst == 2'd2) begin
                out_p1_addr_w = ow_a[AW-1:0]; out_p2_addr_w = ow_b[AW-1:0];
                out_p1_addr_b = ow_a[BW-1:0]; out_p2_addr_b = ow_b[BW-1:0];
                out_p1_data = qw_a; out_p2_data = qw_b;
                out_p1_we = 1'b1; out_p2_we = 1'b1;
            end
            else if (cst == 2'd3) begin
                out_p1_addr_w = ow_c[AW-1:0]; out_p2_addr_w = ow_d[AW-1:0];
                out_p1_addr_b = ow_c[BW-1:0]; out_p2_addr_b = ow_d[BW-1:0];
                out_p1_data = qw_c; out_p2_data = qw_d;
                out_p1_we = 1'b1; out_p2_we = 1'b1;
            end
        end
        S_POOLR: begin
            use_word_addr = 1'b1;
            if (pph == 2'd0) begin
                in_p1_word = ppb[BW-1:0];
                in_p2_word = ppb[BW-1:0] + pci4[BW-1:0];
            end
            else begin
                in_p1_word = ppb[BW-1:0] + prow[BW-1:0];
                in_p2_word = ppb[BW-1:0] + prow[BW-1:0] + pci4[BW-1:0];
            end
        end
        S_POOLW: begin
            use_word_addr = 1'b1;
            in_p1_word = ppb[BW-1:0] + prow[BW-1:0];
            in_p2_word = ppb[BW-1:0] + prow[BW-1:0] + pci4[BW-1:0];
            out_p1_addr_w = pob[AW-1:0]; out_p1_addr_b = pob[BW-1:0];
            out_p1_data = pool_wmax;
            out_p1_we = 1'b1;
        end
        S_GAPR: begin
            in_p1_addr = (gpair < gn_pair) ? gb[BWA+1:0] : {BWA+2{1'b0}};
            in_p2_addr = (gpair < gn_pair) ? gap_addr2[BWA+1:0] : {BWA+2{1'b0}};
        end
        default: begin
            in_p1_addr = 13'd0; in_p2_addr = 13'd0;
        end
        endcase
    end

    always @(*) begin
        // ---- memA ----
        if (state == S_LOAD) begin
            a1_addr = ld_word[AW-1:0];
            a1_we   = ld_we;
        end
        else if (out_in_a) begin
            a1_addr = dbg_rd_en ? dbgA_word : out_p1_addr_w;
            a1_we   = dbg_rd_en ? 1'b0 : out_p1_we;
        end
        else begin
            a1_addr = dbg_rd_en ? dbgA_word :
                      (use_word_addr ? in_p1_word[AW-1:0] :
                       ((state == S_CTAP || state == S_CMAC) ? in_addr0[BWA+1:2] : in_p1_addr[BWA+1:2]));
            a1_we   = 1'b0;
        end
        a1_wdata = out_p1_data;

        if (out_in_a) begin
            a2_addr = out_p2_addr_w; a2_we = out_p2_we;
        end
        else begin
            a2_addr = use_word_addr ? in_p2_word[AW-1:0] :
                      ((state == S_CTAP || state == S_CMAC) ? in_addr1[BWA+1:2] : in_p2_addr[BWA+1:2]);
            a2_we   = 1'b0;
        end
        a2_wdata = out_p2_data;

        // ---- memB ----
        if (out_in_a) begin
            b1_addr = dbg_rd_en ? dbgB_word :
                      (use_word_addr ? in_p1_word :
                       ((state == S_CTAP || state == S_CMAC) ? in_addr0[BW+1:2] : in_p1_addr[BWA+1:2]));
            b1_we   = 1'b0;
        end
        else begin
            b1_addr = dbg_rd_en ? dbgB_word : out_p1_addr_b;
            b1_we   = dbg_rd_en ? 1'b0 : out_p1_we;
        end
        b1_wdata = out_p1_data;

        if (out_in_a) begin
            b2_addr = use_word_addr ? in_p2_word :
                      ((state == S_CTAP || state == S_CMAC) ? in_addr1[BW+1:2] : in_p2_addr[BWA+1:2]);
            b2_we   = 1'b0;
        end
        else begin
            b2_addr = out_p2_addr_b; b2_we = out_p2_we;
        end
        b2_wdata = out_p2_data;

        // 调试读口必须独立于当前层的 in_sel：层完成后 in_sel 已经翻转，
        // 此时需要同时给两张缓冲送入调试地址，再由 dbg_sel 选择目标存储器。
        if (dbg_rd_en) begin
            a1_addr = dbgA_word;
            a1_we   = 1'b0;
            b1_addr = dbgB_word;
            b1_we   = 1'b0;
        end
    end

    //==================================================================
    // cfg ROM 是组合读（cnn_rom 里就是 assign），地址必须组合：
    // 地址若是寄存器输出，同一拍抓到的 rom_cfg_data 就是「上一个字段」，
    // 整层的 ci/co/k/ih/iw/oh/ow/taps/m/sh 会集体晚一拍（踩过的坑）。
    assign rom_cfg_addr = ({11'd0, cur} * `CNN_CFG_N) + {11'd0, lcf};

    //==================================================================
    // 主状态机
    //==================================================================
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state <= S_IDLE; lcf <= 5'd0; cur <= 4'd0; in_sel <= 1'b0;
            kind <= KIND_CONV; ci <= 16'd0; co <= 16'd0; kk <= 16'd0;
            ih <= 16'd0; iw <= 16'd0; oh <= 16'd0; ow <= 16'd0; taps <= 16'd0;
            wbase <= 16'd0; w_grp <= 16'd0; bbase <= 16'd0; pad <= 16'd0;
            qm <= 16'd1; qsh <= 8'd0;
            pix_base <= 32'd0; pix_base_init <= 32'd0; out_pix_base <= 32'd0;
            pix_delta <= 32'd0; out_delta <= 32'd0; tky_delta <= 32'd0;
            og <= 16'd0; loy <= 16'd0; lopg <= 16'd0; tcnt <= 16'd0;
            tky <= 16'd0; tkx <= 16'd0; tc <= 16'd0; t_off <= 16'd0; cst <= 2'd0;
            poy <= 16'd0; pox <= 16'd0; pk <= 16'd0; pph <= 2'd0;
            ppb <= 16'd0; pob <= 16'd0; pci4 <= 16'd0; prow <= 16'd0;
            pdelta_ox <= 32'd0; pdelta_oy <= 32'd0; pool_a <= 32'd0; pool_b <= 32'd0;
            gci <= 8'd0; gpair <= 16'd0; gb <= 32'd0; gacc <= 24'sd0;
            gap_flat <= {`CNN_FC_IN*8{1'b0}};
            fci <= 8'd0; fc_group <= 5'd0; logit_flat <= {`CNN_CLASSES*8{1'b0}};
            fg_l <= 32'd0; bx0_l <= 32'd0; bx1_l <= 32'd0; by0_l <= 32'd0; by1_l <= 32'd0;
            minpix_l <= 32'd0; cyc_cnt <= 32'd0; conf_l <= 32'd0; am_l <= 7'd0;
            best_l <= -8'sd128; second_l <= -8'sd128; min_l <= 8'sd127;
            cls <= 32'd255; score <= 32'd0; obj_w <= 32'd0; obj_h <= 32'd0;
            valid <= 1'b0; done <= 1'b0; cycles <= 32'd0; dbg_at_halt <= 1'b0;
            pe_clr <= 1'b0; pe_mac <= 1'b0; pe_q <= 1'b0; pe_relu <= 1'b1;
            pe_bias <= 256'd0; pe_w <= 64'd0; pe_a <= 16'd0; pe_m <= 16'd1; pe_sh <= 8'd0;
            rom_w_addr <= {`CNN_W_AW{1'b0}}; rom_b_addr <= {`CNN_B_AW{1'b0}};
            rom_fc_addr <= {`CNN_FC_AW{1'b0}};
            pix_base_init <= 32'd0;
            dselA <= 2'd0; dselB <= 2'd0; v0_d <= 1'b0; v1_d <= 1'b0;
            div_start <= 1'b0; div_a <= 32'd0; div_b <= 32'd0;
            a1_wstrb <= 4'h0; a2_wstrb <= 4'h0; b1_wstrb <= 4'h0; b2_wstrb <= 4'h0;
        end
        else begin
            done      <= 1'b0;
            div_start <= 1'b0;
            pe_clr    <= 1'b0;
            pe_mac    <= 1'b0;
            pe_q      <= 1'b0;
            rom_w_addr <= {`CNN_W_AW{1'b0}}; rom_fc_addr <= {`CNN_FC_AW{1'b0}};
            rom_b_addr <= {`CNN_B_AW{1'b0}};
            a1_wstrb <= 4'hF; a2_wstrb <= 4'hF; b1_wstrb <= 4'hF; b2_wstrb <= 4'hF;

            if ((state != S_IDLE) && (state != S_HALT)) cyc_cnt <= cyc_cnt + 32'd1;

            if (frame_new) begin
                fg_l <= fg_cnt; bx0_l <= box_x0; bx1_l <= box_x1;
                by0_l <= box_y0; by1_l <= box_y1; minpix_l <= min_pix;
            end

            case (state)
            S_IDLE: begin
                dselA <= dbg_addr[1:0];
                dselB <= dbg_addr[1:0];
                if (ft_edge) begin
                    state   <= S_LOAD;
                    cyc_cnt <= 32'd0;
                    in_sel  <= 1'b0;
                    cur     <= 3'd0;      // ★ 新的一帧必须回到第 0 层重跑
                end
            end

            S_LOAD: begin
                if (cyc_cnt >= 32'd1024) state <= S_LCFG;
            end

            S_LCFG: begin
                if      (lcf == `CNN_F_KIND)  kind  <= rom_cfg_data[1:0];
                else if (lcf == `CNN_F_CI)    ci    <= rom_cfg_data[15:0];
                else if (lcf == `CNN_F_CO)    co    <= rom_cfg_data[15:0];
                else if (lcf == `CNN_F_K)     kk    <= rom_cfg_data[15:0];
                else if (lcf == `CNN_F_IH)    ih    <= rom_cfg_data[15:0];
                else if (lcf == `CNN_F_IW)    iw    <= rom_cfg_data[15:0];
                else if (lcf == `CNN_F_OH)    oh    <= rom_cfg_data[15:0];
                else if (lcf == `CNN_F_OW)    ow    <= rom_cfg_data[15:0];
                else if (lcf == `CNN_F_TAPS)  taps  <= rom_cfg_data[15:0];
                else if (lcf == `CNN_F_WBASE) wbase <= rom_cfg_data[15:0];
                else if (lcf == `CNN_F_BBASE) bbase <= rom_cfg_data[15:0];
                else if (lcf == `CNN_F_M)     qm    <= rom_cfg_data[15:0];
                else                         qsh   <= rom_cfg_data[7:0];
                if (lcf == `CNN_CFG_N - 5'd1) begin
                    lcf <= 5'd0;
                    og <= 16'd0; loy <= 16'd0; lopg <= 16'd0;
                    tcnt <= 16'd0; tky <= 16'd0; tkx <= 16'd0; tc <= 16'd0; t_off <= 16'd0;
                    cst <= 2'd0; pph <= 2'd0; pk <= 16'd0;
                    poy <= 16'd0; pox <= 16'd0; ppb <= 16'd0; pob <= 16'd0;
                    gci <= 5'd0; gpair <= 16'd0; gacc <= 24'sd0;
                    fci <= 8'd0;
                    fc_group <= 5'd0;
                    best_l <= -8'sd128;
                    second_l <= -8'sd128;
                    min_l <= 8'sd127;
                    state <= S_LCFG2;
                end
                else lcf <= lcf + 5'd1;
            end

            S_LCFG2: begin
                pad <= kk >> 1;
                pe_m <= qm;
                pe_sh <= qsh;
                pe_relu <= (kind == KIND_CONV);
                w_grp <= wbase;
                pix_base_init <= 32'd0 - ({16'd0, ci} * ({16'd0, iw} + 16'd1) * (kk >> 1));
                pix_base <= 32'd0 - ({16'd0, ci} * ({16'd0, iw} + 16'd1) * (kk >> 1));
                out_pix_base <= 32'd0;
                pix_delta <= {15'd0, ci} << 1;
                out_delta <= {15'd0, co} << 1;
                tky_delta <= (({16'd0, iw} - kk) * ci) + 16'd1;
                pci4 <= ci >> 2;
                prow <= (iw * ci) >> 2;
                // ppb 在 pk 循环里每换一个 4 通道组就 +1（共 pci4-1 次），
                // 所以这里只补足「一个输出像素走过 2 个输入列 = 2*pci4 个字」的余量：
                //   delta = 2*pci4 - (pci4-1) = pci4 + 1
                // 原来写成 ci>>1 = 2*pci4，把组内那步算重了，ppb 每个输出像素多走 1 个字；
                // 密集输入看不出，只有单点输入（cnn_tb 向量 2）才会暴露成「池化全 0」。
                pdelta_ox <= {15'd0, (ci >> 2)} + 16'd1;
                // ★ 这里**不能**用 prow：prow 也是在 S_LCFG2 这一拍非阻塞赋值的，
                //   读到的是上一层的旧值（L0 的 ci=1 时 prow=8），池化行指针因此乱飞
                //   —— 症状是「池化整层扫不到目标」（cnn_tb 向量 2 单点输入时 L1 全 0）。
                //   直接展开 prow 的表达式，保证算出来就是本层的字/行步长。
                pdelta_oy <= ((((iw * ci) >> 2) - (ow * (ci >> 2))) << 1);
                gb <= 32'd0;
                if (kind == KIND_CONV) state <= S_CBIAS;
                else if (kind == KIND_POOL) state <= S_POOLR;
                else if (kind == KIND_GAP) state <= S_GAPR;
                else state <= S_FCB;
            end

            S_CBIAS: begin
                // 每个 og 组要读自己那 8 个通道的权重：w_grp = wbase + og*taps
                rom_b_addr <= bbase[`CNN_B_AW-1:0] + og[`CNN_B_AW-1:0];
                if (cst == 2'd2) begin
                    pe_bias  <= rom_b_data;
                    w_grp    <= (og == 16'd0) ? wbase : (w_grp + taps);
                    cst      <= 2'd0;
                    state    <= S_CTAP;
                end
                else cst <= cst + 2'd1;
            end

            S_CTAP: begin
                rom_w_addr <= (w_grp[`CNN_W_AW-1:0] + tcnt[`CNN_W_AW-1:0]);
                dselA <= in_addr0[1:0];
                dselB <= in_addr1[1:0];
                v0_d  <= c0_ok;
                v1_d  <= c1_ok;
                if (tcnt == 16'd0) begin
                    // ROM/BRAM 和 PE 控制均为一拍延迟；首 tap 先装载地址，
                    // 不要在清累加器这一拍提前推进激活偏移。
                    pe_clr <= 1'b1;
                    state  <= S_CMAC;
                end
                else begin
                    state <= S_CMAC;
                end
            end

            S_CMAC: begin
                pe_mac <= 1'b1;
                if (tcnt == (taps - 16'd1)) begin
                    state <= S_CSTO;
                    cst   <= 2'd0;
                end
                else begin
                    tcnt <= tcnt + 16'd1;
                        if ((tc + 16'd1) >= ci) begin
                            tc <= 16'd0;
                            if ((tkx + 16'd1) >= kk) begin
                                tkx   <= 16'd0;
                                tky   <= tky + 16'd1;
                                t_off <= t_off + tky_delta[15:0];
                            end
                            else begin
                                tkx   <= tkx + 16'd1;
                                t_off <= t_off + 16'd1;
                            end
                        end
                        else begin
                            tc    <= tc + 16'd1;
                            t_off <= t_off + 16'd1;
                        end
                    state <= S_CTAP;
                end
            end

            S_CSTO: begin
                // 4 拍：
                //   cst=0 等最后一个 MAC 落进 acc（本拍 mac_en 还是 1），同时给量化使能
                //   cst=1 量化结果 q_r 在末尾才落定（mac_en=0，共用乘法器算 acc*m）
                //   cst=2/3 把 16 字节写回（两个写口 x 两次）
                // ★ 量化使能必须在本拍就给：q_r 在 cst=1 末尾更新，cst=2 的写回才拿得到
                //   本次结果；晚一拍（到 cst=1 才给）就会把上一对像素的旧值写进去。
                if (cst == 2'd0) begin
                    pe_q <= 1'b1;
                    cst  <= 2'd1;
                end
                else if (cst == 2'd1) cst <= 2'd2;
                else if (cst == 2'd2) cst <= 2'd3;
                else begin
                    cst <= 2'd0;
                    pix_base     <= pix_base + pix_delta;
                    out_pix_base <= out_pix_base + out_delta;
                    // 下一个像素对从第一个 tap 重新开始（t_off 不清零会一路累加下去）
                    tcnt <= 16'd0; tky <= 16'd0; tkx <= 16'd0; tc <= 16'd0; t_off <= 16'd0;
                    if ((lopg + 16'd1) >= pg_lim) begin
                        lopg <= 16'd0;
                        if ((loy + 16'd1) >= oh) begin
                            loy <= 16'd0;
                            if ((og + 16'd1) >= og_lim) begin
                                og <= 16'd0;
                                // 层结束统一走 S_HALT，由 S_LCFG2 按 kind 分派
                                // （fc 也由 kind 驱动进 S_FCB，无需 cur==N-1 特判——
                                // 历史 `cur==3'd7 -> S_FCB` 在 8 层结构是死分支，
                                // 10 层下 L7 conv 结束后若还特判会跳过 L8 gap）
                                cur    <= cur + 4'd1;
                                in_sel <= ~in_sel;
                                state  <= S_HALT;      // 逐层暂停点
                            end
                            else begin
                                // 换 og 组：输入基址/输出基址都要回到原点
                                og           <= og + 16'd1;
                                pix_base     <= pix_base_init;
                                out_pix_base <= 32'd0;
                                state        <= S_CBIAS;
                            end
                        end
                        else begin
                            loy   <= loy + 16'd1;
                            state <= S_CTAP;
                        end
                    end
                    else begin
                        lopg  <= lopg + 16'd1;
                        state <= S_CTAP;
                    end
                end
            end

            S_POOLR: begin
                if (pph == 2'd0) begin
                    pool_a <= in_r1;
                    pool_b <= in_r2;
                    pph   <= 2'd1;
                end
                else begin
                    state  <= S_POOLW;
                end
            end

            S_POOLW: begin
                pph <= 2'd0;
                pob <= pob + 16'd1;                    // 写完 1 个字 = 4 个通道
                if ((pk + 16'd1) >= pci4) begin
                    pk <= 16'd0;                       // 一个输出像素的 4 通道组写完了
                    if ((pox + 16'd1) >= ow) begin
                        pox <= 16'd0;
                        if ((poy + 16'd1) >= oh) begin
                            poy    <= 16'd0;
                            pob    <= 16'd0;
                            cur    <= cur + 4'd1;
                            in_sel <= ~in_sel;
                            state  <= S_HALT;              // 逐层暂停点
                        end
                        else begin
                            poy   <= poy + 16'd1;
                            ppb   <= ppb + pdelta_ox + pdelta_oy;   // 换行
                            state <= S_POOLR;
                        end
                    end
                    else begin
                        pox   <= pox + 16'd1;
                        ppb   <= ppb + pdelta_ox;                   // 下一个输出像素
                        state <= S_POOLR;
                    end
                end
                else begin
                    pk    <= pk + 16'd1;
                    ppb   <= ppb + 16'd1;                           // 下一个 4 通道组
                    state <= S_POOLR;
                end
            end

            S_GAPR: begin
                dselA <= gb[1:0];
                dselB <= gb[1:0] + ci[1:0];
                if (gpair < gn_pair) begin
                    gacc <= gsum;
                    gb <= gb + ({15'd0, ci} << 1);
                    if ((gpair + 16'd1) >= gn_pair) state <= S_GAPW;
                    else gpair <= gpair + 16'd1;
                end
                else state <= S_GAPW;
            end

            S_GAPW: begin
                gap_flat[gci*8 +: 8] <= sat8(gacc >>> `CNN_GAP_SHIFT);
                gacc  <= 24'sd0;
                gpair <= 16'd0;
                gb    <= 32'd1 + {27'd0, gci};
                if ((gci + 16'd1) >= ci) begin
                    gci    <= 8'd0;
                    cur    <= cur + 4'd1;
                    in_sel <= ~in_sel;
                    state  <= S_HALT;                      // 逐层暂停点
                end
                else begin
                    gci   <= gci + 8'd1;
                    state <= S_GAPR;
                end
            end

            S_FCB: begin
                if (cst == 2'd1) begin
                    pe_bias <= {128'd0, rom_fc_bias[fc_group*128 +: 128]};
                    rom_fc_addr <= fc_group * `CNN_FC_IN;
                    cst     <= 2'd2;
                end
                else if (cst == 2'd2) begin
                    pe_clr  <= 1'b1;
                    pe_relu <= 1'b0;
                    pe_m    <= qm;
                    pe_sh   <= qsh;
                    cst     <= 2'd0;
                    state   <= S_FCM;
                end
                else cst <= 2'd1;
            end

            S_FCM: begin
                rom_fc_addr <= fc_group * `CNN_FC_IN + fci;
                pe_w        <= {32'd0, rom_fc_data};
                pe_a        <= {8'd0, gap_flat[fcw_i*8 +: 8]};
                pe_mac      <= 1'b1;
                if (fci >= `CNN_FC_IN) state <= S_FCQ;
                else fci <= fci + 8'd1;
            end

            S_FCQ: begin
                // 最后一个 MAC 本拍才落进 acc，量化要放到下一拍（那一拍 mac_en=0）
                pe_q  <= 1'b1;
                state <= S_FCQ2;
            end

            S_FCQ2: begin
                // q_r 在这一拍末尾才更新，4 个 logit 放到 S_FIN 去抓
                state      <= S_FIN;
            end

            S_FIN: begin
                logit_flat[fc_base*8 +: 32] <= {lg3, lg2, lg1, lg0};
                best_l <= best_c;
                second_l <= second_c;
                min_l <= min_c;
                am_l <= best_idx_c;
                if ((fc_group + 5'd1) >= `CNN_FC_GROUPS) begin
                    if ((best_c - min_c) == 8'sd0) begin
                        conf_l <= 32'd0;
                        state <= S_OUT;
                    end
                    else begin
                        div_a <= {24'd0, (best_c - second_c)} * 32'd1000;
                        div_b <= {24'd0, (best_c - min_c)} + 32'd1;
                        div_start <= 1'b1;
                        state <= S_DIV;
                    end
                end
                else begin
                    fc_group <= fc_group + 5'd1;
                    fci <= 8'd0;
                    cst <= 2'd0;
                    state <= S_FCB;
                end
            end

            S_DIV: begin
                if (div_dn) begin
                    conf_l <= (div_q > 32'd1000) ? 32'd1000 : div_q;
                    state  <= S_OUT;
                end
            end

            S_OUT: begin
                cls    <= ((`CNN_NONE_CLASS >= 0 && am_l == `CNN_NONE_CLASS) ||
                           (fg_l < minpix_l)) ? 32'd255 : {25'd0, am_l};
                valid  <= !((`CNN_NONE_CLASS >= 0 && am_l == `CNN_NONE_CLASS)) &&
                          (fg_l >= minpix_l);
                score  <= conf_l;
                obj_w  <= (bx1_l >= bx0_l) ? (bx1_l - bx0_l + 32'd1) : 32'd0;
                obj_h  <= (by1_l >= by0_l) ? (by1_l - by0_l + 32'd1) : 32'd0;
                cycles <= cyc_cnt;
                done   <= 1'b1;
                state  <= S_IDLE;
            end

            S_HALT: begin
                // 层边界暂停点：cur/in_sel 已经推进到「下一层」，刚算完的那一层
                // 就在它的输出缓冲里（层号偶数 -> memB，奇数 -> memA）。
                // dbg_halt=0 时只多花 1 拍穿过，且不计入 cyc_cnt，不影响 cycles 与结果。
                dselA <= dbg_addr[1:0];
                dselB <= dbg_addr[1:0];
                if (dbg_halt) dbg_at_halt <= 1'b1;
                else begin
                    dbg_at_halt <= 1'b0;
                    state       <= S_LCFG;
                end
            end

            default: state <= S_IDLE;
            endcase
        end
    end

    //==================================================================
    // 调试读口
    //==================================================================
    wire signed [7:0] dbg_gap = gap_flat[dbg_addr[7:0]*8 +: 8];   // 8 位地址：gap 通道可达 255（wider3 144 通道）
    wire signed [7:0] dbg_lgt = logit_flat[dbg_addr[7:0]*8 +: 8];
    // 用连续赋值而不是 always @(*)：always @(*) 读存储阵列会触发 iverilog 的
    // 「敏感于阵列全部字」告警（本工程要求 -Wall 零告警）。
    // 连续赋值语义等价：都是组合逻辑，随地址/选择变化立即更新。
    wire [7:0] dbg_mem = (dbg_sel == 2'd0)
                       ? (memA[dbg_addr[AW+1:2]] >> {dbg_addr[1:0], 3'b000})
                       : (memB[dbg_addr[BW+1:2]] >> {dbg_addr[1:0], 3'b000});
    assign dbg_data = (dbg_sel == 2'd2) ? dbg_gap
                    : (dbg_sel == 2'd3) ? dbg_lgt
                    : dbg_mem;

    assign pix_rd_addr = cyc_cnt[9:0];
endmodule
