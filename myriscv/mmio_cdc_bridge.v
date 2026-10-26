// ============================================================================
// mmio_cdc_bridge  --  MMIO 请求/响应跨时钟桥（CPU 135 MHz ↔ 外设 93.75 MHz）
//
// 为什么需要它：乱序核的 I/O 口（ooo_dbus 的 O 端口）在 CPU 时钟域，而相机/
// 预处理/CNN/UART/GPIO 的寄存器必须在 core_clk（DDR 的 93.75 MHz）域，
// 因为它们和视频通路（pclk、HDMI 像素时钟）耦合，两个域之间必须显式同步。
//
// 协议：四相 toggle 握手 + 数据总线"稳定后才被采样"
//   - CPU 侧先锁存请求字段，下一拍才翻转 req_tgl；字段保持到整笔事务结束
//   - core 侧两级同步 req_tgl，看到翻转才发起请求（此时数据已稳定 ≥2 个 core 周期）
//   - core 侧锁存响应后才翻转 ack_tgl；CPU 侧两级同步后在翻转拍输出单拍 rsp_valid
//
// 吞吐：单笔在途，一次往返约 15~20 个 CPU 周期。MMIO 访问频率极低，
//       对 CoreMark 零影响，对 Loader 的 UART 轮询完全够用。
// ============================================================================
`timescale 1ns / 1ps

module mmio_cdc_bridge (
    // ---------------- CPU 时钟域 ----------------
    input  wire        cpu_clk,
    input  wire        cpu_resetn,
    input  wire        cpu_req_valid,
    input  wire        cpu_req_write,
    input  wire [1:0]  cpu_req_size,
    input  wire [31:0] cpu_req_addr,
    input  wire [31:0] cpu_req_wdata,
    input  wire [3:0]  cpu_req_wstrb,
    output wire        cpu_req_ready,
    output reg         cpu_rsp_valid,
    output reg  [31:0] cpu_rsp_rdata,
    output reg         cpu_rsp_error,

    // ---------------- 外设（core_clk）时钟域 ----------------
    input  wire        core_clk,
    input  wire        core_resetn,
    output wire        core_req_valid,
    output wire        core_req_write,
    output wire [1:0]  core_req_size,
    output wire [31:0] core_req_addr,
    output wire [31:0] core_req_wdata,
    output wire [3:0]  core_req_wstrb,
    input  wire        core_req_ready,
    input  wire        core_rsp_valid,
    input  wire [31:0] core_rsp_rdata,
    input  wire        core_rsp_error
);

    // ---------------------------------------------------------------- 跨域寄存器
    reg        req_tgl;                  // CPU 域 -> core 域
    reg        ack_tgl;                  // core 域 -> CPU 域
    reg [31:0] rsp_q_rdata;              // core 域锁存的响应数据（稳定）
    reg        rsp_q_error;

    // ---------------------------------------------------------------- CPU 侧
    reg        busy;
    reg [1:0]  ack_sync;
    reg        ack_seen;
    reg        q_write;
    reg [1:0]  q_size;
    reg [31:0] q_addr, q_wdata;
    reg [3:0]  q_wstrb;

    assign cpu_req_ready = !busy;
    wire ack_event = (ack_sync[1] != ack_seen);

    always @(posedge cpu_clk or negedge cpu_resetn) begin
        if (!cpu_resetn) begin
            busy <= 1'b0; req_tgl <= 1'b0; ack_sync <= 2'b0; ack_seen <= 1'b0;
            cpu_rsp_valid <= 1'b0; cpu_rsp_rdata <= 32'd0; cpu_rsp_error <= 1'b0;
            q_write <= 1'b0; q_size <= 2'd0; q_addr <= 32'd0; q_wdata <= 32'd0; q_wstrb <= 4'd0;
        end else begin
            ack_sync <= {ack_sync[0], ack_tgl};
            cpu_rsp_valid <= 1'b0;

            if (ack_event) begin
                ack_seen <= ack_sync[1];
                cpu_rsp_valid <= 1'b1;               // 单拍响应
                cpu_rsp_rdata <= rsp_q_rdata;
                cpu_rsp_error <= rsp_q_error;
                busy <= 1'b0;
            end else if (!busy && cpu_req_valid) begin
                q_write <= cpu_req_write;
                q_size  <= cpu_req_size;
                q_addr  <= cpu_req_addr;
                q_wdata <= cpu_req_wdata;
                q_wstrb <= cpu_req_wstrb;
                busy    <= 1'b1;
                req_tgl <= ~req_tgl;                 // 数据已在本拍锁存，翻转安全
            end
        end
    end

    // ---------------------------------------------------------------- core 侧
    reg [1:0] req_tgl_sync;
    reg       req_seen;
    reg       active;                    // 已受理一笔事务
    reg       accepted;                  // 互连已接受请求，撤销 valid
    // 响应看门狗：如果从设备在 WD 个 core 周期内始终不返回响应，就合成一个
    // 错误响应走正常握手路径交回 CPU（BSP 会打印 TRAP 并跳回 Loader），
    // 这样"停摆"退化成一次可恢复的总线错误，不会让整块板子失联。
    // 之后用一个"排空"状态丢弃那笔迟到的响应，避免被下一笔事务误取。
    localparam integer WD_CORE   = 512;
    localparam integer DRAIN_CORE = 512;
    reg [9:0] rsp_wd;
    reg [9:0] drain_wd;
    reg       drain;

    assign core_req_valid = active && !accepted;
    assign core_req_write = q_write;
    assign core_req_size  = q_size;
    assign core_req_addr  = q_addr;
    assign core_req_wdata = q_wdata;
    assign core_req_wstrb = q_wstrb;

    always @(posedge core_clk or negedge core_resetn) begin
        if (!core_resetn) begin
            req_tgl_sync <= 2'b0; req_seen <= 1'b0; active <= 1'b0; accepted <= 1'b0;
            ack_tgl <= 1'b0; rsp_q_rdata <= 32'd0; rsp_q_error <= 1'b0;
            rsp_wd <= 10'd0; drain <= 1'b0; drain_wd <= 10'd0;
        end else begin
            req_tgl_sync <= {req_tgl_sync[0], req_tgl};

            if (!active && !drain && (req_tgl_sync[1] != req_seen)) begin
                req_seen <= req_tgl_sync[1];
                active   <= 1'b1;
                accepted <= 1'b0;
                rsp_wd   <= 10'd0;
            end

            if (core_req_valid && core_req_ready) begin
                accepted <= 1'b1;                    // 只发一次
            end

            if (active && core_rsp_valid) begin
                rsp_q_rdata <= core_rsp_rdata;
                rsp_q_error <= core_rsp_error;
                active   <= 1'b0;
                accepted <= 1'b0;
                ack_tgl  <= ~ack_tgl;                // 数据已锁存，翻转安全
                rsp_wd   <= 10'd0;
            end else if (active) begin
                if (rsp_wd >= WD_CORE[9:0]) begin
                    // 从设备不响应：合成一个错误响应，然后进入排空
                    rsp_q_rdata <= 32'd0;
                    rsp_q_error <= 1'b1;
                    active      <= 1'b0;
                    accepted    <= 1'b0;
                    ack_tgl     <= ~ack_tgl;
                    rsp_wd      <= 10'd0;
                    drain       <= 1'b1;
                    drain_wd    <= 10'd0;
                end else begin
                    rsp_wd <= rsp_wd + 10'd1;
                end
            end

            if (drain) begin
                if (core_rsp_valid) begin
                    drain    <= 1'b0;           // 丢掉迟到的响应
                    drain_wd <= 10'd0;
                end else if (drain_wd >= DRAIN_CORE[9:0]) begin
                    drain    <= 1'b0;           // 等太久就放弃，恢复受理新事务
                    drain_wd <= 10'd0;
                end else begin
                    drain_wd <= drain_wd + 10'd1;
                end
            end
        end
    end

endmodule
