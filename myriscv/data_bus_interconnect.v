`timescale 1ns / 1ps

// 单主机、RAM/MMIO/UART/VISION/DDR 数据总线互连。
//
// 地址空间：
//   RAM    : (地址 & RAM_ADDR_MASK)    == RAM_BASE
//   MMIO   : (地址 & MMIO_ADDR_MASK)   == MMIO_BASE
//   UART   : 地址[31:4]                == UART_BASE[31:4]
//   VISION : (地址 & VISION_ADDR_MASK) == VISION_BASE   （接口契约 v1.0）
//   DDR    : ENABLE_DDR && (地址 & DDR_ADDR_MASK) == DDR_BASE
//
// CPU 使用完整的 32 位字节地址；送给从机的地址已经减去对应 BASE，
// 因而从机只看到从 0 开始的局部地址。互连最多保留一笔未完成事务，
// 并锁存请求目标，保证响应返回时不会再用已经变化的 CPU 地址做选择。
//
// ★ 视觉子系统（toCPU_vision_20261012/doc/接口契约.md v1.0）：
//   0x8000_0000 起 4 KiB，必须不可缓存；从端时序与 inst_rom/data_ram 一致
//   （片选+写使能在 posedge 提交，读数据寄存输出 1 拍后有效，从不拉低 ready），
//   因此不会给 CoreMark/主频带来任何等待周期。
//   ★ RAM_BASE 的默认值也是 0x8000_0000，与视觉段冲突；soc_top 实际传
//     DATA_RAM_BASE(=0x0) 故不冲突。若用默认值例化，RAM 优先命中、视觉段不可达。
//   ★ 将来加 D-Cache 时，命中判定必须排除本段（区间比较器直接 bypass）。
module data_bus_interconnect #(
    parameter [31:0] RAM_BASE       = 32'h8000_0000,
    parameter [31:0] RAM_ADDR_MASK  = 32'hffff_c000, // 16 KiB
    parameter [31:0] MMIO_BASE      = 32'h1000_0000,
    parameter [31:0] MMIO_ADDR_MASK = 32'hffff_f000, // 4 KiB
    parameter integer ENABLE_DDR    = 0,
    parameter [31:0] DDR_BASE       = 32'h4000_0000,
    parameter [31:0] DDR_ADDR_MASK  = 32'he000_0000, // 512 MiB
    parameter integer ENABLE_UART   = 0,
    parameter [31:0] UART_BASE      = 32'h1000_1000, // 16-byte aligned, 16 bytes
    parameter integer ENABLE_VISION = 0,
    parameter [31:0] VISION_BASE    = 32'h8000_0000,
    parameter [31:0] VISION_ADDR_MASK = 32'hffff_f000, // 4 KiB
    // 通用 GPIO（赛题基础任务 3：外设系统集成，需 GPIO）
    parameter integer ENABLE_GPIO = 0,
    parameter [31:0] GPIO_BASE      = 32'h1000_2000,
    parameter [31:0] GPIO_ADDR_MASK = 32'hffff_ffe0 // 32 bytes
) (
    input  wire        clk,
    input  wire        resetn,

    input  wire        m_req_valid,
    input  wire        m_req_write,
    input  wire [ 1:0] m_req_size,
    input  wire [31:0] m_req_addr,
    input  wire [31:0] m_req_wdata,
    input  wire [ 3:0] m_req_wstrb,
    output wire        m_req_ready,
    output wire        m_rsp_valid,
    output wire [31:0] m_rsp_rdata,
    output wire        m_rsp_error,

    output wire        ram_req_valid,
    output wire        ram_req_write,
    output wire [ 1:0] ram_req_size,
    output wire [31:0] ram_req_addr,
    output wire [31:0] ram_req_wdata,
    output wire [ 3:0] ram_req_wstrb,
    input  wire        ram_req_ready,
    input  wire        ram_rsp_valid,
    input  wire [31:0] ram_rsp_rdata,
    input  wire        ram_rsp_error,

    output wire        mmio_req_valid,
    output wire        mmio_req_write,
    output wire [ 1:0] mmio_req_size,
    output wire [31:0] mmio_req_addr,
    output wire [31:0] mmio_req_wdata,
    output wire [ 3:0] mmio_req_wstrb,
    input  wire        mmio_req_ready,
    input  wire        mmio_rsp_valid,
    input  wire [31:0] mmio_rsp_rdata,
    input  wire        mmio_rsp_error,

    output wire        ddr_req_valid,
    output wire        ddr_req_write,
    output wire [ 1:0] ddr_req_size,
    output wire [31:0] ddr_req_addr,
    output wire [31:0] ddr_req_wdata,
    output wire [ 3:0] ddr_req_wstrb,
    input  wire        ddr_req_ready,
    input  wire        ddr_rsp_valid,
    input  wire [31:0] ddr_rsp_rdata,
    input  wire        ddr_rsp_error,

    output wire        uart_req_valid,
    output wire        uart_req_write,
    output wire [ 1:0] uart_req_size,
    output wire [31:0] uart_req_addr,
    output wire [31:0] uart_req_wdata,
    output wire [ 3:0] uart_req_wstrb,
    input  wire        uart_req_ready,
    input  wire        uart_rsp_valid,
    input  wire [31:0] uart_rsp_rdata,
    input  wire        uart_rsp_error,

    // 视觉子系统从端
    output wire        vision_req_valid,
    output wire        vision_req_write,
    output wire [ 1:0] vision_req_size,
    output wire [31:0] vision_req_addr,
    output wire [31:0] vision_req_wdata,
    output wire [ 3:0] vision_req_wstrb,
    input  wire        vision_req_ready,
    input  wire        vision_rsp_valid,
    input  wire [31:0] vision_rsp_rdata,
    input  wire        vision_rsp_error,

    // 通用 GPIO 从端
    output wire        gpio_req_valid,
    output wire        gpio_req_write,
    output wire [ 1:0] gpio_req_size,
    output wire [31:0] gpio_req_addr,
    output wire [31:0] gpio_req_wdata,
    output wire [ 3:0] gpio_req_wstrb,
    input  wire        gpio_req_ready,
    input  wire        gpio_rsp_valid,
    input  wire [31:0] gpio_rsp_rdata,
    input  wire        gpio_rsp_error
);

    localparam [2:0] TARGET_RAM    = 3'd0;
    localparam [2:0] TARGET_MMIO   = 3'd1;
    localparam [2:0] TARGET_DDR    = 3'd2;
    localparam [2:0] TARGET_ERROR  = 3'd3;
    localparam [2:0] TARGET_UART   = 3'd4;
    localparam [2:0] TARGET_VISION = 3'd5;
    localparam [2:0] TARGET_GPIO   = 3'd6;

    wire ram_select;
    wire mmio_select;
    wire ddr_select;
    wire uart_select;
    wire vision_select;
    wire gpio_select;
    wire req_fire;
    reg  pending;
    reg [2:0] response_target;

    assign ram_select  = ((m_req_addr & RAM_ADDR_MASK) ==
                          (RAM_BASE & RAM_ADDR_MASK));
    // RAM 优先，避免参数配置错误导致两个窗口重叠时同时选中从机。
    assign mmio_select = !ram_select &&
                         ((m_req_addr & MMIO_ADDR_MASK) ==
                          (MMIO_BASE & MMIO_ADDR_MASK));
    assign uart_select = (ENABLE_UART != 0) && !ram_select && !mmio_select &&
                         (m_req_addr[31:4] == UART_BASE[31:4]);
    assign vision_select = (ENABLE_VISION != 0) && !ram_select && !mmio_select &&
                           !uart_select &&
                           ((m_req_addr & VISION_ADDR_MASK) ==
                            (VISION_BASE & VISION_ADDR_MASK));
    assign gpio_select = (ENABLE_GPIO != 0) && !ram_select && !mmio_select &&
                         !uart_select && !vision_select &&
                         ((m_req_addr & GPIO_ADDR_MASK) ==
                          (GPIO_BASE & GPIO_ADDR_MASK));
    assign ddr_select = (ENABLE_DDR != 0) && !ram_select && !mmio_select &&
                        !uart_select && !vision_select && !gpio_select &&
                        ((m_req_addr & DDR_ADDR_MASK) ==
                         (DDR_BASE & DDR_ADDR_MASK));

    assign m_req_ready = !pending &&
                         (ram_select    ? ram_req_ready    :
                          mmio_select   ? mmio_req_ready   :
                          uart_select   ? uart_req_ready   :
                          vision_select ? vision_req_ready :
                          gpio_select   ? gpio_req_ready   :
                          ddr_select    ? ddr_req_ready    : 1'b1);
    assign req_fire = m_req_valid && m_req_ready;

    assign ram_req_valid = !pending && m_req_valid && ram_select;
    assign ram_req_write = m_req_write;
    assign ram_req_size  = m_req_size;
    assign ram_req_addr  = m_req_addr - RAM_BASE;
    assign ram_req_wdata = m_req_wdata;
    assign ram_req_wstrb = m_req_wstrb;

    assign mmio_req_valid = !pending && m_req_valid && mmio_select;
    assign mmio_req_write = m_req_write;
    assign mmio_req_size  = m_req_size;
    assign mmio_req_addr  = m_req_addr - MMIO_BASE;
    assign mmio_req_wdata = m_req_wdata;
    assign mmio_req_wstrb = m_req_wstrb;

    assign ddr_req_valid = !pending && m_req_valid && ddr_select;
    assign ddr_req_write = m_req_write;
    assign ddr_req_size  = m_req_size;
    assign ddr_req_addr  = m_req_addr - DDR_BASE;
    assign ddr_req_wdata = m_req_wdata;
    assign ddr_req_wstrb = m_req_wstrb;

    assign uart_req_valid = !pending && m_req_valid && uart_select;
    assign uart_req_write = m_req_write;
    assign uart_req_size  = m_req_size;
    assign uart_req_addr  = m_req_addr - UART_BASE;
    assign uart_req_wdata = m_req_wdata;
    assign uart_req_wstrb = m_req_wstrb;

    assign vision_req_valid = !pending && m_req_valid && vision_select;
    assign vision_req_write = m_req_write;
    assign vision_req_size  = m_req_size;
    assign vision_req_addr  = m_req_addr - VISION_BASE;
    assign vision_req_wdata = m_req_wdata;
    assign vision_req_wstrb = m_req_wstrb;

    assign gpio_req_valid = !pending && m_req_valid && gpio_select;
    assign gpio_req_write = m_req_write;
    assign gpio_req_size  = m_req_size;
    assign gpio_req_addr  = m_req_addr - GPIO_BASE;
    assign gpio_req_wdata = m_req_wdata;
    assign gpio_req_wstrb = m_req_wstrb;

    // 未映射地址也先完成请求握手，再在下一拍返回 error，避免 CPU 死等。
    assign m_rsp_valid = pending &&
                         ((response_target == TARGET_RAM)    ? ram_rsp_valid    :
                          (response_target == TARGET_MMIO)   ? mmio_rsp_valid   :
                          (response_target == TARGET_DDR)    ? ddr_rsp_valid    :
                          (response_target == TARGET_UART)   ? uart_rsp_valid   :
                          (response_target == TARGET_VISION) ? vision_rsp_valid :
                          (response_target == TARGET_GPIO)   ? gpio_rsp_valid   :
                                                               1'b1);
    assign m_rsp_rdata = (response_target == TARGET_RAM)    ? ram_rsp_rdata    :
                         (response_target == TARGET_MMIO)   ? mmio_rsp_rdata   :
                         (response_target == TARGET_DDR)    ? ddr_rsp_rdata    :
                         (response_target == TARGET_UART)   ? uart_rsp_rdata   :
                         (response_target == TARGET_VISION) ? vision_rsp_rdata :
                         (response_target == TARGET_GPIO)   ? gpio_rsp_rdata   :
                                                              32'b0;
    assign m_rsp_error = m_rsp_valid &&
                         ((response_target == TARGET_RAM)    ? ram_rsp_error    :
                          (response_target == TARGET_MMIO)   ? mmio_rsp_error   :
                          (response_target == TARGET_DDR)    ? ddr_rsp_error    :
                          (response_target == TARGET_UART)   ? uart_rsp_error   :
                          (response_target == TARGET_VISION) ? vision_rsp_error :
                          (response_target == TARGET_GPIO)   ? gpio_rsp_error   :
                                                               1'b1);

    always @(posedge clk) begin
        if (!resetn) begin
            pending         <= 1'b0;
            response_target <= TARGET_ERROR;
        end else begin
            if (m_rsp_valid)
                pending <= 1'b0;

            if (req_fire) begin
                pending <= 1'b1;
                if (ram_select)
                    response_target <= TARGET_RAM;
                else if (mmio_select)
                    response_target <= TARGET_MMIO;
                else if (ddr_select)
                    response_target <= TARGET_DDR;
                else if (uart_select)
                    response_target <= TARGET_UART;
                else if (vision_select)
                    response_target <= TARGET_VISION;
                else if (gpio_select)
                    response_target <= TARGET_GPIO;
                else
                    response_target <= TARGET_ERROR;
            end
        end
    end

endmodule
