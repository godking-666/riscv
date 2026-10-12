`timescale 1ns / 1ps

// 通用 GPIO 外设（SRAM-like MMIO，风格与 uart_mmio / simple_mmio 一致）。
//
// 赛题依据：《2026 FPGA 赛道选题指南-紫光同创》选题一 基础任务 3
//   "外设系统集成：集成基础外设（如 UART 控制器、GPIO 等）用于系统控制与结果输出"
//   此前工程只有 UART，LED 由 soc_ddr3_leds 硬件直接驱动、CPU 不可编程 —— 本模块补此缺口。
//
// 地址窗口：GPIO_BASE 起 32 字节（地址用 [4:2] 选寄存器）
//
//   偏移   名称        访问   复位   说明
//   0x00   DATA_OUT    RW     0      输出值（仅 DIR=1 的位真正驱动引脚）
//   0x04   DATA_IN     RO     -      输入值（引脚采样，同步两拍）
//   0x08   DIR         RW     0      方向：1=输出，0=输入
//   0x0C   TOGGLE      W      -      写 1 翻转 DATA_OUT 对应位（读返回 0）
//   0x10   IRQ_EN      RW     0      输入位中断使能
//   0x14   IRQ_TYPE    RW     0      0=高电平触发，1=上升沿触发
//   0x18   IRQ_STATUS  RO     -      粘滞中断标志，写 1 清除（W1C）
//   0x1C   ID          RO     0x4750494F   魔数 "GPIO"，软件探测器件在位
//
// 总线语义与 inst_rom/data_ram 一致：片选+写使能在 posedge 提交，读数据寄存输出 1 拍后有效，
// 从不插入等待周期，因此对 CoreMark 与主频零影响。
//
// 引脚侧约定（由板级顶层决定最终接法）：
//   gpio_out[i] 仅在 gpio_dir[i]=1 时有效；板级顶层可用它覆盖 soc_ddr3_leds 的硬件指示灯
//   （建议：gpio_dir[i]=1 的位由 GPIO 驱动，其余位保留硬件状态指示，互不打架）
module gpio_mmio #(
    parameter integer GPIO_WIDTH = 16,
    parameter [31:0]  ID_VALUE   = 32'h4750_494F,   // "GPIO"
    parameter integer SYNC_STAGES = 2                // 输入同步拍数
) (
    input  wire                     clk,
    input  wire                     resetn,

    // 总线从端
    input  wire                     req_valid,
    input  wire                     req_write,
    input  wire [ 1:0]              req_size,
    input  wire [31:0]              req_addr,
    input  wire [31:0]              req_wdata,
    input  wire [ 3:0]              req_wstrb,
    output wire                     req_ready,
    output wire                     rsp_valid,
    output wire [31:0]              rsp_rdata,
    output wire                     rsp_error,

    // 外部引脚
    input  wire [GPIO_WIDTH-1:0]    gpio_in,
    output wire [GPIO_WIDTH-1:0]    gpio_out,
    output wire [GPIO_WIDTH-1:0]    gpio_dir,

    // 中断（电平型，= |(IRQ_STATUS & IRQ_EN)）
    output wire                     gpio_irq
);

    localparam [2:0] R_DATA_OUT   = 3'd0,
                     R_DATA_IN    = 3'd1,
                     R_DIR        = 3'd2,
                     R_TOGGLE     = 3'd3,
                     R_IRQ_EN     = 3'd4,
                     R_IRQ_TYPE   = 3'd5,
                     R_IRQ_STATUS = 3'd6,
                     R_ID         = 3'd7;

    reg [GPIO_WIDTH-1:0] data_out_r;
    reg [GPIO_WIDTH-1:0] dir_r;
    reg [GPIO_WIDTH-1:0] irq_en_r;
    reg [GPIO_WIDTH-1:0] irq_type_r;
    reg [GPIO_WIDTH-1:0] irq_status_r;

    // 输入同步链 + 上一拍值（用于边沿检测）
    reg [GPIO_WIDTH-1:0] sync_chain [0:SYNC_STAGES-1];
    reg [GPIO_WIDTH-1:0] data_in_r;
    reg [GPIO_WIDTH-1:0] data_in_d;
    integer i;

    reg        pending;
    reg [31:0] response_data;
    reg        response_error;

    wire req_fire;
    wire access_valid;
    wire word_access;
    wire [2:0] reg_sel;

    assign reg_sel = req_addr[4:2];

    assign req_ready  = resetn && !pending;
    assign req_fire   = req_valid && req_ready;
    assign rsp_valid  = pending;
    assign rsp_rdata  = response_data;
    assign rsp_error  = rsp_valid && response_error;

    // 只支持整字访问（与视觉子系统契约一致，简单且够用）
    assign word_access  = (req_size == 2'd2) && (req_addr[1:0] == 2'b00);
    assign access_valid = (req_addr[31:5] == 27'd0) && word_access;

    assign gpio_out = data_out_r;
    assign gpio_dir = dir_r;

    // 中断：电平型，软件写 IRQ_STATUS 清
    wire [GPIO_WIDTH-1:0] irq_pending = irq_status_r & irq_en_r;
    assign gpio_irq = |irq_pending;

    // 边沿检测（上升沿）
    wire [GPIO_WIDTH-1:0] rise_edge = data_in_r & ~data_in_d;

    integer k;
    always @(posedge clk) begin
        if (!resetn) begin
            data_out_r  <= {GPIO_WIDTH{1'b0}};
            dir_r       <= {GPIO_WIDTH{1'b0}};
            irq_en_r    <= {GPIO_WIDTH{1'b0}};
            irq_type_r  <= {GPIO_WIDTH{1'b0}};
            irq_status_r<= {GPIO_WIDTH{1'b0}};
            for (k = 0; k < SYNC_STAGES; k = k + 1)
                sync_chain[k] <= {GPIO_WIDTH{1'b0}};
            data_in_r   <= {GPIO_WIDTH{1'b0}};
            data_in_d   <= {GPIO_WIDTH{1'b0}};
        end else begin
            // ---- 输入同步 ----
            sync_chain[0] <= gpio_in;
            for (k = 1; k < SYNC_STAGES; k = k + 1)
                sync_chain[k] <= sync_chain[k-1];
            data_in_d <= data_in_r;
            data_in_r <= sync_chain[SYNC_STAGES-1];

            // ---- 中断标志：先按类型置位，再处理 W1C 清除（写优先，避免丢清除）----
            for (i = 0; i < GPIO_WIDTH; i = i + 1) begin
                if (irq_en_r[i]) begin
                    if (irq_type_r[i])
                        irq_status_r[i] <= irq_status_r[i] | rise_edge[i];
                    else
                        irq_status_r[i] <= irq_status_r[i] | data_in_r[i];
                end
            end

            // ---- 寄存器写 ----
            if (req_fire && access_valid && req_write) begin
                case (reg_sel)
                    R_DATA_OUT: data_out_r <= req_wdata[GPIO_WIDTH-1:0];
                    R_DIR:      dir_r      <= req_wdata[GPIO_WIDTH-1:0];
                    R_TOGGLE:   data_out_r <= data_out_r ^ req_wdata[GPIO_WIDTH-1:0];
                    R_IRQ_EN:   irq_en_r   <= req_wdata[GPIO_WIDTH-1:0];
                    R_IRQ_TYPE: irq_type_r <= req_wdata[GPIO_WIDTH-1:0];
                    R_IRQ_STATUS:
                        // W1C：写 1 清对应位（清除优先于本拍的置位）
                        irq_status_r <= irq_status_r & ~req_wdata[GPIO_WIDTH-1:0];
                    default: ; // R_DATA_IN / R_ID 只读
                endcase
            end
        end
    end

    // ---- 读响应（寄存输出，1 拍后有效）----
    always @(posedge clk) begin
        if (!resetn) begin
            pending       <= 1'b0;
            response_data <= 32'b0;
            response_error<= 1'b0;
        end else begin
            if (rsp_valid)
                pending <= 1'b0;

            if (req_fire) begin
                pending       <= 1'b1;
                response_error<= !access_valid;
                if (!access_valid)
                    response_data <= 32'b0;
                else if (req_write)
                    // 写：回读当前值（TOGGLE 读回 0，符合"只写"语义）
                    response_data <= (reg_sel == R_TOGGLE) ? 32'b0
                                                           : req_wdata;
                else begin
                    case (reg_sel)
                        R_DATA_OUT:   response_data <= {{(32-GPIO_WIDTH){1'b0}}, data_out_r};
                        R_DATA_IN:    response_data <= {{(32-GPIO_WIDTH){1'b0}}, data_in_r};
                        R_DIR:        response_data <= {{(32-GPIO_WIDTH){1'b0}}, dir_r};
                        R_TOGGLE:     response_data <= 32'b0;
                        R_IRQ_EN:     response_data <= {{(32-GPIO_WIDTH){1'b0}}, irq_en_r};
                        R_IRQ_TYPE:   response_data <= {{(32-GPIO_WIDTH){1'b0}}, irq_type_r};
                        R_IRQ_STATUS: response_data <= {{(32-GPIO_WIDTH){1'b0}}, irq_status_r};
                        R_ID:         response_data <= ID_VALUE;
                        default:      response_data <= 32'b0;
                    endcase
                end
            end
        end
    end

endmodule
