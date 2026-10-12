//======================================================================
// vision_regs.v -- 视觉子系统 MMIO 寄存器从端（CPU 时钟域）
//
// 总线风格与工程既有 inst_rom / data_ram 保持一致：
//   * 写：bus_sel && bus_we 当拍提交，支持字节使能
//   * 读：bus_rdata 寄存输出，1 拍延迟
//   * 从端不插入等待周期（不给 CPU 引入 wait state）
//
// 片内偏移 = bus_addr[11:0]；基址由 CPU 侧地址译码剥离后给出 bus_sel。
//
// 【必须与 CPU 组约定的两条】
//   1) 本段地址必须配置为「不可缓存」。否则读 STATUS 会读到 D-Cache 里的旧值、
//      写 CTRL 可能被写缓冲吃掉而不下发。
//   2) 本段写在 CPU 侧必须是「直通/有序」的，或者在 CTRL 写之前提供写屏障。
//      否则软件写 ROI 与写 CTRL 的先后关系无保证。
//
// 跨时钟域：cam 域结果用「翻转握手」接收 —— roi_stats 在帧起始翻转 res_toggle，
// 本模块把 toggle 打两拍后取边沿，此时 res_* 已经稳定远超两拍，可以安全锁存。
//======================================================================
`timescale 1ns / 1ps

module vision_regs (
    input  wire        clk,
    input  wire        rstn,

    // ---- MMIO 从端 ----
    input  wire        bus_sel,
    input  wire        bus_we,
    input  wire [31:0] bus_addr,
    input  wire [31:0] bus_wdata,
    input  wire [3:0]  bus_be,
    output reg  [31:0] bus_rdata,

    output wire        irq,

    // ---- 相机配置状态（来自 ov5640_cam_ctrl）----
    input  wire        cam_cfg_done,
    input  wire        cam_cfg_err,
    output reg         cam_restart,

    // ---- 配置输出到 cam 域 ----
    output wire [15:0] cfg_roi_x,
    output wire [15:0] cfg_roi_y,
    output wire [15:0] cfg_roi_w,
    output wire [15:0] cfg_roi_h,
    output wire [7:0]  cfg_thresh,
    output wire        cfg_pol,
    output reg         cfg_toggle,
    output wire        enable,

    // ---- 分类器参数 ----
    output wire [31:0] roi_w,
    output wire [31:0] roi_h,
    output wire [31:0] min_pix,
    output wire [31:0] area_c_max,

    // ---- 来自 cam 域的结果 ----
    input  wire [31:0] res_frame_cnt,
    input  wire [31:0] res_fg_cnt,
    input  wire [15:0] res_box_x0,
    input  wire [15:0] res_box_y0,
    input  wire [15:0] res_box_x1,
    input  wire [15:0] res_box_y1,
    input  wire [31:0] res_cycles,
    input  wire        res_toggle,

    // ---- 给分类器的帧事件与数据 ----
    output reg  [31:0] lat_frame_cnt,
    output reg  [31:0] lat_fg_cnt,
    output reg  [31:0] lat_box_x0,
    output reg  [31:0] lat_box_y0,
    output reg  [31:0] lat_box_x1,
    output reg  [31:0] lat_box_y1,
    output reg  [31:0] lat_cycles,
    output reg         frame_new,

    // ---- 分类结果 ----
    input  wire [31:0] cls_i,
    input  wire [31:0] score_i,
    input  wire [31:0] obj_w_i,
    input  wire [31:0] obj_h_i,
    input  wire        cls_valid_i,
    input  wire        cls_done_i
);

    // ---- 寄存器偏移 ----
    localparam A_ID         = 12'h000;
    localparam A_VERSION    = 12'h004;
    localparam A_CTRL       = 12'h008;
    localparam A_STATUS     = 12'h00C;
    localparam A_IRQ_CLR    = 12'h010;
    localparam A_FRAME_CNT  = 12'h014;
    localparam A_ITEM_CNT   = 12'h018;
    localparam A_FRAME_CYC  = 12'h01C;
    localparam A_ROI_X      = 12'h020;
    localparam A_ROI_Y      = 12'h024;
    localparam A_ROI_W      = 12'h028;
    localparam A_ROI_H      = 12'h02C;
    localparam A_THRESH     = 12'h030;
    localparam A_MIN_PIX    = 12'h034;
    localparam A_AREA_C_MAX = 12'h038;
    localparam A_CLASS      = 12'h03C;
    localparam A_SCORE      = 12'h040;
    localparam A_BOX_X0     = 12'h044;
    localparam A_BOX_Y0     = 12'h048;
    localparam A_BOX_X1     = 12'h04C;
    localparam A_BOX_Y1     = 12'h050;
    localparam A_FG_CNT     = 12'h054;
    localparam A_OBJ_W      = 12'h058;
    localparam A_OBJ_H      = 12'h05C;

    localparam ID_VALUE     = 32'h5649_5331;   // "VIS1"

    wire        wr  = bus_sel & bus_we;
    wire [11:0] off = bus_addr[11:0];

    // ---- 可写寄存器 ----
    reg        ctrl_enable;
    reg        ctrl_irq_en;
    reg [31:0] roi_x, roi_y, roi_w_r, roi_h_r;
    reg [7:0]  thresh;
    reg        pol;
    reg [31:0] min_pix_r, area_c_max_r;

    // ---- 只读状态 ----
    reg [31:0] item_cnt;
    reg [31:0] cls_lat, score_lat, obj_w_lat, obj_h_lat;
    reg        valid_lat;
    reg        done_flag;
    reg        cam_ok;
    reg        err_flag;
    reg        obj_prev;

    // ---- res_toggle 同步 ----
    reg rt_d, rt_dd;
    always @(posedge clk) begin
        if (!rstn) begin
            rt_d  <= 1'b0;
            rt_dd <= 1'b0;
        end
        else begin
            rt_d  <= res_toggle;
            rt_dd <= rt_d;
        end
    end
    wire res_edge = rt_d ^ rt_dd;

    // ---- 寄存器写 + 结果接收 ----
    always @(posedge clk) begin
        if (!rstn) begin
            ctrl_enable   <= 1'b0;
            ctrl_irq_en   <= 1'b0;
            cfg_toggle    <= 1'b0;
            roi_x         <= 32'd0;
            roi_y         <= 32'd0;
            roi_w_r       <= 32'd320;
            roi_h_r       <= 32'd240;
            thresh        <= 8'd128;
            pol           <= 1'b0;
            min_pix_r     <= 32'd64;
            area_c_max_r  <= 32'd500;
            item_cnt      <= 32'd0;
            cls_lat       <= 32'd255;
            score_lat     <= 32'd0;
            obj_w_lat     <= 32'd0;
            obj_h_lat     <= 32'd0;
            valid_lat     <= 1'b0;
            done_flag     <= 1'b0;
            cam_ok        <= 1'b0;
            cam_restart   <= 1'b0;
            err_flag      <= 1'b0;
            obj_prev      <= 1'b0;
            lat_frame_cnt <= 32'd0;
            lat_fg_cnt    <= 32'd0;
            lat_box_x0    <= 32'd0;
            lat_box_y0    <= 32'd0;
            lat_box_x1    <= 32'd0;
            lat_box_y1    <= 32'd0;
            lat_cycles    <= 32'd0;
            frame_new     <= 1'b0;
        end
        else begin
            frame_new   <= 1'b0;
            cam_restart <= 1'b0;

            // ---------- 写 ----------
            if (wr) begin
                case (off)
                    A_CTRL: begin
                        ctrl_enable <= bus_wdata[0];
                        ctrl_irq_en <= bus_wdata[2];
                        // bit3 CFG_COMMIT：把 ROI/阈值配置一次性推给 cam 域（自清）
                        if (bus_wdata[3]) cfg_toggle <= ~cfg_toggle;
                        // bit4 CAM_RESTART：重跑上电时序 + SCCB 配置（自清）
                        if (bus_wdata[4]) cam_restart <= 1'b1;
                        // bit1 SOFT_RESET：清计数与状态，自清
                        if (bus_wdata[1]) begin
                            item_cnt  <= 32'd0;
                            done_flag <= 1'b0;
                            err_flag  <= 1'b0;
                            obj_prev  <= 1'b0;
                        end
                    end
                    A_IRQ_CLR:    done_flag    <= 1'b0;
                    A_ROI_X:      roi_x        <= bus_wdata;
                    A_ROI_Y:      roi_y        <= bus_wdata;
                    A_ROI_W:      roi_w_r      <= bus_wdata;
                    A_ROI_H:      roi_h_r      <= bus_wdata;
                    A_THRESH: begin
                        thresh <= bus_wdata[7:0];
                        pol    <= bus_wdata[8];
                    end
                    A_MIN_PIX:    min_pix_r    <= bus_wdata;
                    A_AREA_C_MAX: area_c_max_r <= bus_wdata;
                    default: ; // 只读或未定义地址：忽略写
                endcase
            end

            // ---------- cam 域结果接收 ----------
            if (res_edge) begin
                cam_ok <= 1'b1;
                if (ctrl_enable) begin
                    lat_frame_cnt <= res_frame_cnt;
                    lat_fg_cnt    <= res_fg_cnt;
                    lat_box_x0    <= {16'd0, res_box_x0};
                    lat_box_y0    <= {16'd0, res_box_y0};
                    lat_box_x1    <= {16'd0, res_box_x1};
                    lat_box_y1    <= {16'd0, res_box_y1};
                    lat_cycles    <= res_cycles;
                    frame_new     <= 1'b1;
                    if ((roi_w_r == 32'd0) || (roi_h_r == 32'd0)) err_flag <= 1'b1;
                end
            end

            // ---------- 分类结果 ----------
            if (cls_done_i) begin
                cls_lat   <= cls_i;
                score_lat <= score_i;
                obj_w_lat <= obj_w_i;
                obj_h_lat <= obj_h_i;
                valid_lat <= cls_valid_i;
                done_flag <= 1'b1;
                if (cls_valid_i && !obj_prev) item_cnt <= item_cnt + 32'd1;
                obj_prev <= cls_valid_i;
            end
        end
    end

    // ---- 读（寄存输出，1 拍延迟）----
    always @(posedge clk) begin
        if (!rstn) bus_rdata <= 32'd0;
        else if (bus_sel && !bus_we) begin
            case (off)
                A_ID:         bus_rdata <= ID_VALUE;
                A_VERSION:    bus_rdata <= 32'h0001_0000;
                A_CTRL:       bus_rdata <= {28'd0, 1'b0, ctrl_irq_en, 1'b0, ctrl_enable};
                A_STATUS:     bus_rdata <= {26'd0, cam_cfg_err, cam_cfg_done, cam_ok,
                                            err_flag, done_flag, ctrl_enable};
                A_IRQ_CLR:    bus_rdata <= 32'd0;
                A_FRAME_CNT:  bus_rdata <= lat_frame_cnt;
                A_ITEM_CNT:   bus_rdata <= item_cnt;
                A_FRAME_CYC:  bus_rdata <= lat_cycles;
                A_ROI_X:      bus_rdata <= roi_x;
                A_ROI_Y:      bus_rdata <= roi_y;
                A_ROI_W:      bus_rdata <= roi_w_r;
                A_ROI_H:      bus_rdata <= roi_h_r;
                A_THRESH:     bus_rdata <= {23'd0, pol, thresh};
                A_MIN_PIX:    bus_rdata <= min_pix_r;
                A_AREA_C_MAX: bus_rdata <= area_c_max_r;
                A_CLASS:      bus_rdata <= valid_lat ? cls_lat : 32'd255;
                A_SCORE:      bus_rdata <= score_lat;
                A_BOX_X0:     bus_rdata <= lat_box_x0;
                A_BOX_Y0:     bus_rdata <= lat_box_y0;
                A_BOX_X1:     bus_rdata <= lat_box_x1;
                A_BOX_Y1:     bus_rdata <= lat_box_y1;
                A_FG_CNT:     bus_rdata <= lat_fg_cnt;
                A_OBJ_W:      bus_rdata <= obj_w_lat;
                A_OBJ_H:      bus_rdata <= obj_h_lat;
                default:      bus_rdata <= 32'hDEAD_BEEF;
            endcase
        end
    end

    assign cfg_roi_x = roi_x[15:0];
    assign cfg_roi_y = roi_y[15:0];
    assign cfg_roi_w = roi_w_r[15:0];
    assign cfg_roi_h = roi_h_r[15:0];
    assign cfg_thresh = thresh;
    assign cfg_pol   = pol;
    assign enable    = ctrl_enable;

    assign roi_w      = roi_w_r;
    assign roi_h      = roi_h_r;
    assign min_pix    = min_pix_r;
    assign area_c_max = area_c_max_r;

    assign irq = ctrl_irq_en & done_flag;
endmodule