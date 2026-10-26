// ============================================================================
// ooo_xbar  --  address decoders / routers between the core and the memories.
//
// The core expects in-order responses.  Requests may stay outstanding to one
// target only; switching to a different target waits until every response
// from the current target has come back.  Unmapped addresses get an error
// response in the next cycle.
// ============================================================================

// ---------------------------------------------------------------- data side
module ooo_dbus #(
    parameter [31:0] TCM_BASE = 32'h4000_0000, parameter [31:0] TCM_MASK = 32'hfffe_0000,
    parameter integer HAS_DC  = 0,
    parameter [31:0] DC_BASE  = 32'h4000_0000, parameter [31:0] DC_MASK  = 32'he000_0000,
    parameter [31:0] IO_BASE  = 32'h1000_0000, parameter [31:0] IO_MASK  = 32'hffff_0000
) (
    input  wire        clk, resetn,
    // master (core)
    input  wire        m_valid, m_we,
    input  wire [31:0] m_addr, m_wdata,
    input  wire [3:0]  m_wstrb,
    input  wire [1:0]  m_size,
    output wire        m_ready,
    output reg         m_rsp_valid,
    output reg  [31:0] m_rsp_rdata,
    output reg         m_rsp_error,
    // TCM (always ready, 1-cycle)
    output wire        t_valid,
    output wire [31:0] t_addr,
    input  wire        t_rsp_valid,
    input  wire [31:0] t_rsp_rdata,
    // data cache
    output wire        c_valid,
    input  wire        c_ready,
    input  wire        c_rsp_valid,
    input  wire [31:0] c_rsp_rdata,
    input  wire        c_rsp_error,
    // I/O (one outstanding)
    output wire        o_valid,
    input  wire        o_ready,
    input  wire        o_rsp_valid,
    input  wire [31:0] o_rsp_rdata,
    input  wire        o_rsp_error
);
    localparam [1:0] TT = 2'd0, TC = 2'd1, TO = 2'd2, TE = 2'd3;
    wire hit_t = (m_addr & TCM_MASK) == TCM_BASE;
    wire hit_c = (HAS_DC != 0) && !hit_t && (m_addr & DC_MASK) == DC_BASE;
    wire hit_o = (m_addr & IO_MASK) == IO_BASE;
    wire [1:0] tgt = hit_t ? TT : hit_c ? TC : hit_o ? TO : TE;
    reg  [1:0] cur;
    reg  [2:0] cnt;
    reg        err_rsp;
    wire same = (cnt == 3'd0) || (tgt == cur);
    wire tgt_ready = (tgt == TT) ? 1'b1 : (tgt == TC) ? c_ready :
                     (tgt == TO) ? (o_ready && cnt == 3'd0) : 1'b1;
    assign m_ready = same && tgt_ready && (cnt != 3'd7);
    wire fire = m_valid && m_ready;
    assign t_valid = fire && tgt == TT;
    assign t_addr  = m_addr & ~TCM_MASK;
    assign c_valid = m_valid && same && tgt == TC && cnt != 3'd7;
    assign o_valid = m_valid && same && tgt == TO && cnt == 3'd0;
    wire rsp = (cur == TT) ? t_rsp_valid : (cur == TC) ? c_rsp_valid :
               (cur == TO) ? o_rsp_valid : err_rsp;
    always @* begin
        m_rsp_valid = (cnt != 3'd0) && rsp;
        case (cur)
        TT: begin m_rsp_rdata = t_rsp_rdata; m_rsp_error = 1'b0; end
        TC: begin m_rsp_rdata = c_rsp_rdata; m_rsp_error = c_rsp_error; end
        TO: begin m_rsp_rdata = o_rsp_rdata; m_rsp_error = o_rsp_error; end
        default: begin m_rsp_rdata = 32'd0; m_rsp_error = 1'b1; end
        endcase
    end
    always @(posedge clk) begin
        if (!resetn) begin
            cur <= TT; cnt <= 3'd0; err_rsp <= 1'b0;
        end else begin
            if (fire) cur <= tgt;
            cnt <= cnt + (fire ? 3'd1 : 3'd0) - (m_rsp_valid ? 3'd1 : 3'd0);
            err_rsp <= fire && tgt == TE;
        end
    end
endmodule

// ---------------------------------------------------------------- instruction side
module ooo_ibus #(
    parameter [31:0] TCM_BASE = 32'h4000_0000, parameter [31:0] TCM_MASK = 32'hfffe_0000,
    parameter integer HAS_IC  = 0,
    parameter [31:0] IC_BASE  = 32'h4000_0000, parameter [31:0] IC_MASK  = 32'he000_0000
) (
    input  wire        clk, resetn,
    input  wire        m_valid,
    input  wire [31:0] m_addr,
    output wire        m_ready,
    output reg         m_rsp_valid,
    output reg  [63:0] m_rsp_data,
    output reg         m_rsp_error,
    output wire        t_valid,
    output wire [31:0] t_addr,
    input  wire        t_rsp_valid,
    input  wire [63:0] t_rsp_data,
    output wire        c_valid,
    input  wire        c_ready,
    input  wire        c_rsp_valid,
    input  wire [63:0] c_rsp_data,
    input  wire        c_rsp_error
);
    localparam [1:0] TT = 2'd0, TC = 2'd1, TE = 2'd3;
    wire hit_t = (m_addr & TCM_MASK) == TCM_BASE;
    wire hit_c = (HAS_IC != 0) && !hit_t && (m_addr & IC_MASK) == IC_BASE;
    wire [1:0] tgt = hit_t ? TT : hit_c ? TC : TE;
    reg  [1:0] cur;
    reg  [2:0] cnt;
    reg        err_rsp;
    wire same = (cnt == 3'd0) || (tgt == cur);
    assign m_ready = same && (tgt != TC || c_ready) && (cnt != 3'd7);
    wire fire = m_valid && m_ready;
    assign t_valid = fire && tgt == TT;
    assign t_addr  = m_addr & ~TCM_MASK;
    assign c_valid = m_valid && same && tgt == TC && cnt != 3'd7;
    always @* begin
        case (cur)
        TT: begin m_rsp_valid = t_rsp_valid; m_rsp_data = t_rsp_data; m_rsp_error = 1'b0; end
        TC: begin m_rsp_valid = c_rsp_valid; m_rsp_data = c_rsp_data; m_rsp_error = c_rsp_error; end
        default: begin m_rsp_valid = err_rsp; m_rsp_data = 64'd0; m_rsp_error = 1'b1; end
        endcase
        if (cnt == 3'd0) m_rsp_valid = 1'b0;
    end
    always @(posedge clk) begin
        if (!resetn) begin
            cur <= TT; cnt <= 3'd0; err_rsp <= 1'b0;
        end else begin
            if (fire) cur <= tgt;
            cnt <= cnt + (fire ? 3'd1 : 3'd0) - (m_rsp_valid ? 3'd1 : 3'd0);
            err_rsp <= fire && tgt == TE;
        end
    end
endmodule

// ---------------------------------------------------------------- I/O fabric
// One request at a time to: system regs (0x1000_0xxx), UART (0x1000_1000..F),
// GPIO (0x1000_5xxx).  Local addresses are passed to the devices.
module ooo_iobus (
    input  wire        clk, resetn,
    input  wire        m_valid, m_we,
    input  wire [31:0] m_addr, m_wdata,
    input  wire [3:0]  m_wstrb,
    input  wire [1:0]  m_size,
    output wire        m_ready,
    output reg         m_rsp_valid,
    output reg  [31:0] m_rsp_rdata,
    output reg         m_rsp_error,
    // system registers
    output wire        s_valid,
    input  wire        s_rsp_valid,
    input  wire [31:0] s_rsp_rdata,
    // UART (existing uart_mmio)
    output wire        u_valid,
    input  wire        u_ready,
    input  wire        u_rsp_valid,
    input  wire [31:0] u_rsp_rdata,
    input  wire        u_rsp_error,
    // GPIO (existing gpio_mmio)
    output wire        g_valid,
    input  wire        g_ready,
    input  wire        g_rsp_valid,
    input  wire [31:0] g_rsp_rdata,
    input  wire        g_rsp_error
);
    wire hs = m_addr[15:12] == 4'h0;
    wire hu = m_addr[15:4] == 12'h100;
    wire hg = m_addr[15:12] == 4'h5;
    reg  [1:0] sel;      // 0 sys, 1 uart, 2 gpio, 3 error
    reg        busy, err_rsp;
    assign m_ready = !busy && (hu ? u_ready : hg ? g_ready : 1'b1);
    wire fire = m_valid && m_ready;
    assign s_valid = m_valid && !busy && hs;
    assign u_valid = m_valid && !busy && hu;
    assign g_valid = m_valid && !busy && hg;
    always @* begin
        case (sel)
        2'd0: begin m_rsp_valid = s_rsp_valid; m_rsp_rdata = s_rsp_rdata; m_rsp_error = 1'b0; end
        2'd1: begin m_rsp_valid = u_rsp_valid; m_rsp_rdata = u_rsp_rdata; m_rsp_error = u_rsp_error; end
        2'd2: begin m_rsp_valid = g_rsp_valid; m_rsp_rdata = g_rsp_rdata; m_rsp_error = g_rsp_error; end
        default: begin m_rsp_valid = err_rsp; m_rsp_rdata = 32'd0; m_rsp_error = 1'b1; end
        endcase
        m_rsp_valid = m_rsp_valid && busy;
    end
    always @(posedge clk) begin
        if (!resetn) begin
            busy <= 1'b0; sel <= 2'd0; err_rsp <= 1'b0;
        end else begin
            err_rsp <= fire && !(hs || hu || hg);
            if (fire) begin busy <= 1'b1; sel <= hs ? 2'd0 : hu ? 2'd1 : hg ? 2'd2 : 2'd3; end
            else if (m_rsp_valid) busy <= 1'b0;
        end
    end
endmodule
