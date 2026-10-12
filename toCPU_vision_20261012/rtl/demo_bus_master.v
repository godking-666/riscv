//======================================================================
// demo_bus_master.v -- 【CPU 替代件】纯硬件总线主控（仅演示/兜底用）
//
// 真正的 RISC-V CPU 由另一组设计。在它就绪之前，用这个模块扮演 CPU：
//   * 按 MMIO 时序写配置寄存器（ROI / 阈值 / 门限）
//   * 写 CTRL 提交配置、软复位、使能
//   * 读 STATUS 等「相机配置完成」（b4）/ 等「本帧结果就绪」（b1）
//   * 读回 CLASS / SCORE / BOX_* / FRAME_* 等结果
//   * 触发 vision_report 发一行文本给 RK3568
//   * 相机看门狗：连续若干次等不到结果就写 CTRL.CAM_RESTART 重配相机
//
// 它的行为与 sw/main.c 一一对应（配置顺序、轮询方式、结果字段完全相同），
// 所以「硬件主控能跑通」等价于「将来 CPU + 固件能跑通」，反之亦然。
//
// ★ 等真 CPU 接上以后，这个模块整块删掉，视觉子系统其余部分一行都不用改。★
//
// 总线时序（与工程既有 inst_rom / data_ram 一致）：
//   写：bus_sel && bus_we 当拍提交
//   读：当拍给地址，下一拍 bus_rdata 有效
//
// 注意：这里刻意「只用总线」拿状态（不引 vision_top 内部信号），
//       这样 STATUS 的每一位都被真实地验证了一遍。
//======================================================================
`timescale 1ns / 1ps

module demo_bus_master #(
    // ---- 上电配置（现场标定时改这里，或由 CPU 侧软件改）----
    parameter [31:0] CFG_ROI_X      = 32'd0,
    parameter [31:0] CFG_ROI_Y      = 32'd0,
    parameter [31:0] CFG_ROI_W      = 32'd320,
    parameter [31:0] CFG_ROI_H      = 32'd240,
    parameter [31:0] CFG_THRESH     = 32'd128,   // bit8 = 极性
    parameter [31:0] CFG_MIN_PIX    = 32'd64,
    parameter [31:0] CFG_AREA_C_MAX = 32'd500,

    parameter [31:0] BASE           = 32'h8000_0000,
    parameter [31:0] POLL_TIMEOUT   = 32'd20000000,  // 轮询等待上限（clk 周期）
    parameter [ 3:0] NOFRAME_LIMIT  = 4'd3           // 连续超时几次就重启相机
)(
    input  wire        clk,
    input  wire        rstn,

    // ---- MMIO 主端 ----
    output reg         bus_sel,
    output reg         bus_we,
    output reg  [31:0] bus_addr,
    output reg  [31:0] bus_wdata,
    output reg  [ 3:0] bus_be,
    input  wire [31:0] bus_rdata,

    // ---- 触发串口上报 ----
    output reg         rep_start,
    input  wire        rep_done,

    // ---- 结果（给 report / ILA 用）----
    output reg  [31:0] o_frame_no,
    output reg  [31:0] o_cls,
    output reg  [31:0] o_x0,
    output reg  [31:0] o_y0,
    output reg  [31:0] o_x1,
    output reg  [31:0] o_y1,
    output reg  [31:0] o_score,
    output reg  [31:0] o_frame_cyc,
    output reg  [31:0] o_item_cnt,

    output reg         o_stale,      // 本轮没等到新结果（超时），结果可能是旧的
    output reg         o_cam_err,    // 相机 SCCB 配置出现过 NACK
    output reg  [31:0] o_noframe     // 累计「等不到结果」次数，调试用
);
    // ---- 寄存器偏移（与 sw/vision_regs.h 保持一致）----
    localparam [11:0] A_CTRL      = 12'h008;
    localparam [11:0] A_STATUS    = 12'h00C;
    localparam [11:0] A_IRQ_CLR   = 12'h010;
    localparam [11:0] A_FRAME_CNT = 12'h014;
    localparam [11:0] A_ITEM_CNT  = 12'h018;
    localparam [11:0] A_FRAME_CYC = 12'h01C;
    localparam [11:0] A_ROI_X     = 12'h020;
    localparam [11:0] A_ROI_Y     = 12'h024;
    localparam [11:0] A_ROI_W     = 12'h028;
    localparam [11:0] A_ROI_H     = 12'h02C;
    localparam [11:0] A_THRESH    = 12'h030;
    localparam [11:0] A_MIN_PIX   = 12'h034;
    localparam [11:0] A_AREA_C_MAX= 12'h038;
    localparam [11:0] A_CLASS     = 12'h03C;
    localparam [11:0] A_SCORE     = 12'h040;
    localparam [11:0] A_BOX_X0    = 12'h044;
    localparam [11:0] A_BOX_Y0    = 12'h048;
    localparam [11:0] A_BOX_X1    = 12'h04C;
    localparam [11:0] A_BOX_Y1    = 12'h050;

    localparam [31:0] CTRL_EN          = 32'h0000_0001;
    localparam [31:0] CTRL_SOFT_RST    = 32'h0000_0002;
    localparam [31:0] CTRL_CFG_COMMIT  = 32'h0000_0008;
    localparam [31:0] CTRL_CAM_RESTART = 32'h0000_0010;

    // ---- 写表：上电初始化要写的寄存器序列 ----
    localparam WR_N = 4'd10;

    reg [11:0] wr_off;
    reg [31:0] wr_dat;
    always @(*) begin
        case (wi)
            4'd0: begin wr_off = A_ROI_X;      wr_dat = CFG_ROI_X;      end
            4'd1: begin wr_off = A_ROI_Y;      wr_dat = CFG_ROI_Y;      end
            4'd2: begin wr_off = A_ROI_W;      wr_dat = CFG_ROI_W;      end
            4'd3: begin wr_off = A_ROI_H;      wr_dat = CFG_ROI_H;      end
            4'd4: begin wr_off = A_MIN_PIX;    wr_dat = CFG_MIN_PIX;    end
            4'd5: begin wr_off = A_AREA_C_MAX; wr_dat = CFG_AREA_C_MAX; end
            4'd6: begin wr_off = A_THRESH;     wr_dat = CFG_THRESH;     end
            4'd7: begin wr_off = A_CTRL;       wr_dat = CTRL_CFG_COMMIT; end
            4'd8: begin wr_off = A_CTRL;       wr_dat = CTRL_SOFT_RST;  end
            default: begin wr_off = A_CTRL;    wr_dat = CTRL_EN;        end
        endcase
    end

    // ---- 读表：每帧要读回的结果寄存器 ----
    localparam RD_N = 4'd9;
    function [11:0] rd_off;
        input [3:0] i;
        begin
            case (i)
                4'd0: rd_off = A_FRAME_CNT;
                4'd1: rd_off = A_CLASS;
                4'd2: rd_off = A_BOX_X0;
                4'd3: rd_off = A_BOX_Y0;
                4'd4: rd_off = A_BOX_X1;
                4'd5: rd_off = A_BOX_Y1;
                4'd6: rd_off = A_SCORE;
                4'd7: rd_off = A_FRAME_CYC;
                default: rd_off = A_ITEM_CNT;
            endcase
        end
    endfunction

    // ---- 状态 ----
    // ★ 读时序：从端 bus_rdata 是寄存输出，地址打出去以后要再等一拍才有效，
    //   所以一次读占三拍：_X 给地址 / _W 收片选（此时从端已把数据锁进 rdata）/ _L 取值。
    //   少一拍的后果是「读到上一个寄存器的值」，整行字段会整体错位一格。
    localparam B_BOOT       = 5'd0;
    localparam B_CFG_LO     = 5'd1;    // 读 STATUS，等 cam_cfg_done 先变低（重启后要重新等）
    localparam B_CFG_LO_W   = 5'd2;
    localparam B_CFG_LO_L   = 5'd3;
    localparam B_CFG_WAIT   = 5'd4;    // 读 STATUS，等 cam_cfg_done 变高
    localparam B_CFG_WAIT_W = 5'd5;
    localparam B_CFG_WAIT_L = 5'd6;
    localparam B_WR         = 5'd7;
    localparam B_WR_W       = 5'd8;
    localparam B_CLR        = 5'd9;
    localparam B_POLL       = 5'd10;
    localparam B_POLL_W     = 5'd11;
    localparam B_POLL_L     = 5'd12;
    localparam B_RD         = 5'd13;
    localparam B_RD_W       = 5'd14;
    localparam B_RD_L       = 5'd15;
    localparam B_REP_P      = 5'd16;
    localparam B_REP        = 5'd17;
    localparam B_CAMRST     = 5'd18;
    localparam B_CAMRST_W   = 5'd19;

    reg [4:0]  st;
    reg [3:0]  wi, ri;
    reg [31:0] tmo;
    reg [3:0]  noframe;

    always @(posedge clk) begin
        if (!rstn) begin
            st         <= B_BOOT;
            wi         <= 4'd0;
            ri         <= 4'd0;
            tmo        <= 32'd0;
            noframe    <= 4'd0;
            bus_sel    <= 1'b0;
            bus_we     <= 1'b0;
            bus_addr   <= 32'd0;
            bus_wdata  <= 32'd0;
            bus_be     <= 4'hF;
            rep_start  <= 1'b0;
            o_frame_no <= 32'd0;
            o_cls      <= 32'd255;
            o_x0       <= 32'd0;
            o_y0       <= 32'd0;
            o_x1       <= 32'd0;
            o_y1       <= 32'd0;
            o_score    <= 32'd0;
            o_frame_cyc<= 32'd0;
            o_item_cnt <= 32'd0;
            o_stale    <= 1'b0;
            o_cam_err  <= 1'b0;
            o_noframe  <= 32'd0;
        end
        else begin
            rep_start <= 1'b0;

            case (st)
                B_BOOT: begin
                    bus_sel <= 1'b0;
                    bus_we  <= 1'b0;
                    wi      <= 4'd0;
                    ri      <= 4'd0;
                    tmo     <= 32'd0;
                    st      <= B_CFG_LO;
                end

                // 相机重启后 cam_cfg_done 会先变低；上电时本来就是低，直接过
                B_CFG_LO: begin
                    bus_sel  <= 1'b1;
                    bus_we   <= 1'b0;
                    bus_addr <= BASE | {20'd0, A_STATUS};
                    st       <= B_CFG_LO_W;
                end

                B_CFG_LO_W: begin
                    bus_sel <= 1'b0;
                    st      <= B_CFG_LO_L;
                end

                B_CFG_LO_L: begin
                    o_cam_err <= bus_rdata[5];
                    if (!bus_rdata[4]) begin
                        tmo <= 32'd0;
                        st  <= B_CFG_WAIT;
                    end
                    else if (tmo >= POLL_TIMEOUT) begin
                        tmo <= 32'd0;
                        st  <= B_CFG_WAIT;
                    end
                    else begin
                        tmo <= tmo + 32'd1;
                        st  <= B_CFG_LO;
                    end
                end

                // 等相机配置表下发完成。相机不在位时靠超时兜底，不能让整机卡死
                B_CFG_WAIT: begin
                    bus_sel  <= 1'b1;
                    bus_we   <= 1'b0;
                    bus_addr <= BASE | {20'd0, A_STATUS};
                    st       <= B_CFG_WAIT_W;
                end

                B_CFG_WAIT_W: begin
                    bus_sel <= 1'b0;
                    st      <= B_CFG_WAIT_L;
                end

                B_CFG_WAIT_L: begin
                    o_cam_err <= bus_rdata[5];
                    if (bus_rdata[4]) begin
                        wi  <= 4'd0;
                        tmo <= 32'd0;
                        st  <= B_WR;
                    end
                    else if (tmo >= POLL_TIMEOUT) begin
                        wi  <= 4'd0;
                        tmo <= 32'd0;
                        st  <= B_WR;      // 相机没配上也继续跑，结果会是「无物品」
                    end
                    else begin
                        tmo <= tmo + 32'd1;
                        st  <= B_CFG_WAIT;
                    end
                end

                B_WR: begin
                    bus_sel   <= 1'b1;
                    bus_we    <= 1'b1;
                    bus_addr  <= BASE | {20'd0, wr_off};
                    bus_wdata <= wr_dat;
                    bus_be    <= 4'hF;
                    st        <= B_WR_W;
                end

                B_WR_W: begin
                    bus_sel <= 1'b0;
                    bus_we  <= 1'b0;
                    if (wi == (WR_N - 4'd1)) begin
                        wi <= 4'd0;
                        st <= B_CLR;
                    end
                    else begin
                        wi <= wi + 4'd1;
                        st <= B_WR;
                    end
                end

                // 清 DONE，为这一帧做准备
                B_CLR: begin
                    bus_sel   <= 1'b1;
                    bus_we    <= 1'b1;
                    bus_addr  <= BASE | {20'd0, A_IRQ_CLR};
                    bus_wdata <= 32'd1;
                    bus_be    <= 4'hF;
                    tmo       <= 32'd0;
                    st        <= B_POLL;
                end

                B_POLL: begin
                    bus_sel  <= 1'b1;
                    bus_we   <= 1'b0;
                    bus_addr <= BASE | {20'd0, A_STATUS};
                    st       <= B_POLL_W;
                end

                B_POLL_W: begin
                    bus_sel <= 1'b0;
                    st      <= B_POLL_L;
                end

                B_POLL_L: begin
                    o_cam_err <= bus_rdata[5];
                    if (bus_rdata[1]) begin            // STATUS.DONE
                        o_stale  <= 1'b0;
                        noframe  <= 4'd0;
                        ri       <= 4'd0;
                        st       <= B_RD;
                    end
                    else if (tmo >= POLL_TIMEOUT) begin
                        // 超时：可能是相机掉线。先按旧值报一行（标 stale）并计数
                        o_stale   <= 1'b1;
                        o_noframe <= o_noframe + 32'd1;
                        if (noframe >= NOFRAME_LIMIT) begin
                            noframe <= 4'd0;
                            st      <= B_CAMRST;
                        end
                        else begin
                            noframe <= noframe + 4'd1;
                            st      <= B_CLR;
                        end
                    end
                    else begin
                        tmo <= tmo + 32'd1;
                        st  <= B_POLL;
                    end
                end

                B_RD: begin
                    bus_sel  <= 1'b1;
                    bus_we   <= 1'b0;
                    bus_addr <= BASE | {20'd0, rd_off(ri)};
                    st       <= B_RD_W;
                end

                B_RD_W: begin
                    bus_sel <= 1'b0;
                    st      <= B_RD_L;
                end

                B_RD_L: begin
                    case (ri)
                        4'd0: o_frame_no  <= bus_rdata;
                        4'd1: o_cls       <= bus_rdata;
                        4'd2: o_x0        <= bus_rdata;
                        4'd3: o_y0        <= bus_rdata;
                        4'd4: o_x1        <= bus_rdata;
                        4'd5: o_y1        <= bus_rdata;
                        4'd6: o_score     <= bus_rdata;
                        4'd7: o_frame_cyc <= bus_rdata;
                        default: o_item_cnt <= bus_rdata;
                    endcase
                    if (ri == (RD_N - 4'd1)) begin
                        rep_start <= 1'b1;             // 1 拍脉冲
                        st        <= B_REP_P;
                    end
                    else begin
                        ri <= ri + 4'd1;
                        st <= B_RD;
                    end
                end

                // 立刻收掉 rep_start，保证它是严格 1 拍，避免 report 重复启动
                B_REP_P: begin
                    rep_start <= 1'b0;
                    st        <= B_REP;
                end

                B_REP: begin
                    if (rep_done) st <= B_CLR;
                end

                B_CAMRST: begin
                    bus_sel   <= 1'b1;
                    bus_we    <= 1'b1;
                    bus_addr  <= BASE | {20'd0, A_CTRL};
                    bus_wdata <= CTRL_CAM_RESTART;
                    bus_be    <= 4'hF;
                    st        <= B_CAMRST_W;
                end

                B_CAMRST_W: begin
                    bus_sel <= 1'b0;
                    bus_we  <= 1'b0;
                    st      <= B_CFG_LO;
                end

                default: st <= B_BOOT;
            endcase
        end
    end
endmodule