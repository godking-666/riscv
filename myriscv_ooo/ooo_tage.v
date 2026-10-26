// ============================================================================
// ooo_tage  --  TAGE conditional-branch direction predictor (overriding).
//
//  Organisation (per fetch packet of two instruction slots):
//    * base predictor : 2 banks (slot 0 / slot 1) x 1024 x 2-bit counters
//    * tagged tables  : 4 tables x 2 banks x 512 entries
//                       entry = {valid, tag[8:0], ctr[2:0], u[1:0]}
//                       history lengths 4 / 10 / 24 / 64 bits
//    * global history : 64-bit PATH history, one bit per TAKEN control
//                       transfer (pc[2]^pc[3]^pc[5] of the branch).  Taken-only
//                       history is the same for both slots of a packet, so one
//                       lookup per packet serves both slots.
//
//  Timing:
//    F0 (cycle n)   : index/tag hash of {pc, history} -> block RAM port A
//    F1 (cycle n+1) : tag compare, provider select -> d0 / d1 (registered by
//                     the front end).  The front end overrides its fast BTB
//                     prediction when they differ.
//  Update (block RAM port B), fed from commit in program order:
//    U0 : pop the update FIFO, read the packet's history snapshot, hash,
//         read all tables
//    U1 : register the table data (keeps the block-RAM output path short)
//    U2 : compute provider / alt / allocation, write back
//    One update every three cycles; an 8-entry FIFO absorbs bursts (a full
//    FIFO drops the update - it only costs accuracy, never correctness).
//
//  History snapshots: every packet accepted into the instruction buffer
//  gets a 6-bit packet id; the history it was predicted with is stored in
//  a 64-entry table.  Instructions carry the id, so a redirect (branch
//  mispredict, decode fix-up) and the commit-time update can recover it.
//
//  Nothing here affects architectural correctness: a wrong history or a lost
//  update only changes prediction quality.
// ============================================================================
module ooo_tage (
    input  wire        clk,
    input  wire        resetn,
    // ---- lookup (F0): packet PC and the speculative history before it
    input  wire [31:3] lk_pc,
    input  wire [63:0] lk_hist,
    // ---- prediction (F1, combinational from block RAM outputs)
    output wire        pr_d0,          // slot 0 predicted taken
    output wire        pr_d1,          // slot 1 predicted taken
    // ---- history snapshot table
    input  wire        sn_we,
    input  wire [5:0]  sn_id,
    input  wire [63:0] sn_hist,
    input  wire [5:0]  fx_id,          // asynchronous read for redirects
    output wire [63:0] fx_hist,
    // ---- training from commit (two branches per cycle)
    input  wire        up0_v,
    input  wire [31:2] up0_pc,
    input  wire        up0_t,
    input  wire [5:0]  up0_id,
    input  wire        up1_v,
    input  wire [31:2] up1_pc,
    input  wire        up1_t,
    input  wire [5:0]  up1_id
);
    localparam integer NT = 4;                 // tagged tables
    localparam integer IB = 9;                 // index bits (512 entries / bank)
    localparam integer TB = 9;                 // tag bits
    localparam integer EW = 1 + TB + 3 + 2;    // entry width
    localparam integer BB = 10;                // base index bits

    // ------------------------------------------------------------ snapshots
    (* syn_ramstyle = "select_ram" *) reg [63:0] snap [0:63];
`ifdef OOO_SIM
    integer si;
    initial for (si = 0; si < 64; si = si + 1) snap[si] = 64'd0;
`endif
    always @(posedge clk) if (sn_we) snap[sn_id] <= sn_hist;
    assign fx_hist = snap[fx_id];

    // ------------------------------------------------------------ hashing
    // index_k = pc[11:3] ^ pc[20:12] ^ fold(hist[L_k-1:0], 9)
    // tag_k   = pc[11:3] ^ fold(hist, 9) ^ (fold(hist, 8) << 1)
    function [8:0] f9;                         // fold the low L bits into 9
        input [63:0] h; input [6:0] L;
        integer i;
        begin
            f9 = 9'd0;
            for (i = 0; i < 64; i = i + 1) if (i < L) f9[i % 9] = f9[i % 9] ^ h[i];
        end
    endfunction
    function [7:0] f8;
        input [63:0] h; input [6:0] L;
        integer i;
        begin
            f8 = 8'd0;
            for (i = 0; i < 64; i = i + 1) if (i < L) f8[i % 8] = f8[i % 8] ^ h[i];
        end
    endfunction
    function [6:0] hlen;
        input integer k;
        begin
            case (k) 0: hlen = 4; 1: hlen = 10; 2: hlen = 24; default: hlen = 64; endcase
        end
    endfunction
    function [IB-1:0] hidx;
        input [31:3] pc; input [63:0] h; input integer k;
        begin hidx = pc[11:3] ^ pc[20:12] ^ f9(h, hlen(k)); end
    endfunction
    function [TB-1:0] htag;
        input [31:3] pc; input [63:0] h; input integer k;
        begin htag = pc[11:3] ^ f9(h, hlen(k)) ^ {f8(h, hlen(k)), 1'b0}; end
    endfunction

    // ------------------------------------------------------------ update FIFO
    reg  [36:0] uq [0:7];                       // {id, t, pc[31:2]}
    reg  [2:0]  uq_wp, uq_rp;
    reg  [3:0]  uq_n;
    reg         ub_v;                           // U1 stage busy (RAM read in flight)
    reg         uc_v;                           // U2 stage busy (write back)
    wire        u_pop = (uq_n != 4'd0) && !ub_v && !uc_v;
    wire [36:0] uh = uq[uq_rp];
    wire [31:2] u_pc = uh[29:0];
    wire        u_t  = uh[30];
    wire [5:0]  u_id = uh[36:31];
    wire [63:0] u_hist = snap[u_id];
    // a full FIFO drops the update (accuracy only)
    wire        acc0 = up0_v && (uq_n < 4'd8);
    wire        acc1 = up1_v && ({1'b0, uq_n} + {4'd0, acc0} < 5'd8);
    always @(posedge clk) begin
        if (acc0) uq[uq_wp] <= {up0_id, up0_t, up0_pc};
        if (acc1) uq[acc0 ? uq_wp + 3'd1 : uq_wp] <= {up1_id, up1_t, up1_pc};
        if (!resetn) begin
            uq_wp <= 3'd0; uq_rp <= 3'd0; uq_n <= 4'd0;
        end else begin
            uq_wp <= uq_wp + {2'd0, acc0} + {2'd0, acc1};
            uq_rp <= uq_rp + {2'd0, u_pop};
            uq_n  <= uq_n + {3'd0, acc0} + {3'd0, acc1} - {3'd0, u_pop};
        end
    end

    // ------------------------------------------------------------ tables
    reg  [TB-1:0] la_tag [0:NT-1];              // lookup tags, registered for F1
    reg  [TB-1:0] ub_tag [0:NT-1];
    reg  [IB-1:0] ub_idx [0:NT-1];
    reg  [BB-1:0] ub_bidx;
    reg           ub_bank, ub_t;
    reg  [EW-1:0] uc_e [0:NT-1];                // U2: registered table data (selected bank)
    reg  [1:0]    uc_b;
    wire [EW-1:0] ea0 [0:NT-1];                 // port A data, bank 0 / bank 1
    wire [EW-1:0] ea1 [0:NT-1];
    wire [EW-1:0] eb0 [0:NT-1];                 // port B data
    wire [EW-1:0] eb1 [0:NT-1];
    reg  [EW-1:0] wdat [0:NT-1];
    reg  [NT-1:0] wen;
    wire [1:0]    ba0, ba1, bb0, bb1;
    reg  [1:0]    bwdat;
    reg           bwen;

    genvar g;
    generate for (g = 0; g < NT; g = g + 1) begin : T
        wire [IB-1:0] ia = hidx(lk_pc, lk_hist, g);
        wire [IB-1:0] iu = hidx(u_pc[31:3], u_hist, g);
        always @(posedge clk) begin
            la_tag[g] <= htag(lk_pc, lk_hist, g);
            if (u_pop) begin
                ub_idx[g] <= iu;
                ub_tag[g] <= htag(u_pc[31:3], u_hist, g);
            end
        end
        ooo_tage_ram #(.AW(IB), .DW(EW)) u_b0 (.clk(clk),
            .a_addr(ia), .a_dout(ea0[g]),
            .b_addr(uc_v ? ub_idx[g] : iu), .b_we(wen[g] && !ub_bank), .b_din(wdat[g]), .b_dout(eb0[g]));
        ooo_tage_ram #(.AW(IB), .DW(EW)) u_b1 (.clk(clk),
            .a_addr(ia), .a_dout(ea1[g]),
            .b_addr(uc_v ? ub_idx[g] : iu), .b_we(wen[g] && ub_bank), .b_din(wdat[g]), .b_dout(eb1[g]));
        always @(posedge clk) if (ub_v) uc_e[g] <= ub_bank ? eb1[g] : eb0[g];
    end endgenerate
    ooo_tage_ram #(.AW(BB), .DW(2)) u_base0 (.clk(clk),
        .a_addr(lk_pc[12:3]), .a_dout(ba0),
        .b_addr(uc_v ? ub_bidx : u_pc[12:3]), .b_we(bwen && !ub_bank), .b_din(bwdat), .b_dout(bb0));
    ooo_tage_ram #(.AW(BB), .DW(2)) u_base1 (.clk(clk),
        .a_addr(lk_pc[12:3]), .a_dout(ba1),
        .b_addr(uc_v ? ub_bidx : u_pc[12:3]), .b_we(bwen && ub_bank), .b_din(bwdat), .b_dout(bb1));
    always @(posedge clk) if (ub_v) uc_b <= ub_bank ? bb1 : bb0;

    // entry fields
    function        e_v;   input [EW-1:0] e; e_v   = e[EW-1];          endfunction
    function [TB-1:0] e_tag; input [EW-1:0] e; e_tag = e[EW-2 -: TB];   endfunction
    function [2:0]  e_ctr; input [EW-1:0] e; e_ctr = e[4:2];            endfunction
    function [1:0]  e_u;   input [EW-1:0] e; e_u   = e[1:0];            endfunction

    // ------------------------------------------------------------ F1 prediction
    reg [NT-1:0] ha0, ha1;
    integer k;
    always @* for (k = 0; k < NT; k = k + 1) begin
        ha0[k] = e_v(ea0[k]) && (e_tag(ea0[k]) == la_tag[k]);
        ha1[k] = e_v(ea1[k]) && (e_tag(ea1[k]) == la_tag[k]);
    end
    function pick;                              // longest-history hit, else base
        input [NT-1:0] h; input [EW-1:0] e0, e1, e2, e3; input [1:0] b;
        begin
            if (h[3])      pick = e3[4];
            else if (h[2]) pick = e2[4];
            else if (h[1]) pick = e1[4];
            else if (h[0]) pick = e0[4];
            else           pick = b[1];
        end
    endfunction
    assign pr_d0 = pick(ha0, ea0[0], ea0[1], ea0[2], ea0[3], ba0);
    assign pr_d1 = pick(ha1, ea1[0], ea1[1], ea1[2], ea1[3], ba1);

    // ------------------------------------------------------------ U1 training
    reg [15:0] lfsr;
    reg [EW-1:0] eb [0:NT-1];
    reg [NT-1:0] hb, prv, hb2, alt_oh, above, cand, c1, c2, aloc;
    reg [1:0]    bctr;
    reg [2:0]    pctr, actr;
    reg          has_p, has_a, pr, ap, mis;
    integer j;
    always @* begin
        for (j = 0; j < NT; j = j + 1) begin
            eb[j] = uc_e[j];
            hb[j] = e_v(eb[j]) && (e_tag(eb[j]) == ub_tag[j]);
        end
        bctr = uc_b;
        // provider = highest hit, alternate = next highest hit (one-hot)
        prv    = {hb[3], hb[2] & ~hb[3], hb[1] & ~|hb[3:2], hb[0] & ~|hb[3:1]};
        hb2    = hb & ~prv;
        alt_oh = {hb2[3], hb2[2] & ~hb2[3], hb2[1] & ~|hb2[3:2], hb2[0] & ~|hb2[3:1]};
        has_p = |hb; has_a = |hb2;
        pctr = 3'd0; actr = 3'd0;
        for (j = 0; j < NT; j = j + 1) begin
            if (prv[j])    pctr = pctr | e_ctr(eb[j]);
            if (alt_oh[j]) actr = actr | e_ctr(eb[j]);
        end
        pr  = has_p ? pctr[2] : bctr[1];
        ap  = has_a ? actr[2] : bctr[1];
        mis = (pr != ub_t);
        // tables above the provider; allocation candidates have u == 0
        above = {~hb[3], ~|hb[3:2], ~|hb[3:1], ~|hb[3:0]};
        for (j = 0; j < NT; j = j + 1) cand[j] = above[j] && (e_u(eb[j]) == 2'd0);
        c1 = cand & ~(cand - 4'd1);             // lowest candidate
        c2 = (cand & ~c1) & ~((cand & ~c1) - 4'd1);
        aloc = (c2 != 4'd0 && lfsr[1:0] == 2'd0) ? c2 : c1;
        // writes
        wen = {NT{1'b0}}; bwen = 1'b0; bwdat = bctr;
        for (j = 0; j < NT; j = j + 1) begin
            wdat[j] = eb[j];
            if (uc_v && prv[j]) begin
                wen[j] = 1'b1;
                wdat[j][4:2] = ub_t ? ((e_ctr(eb[j]) == 3'd7) ? 3'd7 : e_ctr(eb[j]) + 3'd1)
                                    : ((e_ctr(eb[j]) == 3'd0) ? 3'd0 : e_ctr(eb[j]) - 3'd1);
                if (pr != ap)
                    wdat[j][1:0] = (pr == ub_t) ? ((e_u(eb[j]) == 2'd3) ? 2'd3 : e_u(eb[j]) + 2'd1)
                                                : ((e_u(eb[j]) == 2'd0) ? 2'd0 : e_u(eb[j]) - 2'd1);
            end
            if (uc_v && mis && !hb[3]) begin
                if (aloc[j]) begin
                    wen[j] = 1'b1;
                    wdat[j] = {1'b1, ub_tag[j], ub_t ? 3'd4 : 3'd3, 2'd0};
                end else if (cand == 4'd0 && above[j]) begin
                    wen[j] = 1'b1;
                    wdat[j][1:0] = (e_u(eb[j]) == 2'd0) ? 2'd0 : e_u(eb[j]) - 2'd1;
                end
            end
        end
        if (uc_v && !has_p) begin
            bwen = 1'b1;
            bwdat = ub_t ? ((bctr == 2'd3) ? 2'd3 : bctr + 2'd1)
                         : ((bctr == 2'd0) ? 2'd0 : bctr - 2'd1);
        end
    end
    always @(posedge clk) begin
        if (u_pop) begin
            ub_bank <= u_pc[2]; ub_t <= u_t; ub_bidx <= u_pc[12:3];
        end
        if (!resetn) begin
            ub_v <= 1'b0; uc_v <= 1'b0; lfsr <= 16'hACE1;
        end else begin
            ub_v <= u_pop; uc_v <= ub_v;
            lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
        end
    end
endmodule

// ----------------------------------------------------------------------------
// ooo_tage_ram -- true dual-port block RAM: port A read-only, port B
// read/write (read-first).  Both reads are synchronous (1-cycle latency).
// Block RAM powers up as zero, which is the "invalid entry / weakly not
// taken" state the predictor expects.
// ----------------------------------------------------------------------------
module ooo_tage_ram #(
    parameter integer AW = 9,
    parameter integer DW = 15
) (
    input  wire          clk,
    input  wire [AW-1:0] a_addr,
    output reg  [DW-1:0] a_dout,
    input  wire [AW-1:0] b_addr,
    input  wire          b_we,
    input  wire [DW-1:0] b_din,
    output reg  [DW-1:0] b_dout
);
    (* syn_ramstyle = "block_ram" *) reg [DW-1:0] mem [0:(1<<AW)-1];
`ifdef OOO_SIM
    integer i;
    initial for (i = 0; i < (1 << AW); i = i + 1) mem[i] = {DW{1'b0}};
`endif
    always @(posedge clk) a_dout <= mem[a_addr];
    always @(posedge clk) begin
        b_dout <= mem[b_addr];
        if (b_we) mem[b_addr] <= b_din;
    end
endmodule
