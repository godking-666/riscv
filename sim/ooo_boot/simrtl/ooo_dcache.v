// ============================================================================
// ooo_dcache  --  2-way set-associative write-back / write-allocate data cache
//
//  * LINE bytes per line, SETS sets, LRU replacement, 64-bit data RAM per way.
//  * Tag lookup in the accept cycle (distributed RAM); the hit verdict is
//    registered, so 'ready' only depends on registers.
//  * Hit latency 1: a load accepted in cycle t is answered in t+1; a store
//    hit writes the data RAM in t+1 and is acknowledged in t+1.
//  * A load accepted while the previous request (a store) writes the same
//    64-bit word takes the store bytes by forwarding (read-first RAM).
//  * Miss: blocking.  Dirty victim -> whole-line write, then whole-line read
//    (each one transaction on the line port = one DDR burst), then replay.
//  * fl_req: write back every dirty line (FENCE.I); fl_done when finished.
// ============================================================================
module ooo_dcache #(
    parameter integer SETS = 128,
    parameter integer LINE = 64
) (
    input  wire               clk, resetn,
    input  wire               c_valid,
    input  wire               c_we,
    input  wire [31:0]        c_addr,
    input  wire [31:0]        c_wdata,
    input  wire [3:0]         c_wstrb,
    output wire               c_ready,
    output reg                c_rsp_valid,
    output reg  [31:0]        c_rsp_rdata,
    output reg                c_rsp_error,
    input  wire               fl_req,
    output wire               fl_done,
    // line port
    output reg                m_valid,
    output reg                m_we,
    output reg  [31:0]        m_addr,
    output wire [LINE*8-1:0]  m_wdata,
    input  wire               m_ready,
    input  wire               m_rsp_valid,
    input  wire [LINE*8-1:0]  m_rsp_data,
    input  wire               m_rsp_error
);
    localparam integer OB = $clog2(LINE);
    localparam integer IB = $clog2(SETS);
    localparam integer TB = 32 - OB - IB;
    localparam integer WPL = LINE / 8;
    localparam integer WB = $clog2(WPL);

    reg  [TB-1:0] tag0 [0:SETS-1];
    reg  [TB-1:0] tag1 [0:SETS-1];
    reg  [SETS-1:0] v0, v1, dt0, dt1, lru;

    // ---------------- lookup at accept
    wire [IB-1:0] ci = c_addr[OB +: IB];
    wire [TB-1:0] ct = c_addr[OB+IB +: TB];
    wire hit0 = v0[ci] && tag0[ci] == ct;
    wire hit1 = v1[ci] && tag1[ci] == ct;

    localparam [2:0] S_RUN = 3'd0, S_WBRD = 3'd1, S_WBREQ = 3'd2, S_RFREQ = 3'd3,
                     S_FILL = 3'd4, S_REPLAY = 3'd5, S_ERR = 3'd6, S_FLSCAN = 3'd7;
    reg  [2:0]  st;

    // L stage
    reg         L_v, L_we, L_h0, L_h1;
    reg  [31:0] L_a;
    reg  [63:0] L_wd;
    reg  [7:0]  L_ws;
    reg  [7:0]  L_fm;            // forwarded byte mask
    reg  [63:0] L_fd;
    wire        L_hit = L_h0 || L_h1;
    wire [IB-1:0] L_set = L_a[OB +: IB];

    assign c_ready = (st == S_RUN) && (!L_v || L_hit) && !fl_req;
    wire acc = c_valid && c_ready;

    // miss handling registers
    reg  [IB-1:0] vset;          // set being written back / filled
    reg           vway;
    reg  [TB-1:0] vtag;
    reg  [WB:0]   rc;            // write-back read counter
    reg  [WB-1:0] fw;            // fill counter
    reg  [LINE*8-1:0] lbuf;      // line buffer (write-back data / refill data)
    reg           ferr, flushing;
    reg  [IB:0]   fidx;          // flush scan index {set, way}
    assign m_wdata = lbuf;

    // ---------------- data RAMs
    wire [63:0] d0, d1;
    reg         re;
    reg  [IB+WB-1:0] raddr, waddr;
    reg  [7:0]  we0, we1;
    reg  [63:0] wdin;
    always @* begin
        re = 1'b0; raddr = c_addr[3 +: IB+WB];
        we0 = 8'd0; we1 = 8'd0; waddr = L_a[3 +: IB+WB]; wdin = L_wd;
        case (st)
        S_RUN: begin
            re = acc;
            if (L_v && L_hit && L_we) begin
                we0 = L_h0 ? L_ws : 8'd0; we1 = L_h1 ? L_ws : 8'd0;
            end
        end
        S_WBRD:   begin re = 1'b1; raddr = {vset, rc[WB-1:0]}; end
        S_REPLAY: begin re = 1'b1; raddr = L_a[3 +: IB+WB]; end
        S_FILL: begin
            waddr = {vset, fw}; wdin = lbuf[fw*64 +: 64];
            we0 = vway ? 8'd0 : 8'hff; we1 = vway ? 8'hff : 8'd0;
        end
        default: ;
        endcase
    end
    ooo_sdp_ram #(.AW(IB+WB), .DW(64)) u_d0 (.clk(clk), .we(we0), .waddr(waddr), .din(wdin),
        .re(re), .raddr(raddr), .dout(d0));
    ooo_sdp_ram #(.AW(IB+WB), .DW(64)) u_d1 (.clk(clk), .we(we1), .waddr(waddr), .din(wdin),
        .re(re), .raddr(raddr), .dout(d1));

    // ---------------- response
    wire [63:0] dsel = L_h1 ? d1 : d0;
    wire [63:0] dmrg;
    genvar g;
    generate for (g = 0; g < 8; g = g + 1) begin : g_m
        assign dmrg[g*8 +: 8] = L_fm[g] ? L_fd[g*8 +: 8] : dsel[g*8 +: 8];
    end endgenerate
    always @* begin
        c_rsp_valid = (st == S_RUN) && L_v && L_hit;
        c_rsp_rdata = L_a[2] ? dmrg[63:32] : dmrg[31:0];
        c_rsp_error = 1'b0;
        if (st == S_ERR) begin c_rsp_valid = 1'b1; c_rsp_error = 1'b1; end
    end
    // flush bookkeeping: fl_ok is set when a full scan finished while fl_req is held
    reg fl_ok;
    assign fl_done = fl_ok;

    wire [IB-1:0] fset = fidx[IB:1];
    wire          fway = fidx[0];
    wire          fdirty = fway ? (v1[fset] && dt1[fset]) : (v0[fset] && dt0[fset]);

    integer i;
    always @(posedge clk) begin
        // write-back data capture (read issued last cycle)
        if (st == S_WBRD && rc != 0) lbuf[(rc-1)*64 +: 64] <= vway ? d1 : d0;
        if (st == S_RFREQ && m_rsp_valid) begin lbuf <= m_rsp_data; ferr <= m_rsp_error; end
        if (st == S_FILL && fw == WPL - 1 && !ferr) begin
            if (!vway) tag0[vset] <= vtag; else tag1[vset] <= vtag;
        end
        if (!resetn) begin
            st <= S_RUN; L_v <= 1'b0; m_valid <= 1'b0; flushing <= 1'b0; fl_ok <= 1'b0;
            v0 <= {SETS{1'b0}}; v1 <= {SETS{1'b0}}; dt0 <= {SETS{1'b0}}; dt1 <= {SETS{1'b0}};
            lru <= {SETS{1'b0}};
        end else begin
            if (!fl_req) fl_ok <= 1'b0;
            case (st)
            S_RUN: begin
                if (fl_req && !fl_ok && !L_v) begin
                    st <= S_FLSCAN; fidx <= 0; flushing <= 1'b1;
                end else if (L_v && !L_hit) begin
                    // miss: choose victim
                    vset <= L_set; vway <= lru[L_set];
                    vtag <= lru[L_set] ? tag1[L_set] : tag0[L_set];
                    if (lru[L_set] ? (v1[L_set] && dt1[L_set]) : (v0[L_set] && dt0[L_set])) begin
                        st <= S_WBRD; rc <= 0;
                    end else begin
                        st <= S_RFREQ; m_valid <= 1'b1; m_we <= 1'b0;
                        m_addr <= {L_a[31:OB], {OB{1'b0}}};
                    end
                end else begin
                    if (L_v) begin
                        lru[L_set] <= L_h0;
                        if (L_we) begin
                            if (L_h0) dt0[L_set] <= 1'b1;
                            if (L_h1) dt1[L_set] <= 1'b1;
                        end
                    end
                    L_v <= acc;
                    if (acc) begin
                        L_a <= c_addr; L_we <= c_we; L_h0 <= hit0; L_h1 <= hit1;
                        L_wd <= {c_wdata, c_wdata};
                        L_ws <= c_we ? (c_addr[2] ? {c_wstrb, 4'b0} : {4'b0, c_wstrb}) : 8'd0;
                        // forward from a store being written this cycle to the same word
                        if (L_v && L_we && L_hit && c_addr[31:3] == L_a[31:3] && !c_we) begin
                            L_fm <= L_ws; L_fd <= L_wd;
                        end else L_fm <= 8'd0;
                    end
                end
            end
            S_WBRD: begin
                rc <= rc + 1'b1;
                if (rc == WPL) begin
                    st <= S_WBREQ; m_valid <= 1'b1; m_we <= 1'b1;
                    m_addr <= {vtag, vset, {OB{1'b0}}};
                end
            end
            S_WBREQ: begin
                if (m_valid && m_ready) m_valid <= 1'b0;
                if (m_rsp_valid) begin
                    if (!vway) dt0[vset] <= 1'b0; else dt1[vset] <= 1'b0;
                    if (flushing) begin
                        st <= S_FLSCAN;          // rescans this (now clean) entry
                    end else begin
                        st <= S_RFREQ; m_valid <= 1'b1; m_we <= 1'b0;
                        m_addr <= {L_a[31:OB], {OB{1'b0}}};
                    end
                end
            end
            S_RFREQ: begin
                if (m_valid && m_ready) m_valid <= 1'b0;
                if (m_rsp_valid) begin
                    st <= S_FILL; fw <= 0; vtag <= L_a[OB+IB +: TB];
                    // the line becomes invalid while it is being overwritten
                    if (!vway) v0[vset] <= 1'b0; else v1[vset] <= 1'b0;
                end
            end
            S_FILL: begin
                fw <= fw + 1'b1;
                if (fw == WPL - 1) begin
                    if (ferr) st <= S_ERR;
                    else begin
                        st <= S_REPLAY;
                        if (!vway) begin v0[vset] <= 1'b1; dt0[vset] <= 1'b0; end
                        else       begin v1[vset] <= 1'b1; dt1[vset] <= 1'b0; end
                        L_h0 <= !vway; L_h1 <= vway;
                    end
                end
            end
            S_REPLAY: st <= S_RUN;
            S_ERR: begin st <= S_RUN; L_v <= 1'b0; end
            S_FLSCAN: begin
                if (fdirty) begin
                    vset <= fset; vway <= fway;
                    vtag <= fway ? tag1[fset] : tag0[fset];
                    st <= S_WBRD; rc <= 0;
                end else if (fidx == {(IB+1){1'b1}}) begin
                    st <= S_RUN; flushing <= 1'b0; fl_ok <= 1'b1;
                end else fidx <= fidx + 1'b1;
            end
            endcase
        end
    end
endmodule
