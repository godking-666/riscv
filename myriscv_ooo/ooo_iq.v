// ============================================================================
// ooo_iq  --  out-of-order issue queue for one ALU lane.
//
//  * N entries, up to 2 inserts per cycle, 1 issue per cycle.
//  * Non data-capture: entries hold physical source tags + ready bits only;
//    operands are read from the PRF after issue.
//  * Oldest-ready-first selection with an age matrix (older[i][j] = 1 when
//    entry j is older than entry i): grant_i = req_i & ~|(req & older[i]).
//    This keeps the select -> wakeup loop short (no comparator tree).
//  * Wakeup: 4 broadcast tags.  Tags 0/1 are the *current-cycle* selections of
//    the two ALU lanes (back-to-back execution of dependent ALU ops).
// ============================================================================
module ooo_iq #(
    parameter integer N  = 8,
    parameter integer PW = 64
) (
    input  wire          clk,
    input  wire          resetn,
    input  wire          flush,
    // insert port 0 / 1
    input  wire          i0_valid,
    input  wire [PW-1:0] i0_pay,
    input  wire [5:0]    i0_p1, i0_p2, i0_pdst,
    input  wire          i0_r1, i0_r2, i0_bc,
    input  wire          i1_valid,
    input  wire [PW-1:0] i1_pay,
    input  wire [5:0]    i1_p1, i1_p2, i1_pdst,
    input  wire          i1_r1, i1_r2, i1_bc,
    // wakeup broadcasts
    input  wire [3:0]    wk_v,
    input  wire [5:0]    wk_t0, wk_t1, wk_t2, wk_t3,
    // issue
    output wire          s_valid,
    output reg  [PW-1:0] s_pay,
    output reg  [5:0]    s_p1, s_p2, s_pdst,
    output reg           s_bc,            // selected op broadcasts its pdst now
    output reg  [3:0]    count
);
    reg [N-1:0]  v, r1, r2, bc;
    reg [N-1:0]  older [0:N-1];
    reg [PW-1:0] pay [0:N-1];
    reg [5:0]    p1 [0:N-1];
    reg [5:0]    p2 [0:N-1];
    reg [5:0]    pd [0:N-1];

    // ---------------- select
    wire [N-1:0] req = v & r1 & r2;
    reg  [N-1:0] grant;
    integer i, j;
    always @* begin
        for (i = 0; i < N; i = i + 1)
            grant[i] = req[i] && !(|(req & older[i]));
    end
    assign s_valid = |req;
    always @* begin
        s_pay = {PW{1'b0}}; s_p1 = 6'd0; s_p2 = 6'd0; s_pdst = 6'd0; s_bc = 1'b0;
        for (i = 0; i < N; i = i + 1) if (grant[i]) begin
            s_pay = s_pay | pay[i]; s_p1 = s_p1 | p1[i]; s_p2 = s_p2 | p2[i];
            s_pdst = s_pdst | pd[i]; s_bc = s_bc | bc[i];
        end
    end

    // ---------------- free slots (first two), registered.
    // Computed from (valid | inserted) without crediting this cycle's issue, which
    // matches the rename-stage capacity check (it does not credit issue either).
    reg [N-1:0] f0_oh, f1_oh;
    reg [N-1:0] occ_n, nf0, nf1;
    reg found0, found1;
    always @* begin
        occ_n = v | ins0_oh | ins1_oh;
        nf0 = {N{1'b0}}; nf1 = {N{1'b0}}; found0 = 1'b0; found1 = 1'b0;
        for (i = 0; i < N; i = i + 1) begin
            if (!occ_n[i]) begin
                if (!found0) begin nf0[i] = 1'b1; found0 = 1'b1; end
                else if (!found1) begin nf1[i] = 1'b1; found1 = 1'b1; end
            end
        end
    end
    // port 0 uses the first free slot; port 1 the next one (or first if port 0 idle)
    wire [N-1:0] ins0_oh = i0_valid ? f0_oh : {N{1'b0}};
    wire [N-1:0] ins1_oh = i1_valid ? (i0_valid ? f1_oh : f0_oh) : {N{1'b0}};

    // ---------------- wake helpers
    function wk;
        input [5:0] t; input [3:0] wv;
        input [5:0] a, b, c, d;
        begin
            wk = (wv[0] && t == a) || (wv[1] && t == b) || (wv[2] && t == c) || (wv[3] && t == d);
        end
    endfunction

    // ---------------- state update
    always @(posedge clk) begin
        // payload / tags: written into the two (registered) free slots every
        // cycle - a free slot's contents are don't-care - so the ~140 write
        // enables per entry come straight from registers instead of from the
        // dispatch decision.  Port 1 is only used together with port 0, so it
        // always lands in the second free slot.
        for (i = 0; i < N; i = i + 1) begin
            if (f0_oh[i]) begin
                pay[i] <= i0_pay; p1[i] <= i0_p1; p2[i] <= i0_p2; pd[i] <= i0_pdst;
            end else if (f1_oh[i]) begin
                pay[i] <= i1_pay; p1[i] <= i1_p1; p2[i] <= i1_p2; pd[i] <= i1_pdst;
            end
        end
        if (!resetn || flush) begin
            f0_oh <= {{(N-1){1'b0}}, 1'b1}; f1_oh <= {{(N-2){1'b0}}, 2'b10};
        end else begin
            f0_oh <= nf0; f1_oh <= nf1;
        end
        if (!resetn || flush) begin
            v <= {N{1'b0}}; count <= 4'd0;
        end else begin
            for (i = 0; i < N; i = i + 1) begin
                if (ins0_oh[i]) begin
                    v[i] <= 1'b1; bc[i] <= i0_bc;
                    r1[i] <= i0_r1 || wk(i0_p1, wk_v, wk_t0, wk_t1, wk_t2, wk_t3);
                    r2[i] <= i0_r2 || wk(i0_p2, wk_v, wk_t0, wk_t1, wk_t2, wk_t3);
                    older[i] <= v & ~grant;              // every live entry is older
                end else if (ins1_oh[i]) begin
                    v[i] <= 1'b1; bc[i] <= i1_bc;
                    r1[i] <= i1_r1 || wk(i1_p1, wk_v, wk_t0, wk_t1, wk_t2, wk_t3);
                    r2[i] <= i1_r2 || wk(i1_p2, wk_v, wk_t0, wk_t1, wk_t2, wk_t3);
                    older[i] <= (v & ~grant) | ins0_oh;  // port-0 op is older
                end else begin
                    if (grant[i]) v[i] <= 1'b0;
                    if (wk(p1[i], wk_v, wk_t0, wk_t1, wk_t2, wk_t3)) r1[i] <= 1'b1;
                    if (wk(p2[i], wk_v, wk_t0, wk_t1, wk_t2, wk_t3)) r2[i] <= 1'b1;
                    // newly inserted entries are younger than this one
                    older[i] <= older[i] & ~ins0_oh & ~ins1_oh;
                end
            end
            count <= count + {3'd0, i0_valid} + {3'd0, i1_valid} - {3'd0, s_valid};
        end
    end
endmodule
