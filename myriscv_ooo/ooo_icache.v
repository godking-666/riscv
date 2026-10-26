// ============================================================================
// ooo_icache  --  2-way set-associative instruction cache, 64-bit fetch port
//
//  * LINE bytes per line (32/64/128), SETS sets, LRU replacement.
//  * Tags in distributed RAM (looked up in the request cycle), data in block
//    RAM (one 64-bit wide simple-dual-port RAM per way).
//  * Hit latency 1, fully pipelined (one fetch packet per cycle).
//  * Miss: blocking; the whole line is fetched from the line port in one
//    transaction (burst on DDR), written into the victim way, and the missed
//    request is answered from the refill buffer.
//  * inv_req: invalidate everything (FENCE.I); inv_done answers in the next
//    idle cycle.
// ============================================================================
module ooo_icache #(
    parameter integer SETS = 128,
    parameter integer LINE = 64
) (
    input  wire               clk, resetn,
    input  wire               c_valid,
    input  wire [31:0]        c_addr,
    output wire               c_ready,
    output reg                c_rsp_valid,
    output reg  [63:0]        c_rsp_data,
    output reg                c_rsp_error,
    input  wire               inv_req,
    output wire               inv_done,
    // line port
    output reg                m_valid,
    output wire [31:0]        m_addr,
    input  wire               m_ready,
    input  wire               m_rsp_valid,
    input  wire [LINE*8-1:0]  m_rsp_data,
    input  wire               m_rsp_error
);
    localparam integer OB = $clog2(LINE);          // offset bits
    localparam integer IB = $clog2(SETS);          // index bits
    localparam integer TB = 32 - OB - IB;          // tag bits
    localparam integer WPL = LINE / 8;             // 64-bit words per line
    localparam integer WB = $clog2(WPL);

    reg  [TB-1:0] tag0 [0:SETS-1];
    reg  [TB-1:0] tag1 [0:SETS-1];
    reg  [SETS-1:0] v0, v1, lru;                   // lru: way to replace next

    // ---------------- lookup in the request cycle
    wire [IB-1:0] ci = c_addr[OB +: IB];
    wire [TB-1:0] ct = c_addr[OB+IB +: TB];
    wire hit0 = v0[ci] && tag0[ci] == ct;
    wire hit1 = v1[ci] && tag1[ci] == ct;

    localparam [1:0] S_RUN = 2'd0, S_MISS = 2'd1, S_FILL = 2'd2, S_RESP = 2'd3;
    reg  [1:0]  st;
    reg         s1_v, s1_h0, s1_h1;
    reg  [31:0] s1_a;
    wire s1_miss = s1_v && !s1_h0 && !s1_h1;
    assign c_ready = (st == S_RUN) && !s1_miss && !inv_req;
    wire acc = c_valid && c_ready;

    // ---------------- data RAMs
    wire [63:0] d0, d1;
    reg  [WB-1:0] fw;                              // refill word counter
    reg  [LINE*8-1:0] fbuf;
    reg         fway, ferr;
    wire        fill_we = (st == S_FILL);
    wire [IB+WB-1:0] raddr = c_addr[3 +: IB+WB];
    wire [IB+WB-1:0] waddr = {s1_a[OB +: IB], fw};
    wire [63:0] fdata = fbuf[fw*64 +: 64];
    ooo_sdp_ram #(.AW(IB+WB), .DW(64)) u_d0 (.clk(clk), .we({8{fill_we && !fway}}), .waddr(waddr),
        .din(fdata), .re(acc), .raddr(raddr), .dout(d0));
    ooo_sdp_ram #(.AW(IB+WB), .DW(64)) u_d1 (.clk(clk), .we({8{fill_we && fway}}), .waddr(waddr),
        .din(fdata), .re(acc), .raddr(raddr), .dout(d1));

    assign m_addr = {s1_a[31:OB], {OB{1'b0}}};
    assign inv_done = inv_req && (st == S_RUN) && !s1_v;

    always @* begin
        c_rsp_valid = 1'b0; c_rsp_data = s1_h1 ? d1 : d0; c_rsp_error = 1'b0;
        if (st == S_RUN && s1_v && (s1_h0 || s1_h1)) c_rsp_valid = 1'b1;
        if (st == S_RESP) begin
            c_rsp_valid = 1'b1; c_rsp_data = fbuf[s1_a[OB-1:3]*64 +: 64]; c_rsp_error = ferr;
        end
    end

    integer i;
    always @(posedge clk) begin
        if (m_rsp_valid && st == S_MISS) begin fbuf <= m_rsp_data; ferr <= m_rsp_error; end
        if (st == S_FILL && fw == WPL - 1 && !ferr) begin
            if (!fway) tag0[s1_a[OB +: IB]] <= s1_a[OB+IB +: TB];
            else       tag1[s1_a[OB +: IB]] <= s1_a[OB+IB +: TB];
        end
        if (!resetn) begin
            st <= S_RUN; s1_v <= 1'b0; m_valid <= 1'b0; fw <= 0;
            v0 <= {SETS{1'b0}}; v1 <= {SETS{1'b0}}; lru <= {SETS{1'b0}};
        end else begin
            case (st)
            S_RUN: begin
                if (inv_req && !s1_v) begin v0 <= {SETS{1'b0}}; v1 <= {SETS{1'b0}}; end
                if (s1_miss) begin
                    st <= S_MISS; m_valid <= 1'b1; fway <= lru[s1_a[OB +: IB]];
                end else begin
                    if (s1_v) lru[s1_a[OB +: IB]] <= s1_h0;        // other way is LRU
                    s1_v <= acc; s1_a <= c_addr; s1_h0 <= hit0; s1_h1 <= hit1;
                end
            end
            S_MISS: begin
                if (m_valid && m_ready) m_valid <= 1'b0;
                if (m_rsp_valid) begin st <= S_FILL; fw <= 0; end
            end
            S_FILL: begin
                fw <= fw + 1'b1;
                if (fw == WPL - 1) begin
                    st <= S_RESP;
                    if (!ferr) begin
                        if (!fway) v0[s1_a[OB +: IB]] <= 1'b1; else v1[s1_a[OB +: IB]] <= 1'b1;
                        lru[s1_a[OB +: IB]] <= !fway;
                    end
                end
            end
            S_RESP: begin
                st <= S_RUN; s1_v <= 1'b0;
            end
            endcase
        end
    end
endmodule
