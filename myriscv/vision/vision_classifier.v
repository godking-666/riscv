//======================================================================
// vision_classifier.v -- 物品三分类（CPU 时钟域）
//
// ★ 这个模块就是日后「AI 加速器」的插入位置 ★
//   接口保持不变（frame_new 进、cls/score/obj_w/obj_h 出），
//   内部从「阈值+形状特征」换成定点 CNN 即可，上层软件与寄存器表不动。
//
// 当前 v1 规则（整数比较，无乘法除法除了 SCORE 的千分比）：
//   fg < MIN_PIX            -> 无物品，valid=0
//   fg < AREA_C_MAX         -> 类别 C（小件）
//   h  >= 2*w               -> 类别 B（细长）
//   否则                     -> 类别 A（大块）
//
// SCORE = 前景像素数 / ROI 面积 × 1000（千分比），用顺序除法器算，每帧一次。
//======================================================================
`timescale 1ns / 1ps

module vision_classifier (
    input  wire        clk,
    input  wire        rstn,

    input  wire        frame_new,     // 1 拍脉冲：有新的一帧统计结果
    input  wire [31:0] fg_cnt,
    input  wire [31:0] box_x0,
    input  wire [31:0] box_y0,
    input  wire [31:0] box_x1,
    input  wire [31:0] box_y1,

    input  wire [31:0] roi_w,
    input  wire [31:0] roi_h,
    input  wire [31:0] min_pix,
    input  wire [31:0] area_c_max,

    output reg  [31:0] cls,           // 0=A 1=B 2=C 0xFF=无物品
    output reg  [31:0] score,
    output reg  [31:0] obj_w,
    output reg  [31:0] obj_h,
    output reg         valid,
    output reg         done           // 1 拍脉冲：本轮分类完成
);

    localparam CLS_A   = 32'd0;
    localparam CLS_B   = 32'd1;
    localparam CLS_C   = 32'd2;
    localparam CLS_NON = 32'd255;

    localparam S_IDLE = 2'd0;
    localparam S_DIV  = 2'd1;

    reg [1:0]  state;
    reg [31:0] fg_l, w_l, h_l;

    reg        div_start;
    reg [31:0] div_dividend, div_divisor;
    wire [31:0] div_quotient;
    wire        div_busy, div_done;

    div_u32_seq u_div (
        .clk      (clk),
        .rstn     (rstn),
        .start    (div_start),
        .dividend (div_dividend),
        .divisor  (div_divisor),
        .quotient (div_quotient),
        .busy     (div_busy),
        .done     (div_done)
    );

    // 外接矩形尺寸（+1 才是像素个数；无前景时 box 是哨兵值，这里用 fg 判定）
    wire [31:0] w_calc = (box_x1 >= box_x0) ? (box_x1 - box_x0 + 32'd1) : 32'd0;
    wire [31:0] h_calc = (box_y1 >= box_y0) ? (box_y1 - box_y0 + 32'd1) : 32'd0;

    // 占用率得分：千分比，上限 1000。组合逻辑（PDS ADS 编译器不允许混用阻塞/非阻塞赋值）
    wire [31:0] score_calc = (div_quotient > 32'd1000) ? 32'd1000 : div_quotient;

    always @(posedge clk) begin
        if (!rstn) begin
            state        <= S_IDLE;
            div_start    <= 1'b0;
            div_dividend <= 32'd0;
            div_divisor  <= 32'd0;
            fg_l         <= 32'd0;
            w_l          <= 32'd0;
            h_l          <= 32'd0;
            cls          <= CLS_NON;
            score        <= 32'd0;
            obj_w        <= 32'd0;
            obj_h        <= 32'd0;
            valid        <= 1'b0;
            done         <= 1'b0;
        end
        else begin
            done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (frame_new) begin
                        fg_l         <= fg_cnt;
                        w_l          <= w_calc;
                        h_l          <= h_calc;
                        div_dividend <= fg_cnt * 32'd1000;
                        div_divisor  <= roi_w * roi_h;
                        div_start    <= 1'b1;
                        state        <= S_DIV;
                    end
                end

                S_DIV: begin
                    div_start <= 1'b0;
                    if (div_done) begin
                        // ---- SCORE（score_calc 为组合逻辑，见声明处）----
                        score      <= score_calc;

                        // ---- 分类 ----
                        obj_w <= w_l;
                        obj_h <= h_l;
                        if (fg_l < min_pix) begin
                            cls   <= CLS_NON;
                            valid <= 1'b0;
                        end
                        else if (fg_l < area_c_max) begin
                            cls   <= CLS_C;
                            valid <= 1'b1;
                        end
                        else if (h_l >= (w_l << 1)) begin
                            cls   <= CLS_B;
                            valid <= 1'b1;
                        end
                        else begin
                            cls   <= CLS_A;
                            valid <= 1'b1;
                        end

                        done  <= 1'b1;
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule