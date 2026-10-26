// ============================================================================
// ooo_lsu  --  memory pipe with out-of-order load issue, store queue and
//              store-to-load forwarding.
//
//  IQM (16 entries, 2 inserts/cycle, age matrix) -> R (PRF read + bypass select)
//    -> A (address, misalign, store-queue check, memory request)
//    -> response (in order, any latency) -> PRF write + wakeup.
//
//  Issue order: the oldest *eligible* entry is selected each cycle.
//    * a load is eligible when its address operand is ready and every older
//      store in the queue has already issued - loads may pass older loads
//      (always safe on a single core) but never an older store;
//    * a store is eligible only as the oldest entry of the queue.
//  Hence every store in the store queue is older than a load in stage A, and
//  no store in the queue is younger than any waiting load: no ordering
//  violations are possible and store-to-load forwarding needs no age check.
//  The "blocked by an older entry" bit is registered (computed from the
//  previous cycle's state, which can only be more conservative).
//  Stores complete (in the ROB) after writing the store queue; they are sent
//  to memory only after commit.  Loads to I/O space wait until they are the
//  oldest instruction and the store queue is empty.  A load whose bytes are
//  fully covered by the youngest overlapping older store takes that store's
//  data; partial overlap waits for the drain.
// ============================================================================
module ooo_lsu #(
    parameter [31:0] ORD0_BASE = 32'h4000_0000, parameter [31:0] ORD0_MASK = 32'he000_0000,
    parameter [31:0] ORD1_BASE = 32'h0000_0000, parameter [31:0] ORD1_MASK = 32'hfff0_0000
) (
    input  wire        clk, resetn, flush,
    // dispatch (2 ports)
    input  wire        m0_valid, m0_wen, m0_r1, m0_r2, m0_st, m0_uns,
    input  wire [4:0]  m0_rob,
    input  wire [5:0]  m0_pdst, m0_p1, m0_p2,
    input  wire [1:0]  m0_size,
    input  wire [31:0] m0_imm,
    input  wire        m1_valid, m1_wen, m1_r1, m1_r2, m1_st, m1_uns,
    input  wire [4:0]  m1_rob,
    input  wire [5:0]  m1_pdst, m1_p1, m1_p2,
    input  wire [1:0]  m1_size,
    input  wire [31:0] m1_imm,
    output reg  [4:0]  count,
    // wakeup
    input  wire [3:0]  wk_v,
    input  wire [5:0]  wk_t0, wk_t1, wk_t2, wk_t3,
    // register read / bypass
    output wire [5:0]  rf_ra1, rf_ra2,
    input  wire [31:0] rf_rd1, rf_rd2,
    input  wire        x0_wv, x1_wv,          // ALU lanes writing at end of this cycle
    input  wire [5:0]  x0_pdst, x1_pdst,
    input  wire [31:0] xr0, xr1,              // ALU lane results registered last cycle
    // ROB interaction
    input  wire        rob_head_valid,
    input  wire [4:0]  rob_head,
    input  wire [1:0]  st_commit,            // stores committed this cycle
    // completion port A (stores, misaligned loads)
    output reg         ca_valid,
    output reg  [4:0]  ca_rob,
    output reg         ca_exc,
    output reg  [4:0]  ca_cause,
    output reg  [31:0] ca_tval,
    // completion port R (load responses) + register write
    output reg         cr_valid,
    output reg  [4:0]  cr_rob,
    output reg         cr_exc,
    output reg  [31:0] cr_tval,
    output wire        wb_valid,              // write PRF + wakeup (in the response cycle)
    output wire        wb_v_q0, wb_v_q1,      // copies of wb_valid for the two ALU issue queues
    output wire [5:0]  wb_pdst,
    output wire [31:0] wb_data,
    // memory
    output reg         dreq_valid,
    output reg         dreq_we,
    output reg  [31:0] dreq_addr,
    output reg  [31:0] dreq_wdata,
    output reg  [3:0]  dreq_wstrb,
    output reg  [1:0]  dreq_size,
    input  wire        dreq_ready,
    input  wire        drsp_valid,
    input  wire [31:0] drsp_rdata,
    input  wire        drsp_error,
    // status
    output wire        sq_empty,
    output wire        mem_idle,               // nothing outstanding at all
    output wire        io_busy,                // an I/O load is outstanding
    input  wire        io_hold                 // do not start I/O loads (interrupt pending)
);
    integer i, k;
    // ------------------------------------------------------------------ IQM (age matrix)
    localparam integer QN = 16;
    reg [QN-1:0] qv, qr1, qr2, qst, qblk;
    reg [QN-1:0] qold [0:QN-1];        // qold[i][j]: entry j is older than entry i
    reg [4:0]  q_rob  [0:QN-1];
    reg [5:0]  q_pd   [0:QN-1];
    reg [5:0]  q_p1   [0:QN-1];
    reg [5:0]  q_p2   [0:QN-1];
    reg        q_wen  [0:QN-1];
    reg        q_uns  [0:QN-1];
    reg [1:0]  q_sz   [0:QN-1];
    reg [31:0] q_imm  [0:QN-1];

    // the load-wakeup term uses a private copy of wb_valid (wb_v_lsu, below)
    wire wb_v_lsu;
    function wk;
        input [5:0] t;
        begin
            wk = (wk_v[0] && t == wk_t0) || (wk_v[1] && t == wk_t1) ||
                 (wk_v[2] && t == wk_t2) || (wb_v_lsu && t == wk_t3);
        end
    endfunction

    // ---- select: oldest eligible entry
    wire [QN-1:0] qel = qv & qr1 & (qr2 | ~qst) & ~qblk;
    reg  [QN-1:0] qgnt;
    always @* for (i = 0; i < QN; i = i + 1) qgnt[i] = qel[i] && !(|(qel & qold[i]));
    wire head_rdy = |qel;
    // ---- free slots (first two), registered, from (valid | inserted) like ooo_iq
    reg  [QN-1:0] qf0, qf1, q_occ, q_nf0, q_nf1;
    reg  q_fd0, q_fd1;
    wire [QN-1:0] qins0 = m0_valid ? qf0 : {QN{1'b0}};
    wire [QN-1:0] qins1 = m1_valid ? qf1 : {QN{1'b0}};     // port 1 only with port 0
    always @* begin
        q_occ = qv | qins0 | qins1;
        q_nf0 = {QN{1'b0}}; q_nf1 = {QN{1'b0}}; q_fd0 = 1'b0; q_fd1 = 1'b0;
        for (i = 0; i < QN; i = i + 1)
            if (!q_occ[i]) begin
                if (!q_fd0) begin q_nf0[i] = 1'b1; q_fd0 = 1'b1; end
                else if (!q_fd1) begin q_nf1[i] = 1'b1; q_fd1 = 1'b1; end
            end
    end
    // selected entry's fields (one-hot AND-OR)
    reg [4:0]  g_rob; reg [5:0] g_pd, g_p1, g_p2; reg g_wen, g_st, g_uns; reg [1:0] g_sz; reg [31:0] g_imm;
    always @* begin
        g_rob = 5'd0; g_pd = 6'd0; g_p1 = 6'd0; g_p2 = 6'd0; g_wen = 1'b0; g_st = 1'b0; g_uns = 1'b0;
        g_sz = 2'd0; g_imm = 32'd0;
        for (i = 0; i < QN; i = i + 1) if (qgnt[i]) begin
            g_rob = g_rob | q_rob[i]; g_pd = g_pd | q_pd[i]; g_p1 = g_p1 | q_p1[i]; g_p2 = g_p2 | q_p2[i];
            g_wen = g_wen | q_wen[i]; g_st = g_st | qst[i]; g_uns = g_uns | q_uns[i];
            g_sz = g_sz | q_sz[i]; g_imm = g_imm | q_imm[i];
        end
    end
    // registered "blocked by an older entry" (from the current state; an entry
    // leaving this cycle still counts, so the bit is conservative)
    wire [QN-1:0] q_vs = qv & qst;

    // ------------------------------------------------------------------ R stage
    reg        r_v, r_wen, r_st, r_uns;
    reg [4:0]  r_rob;
    reg [5:0]  r_pd, r_p1, r_p2;
    reg [1:0]  r_sz;
    reg [31:0] r_imm;
    assign rf_ra1 = r_p1;
    assign rf_ra2 = r_p2;

    // ------------------------------------------------------------------ A stage
    reg        a_v, a_wen, a_st, a_uns;
    reg [4:0]  a_rob;
    reg [5:0]  a_pd;
    reg [1:0]  a_sz;
    reg [31:0] a_imm;
    reg [31:0] a_o1, a_o2;          // operand value (PRF or held)
    reg [1:0]  a_b1, a_b2;          // bypass select {lane1, lane0}
    wire [31:0] op1 = a_b1[0] ? xr0 : (a_b1[1] ? xr1 : a_o1);
    wire [31:0] op2 = a_b2[0] ? xr0 : (a_b2[1] ? xr1 : a_o2);
    wire [31:0] addr = op1 + a_imm;
    wire mis = (a_sz == 2'd1 && addr[0]) || (a_sz == 2'd2 && addr[1:0] != 2'b00);
    wire is_io = !(((addr & ORD0_MASK) == ORD0_BASE) || ((addr & ORD1_MASK) == ORD1_BASE));
    wire [3:0] bmask = (a_sz == 2'd0) ? (4'b0001 << addr[1:0]) :
                       (a_sz == 2'd1) ? (addr[1] ? 4'b1100 : 4'b0011) : 4'b1111;
    wire [31:0] sdata = (a_sz == 2'd0) ? {4{op2[7:0]}} :
                        (a_sz == 2'd1) ? {2{op2[15:0]}} : op2;

    // ------------------------------------------------------------------ store queue
    reg [29:0] sq_addr [0:7];
    reg [31:0] sq_data [0:7];
    reg [3:0]  sq_strb [0:7];
    reg        sq_io   [0:7];
    reg [2:0]  sq_h, sq_c, sq_t;    // head (oldest), first uncommitted, tail
    reg [3:0]  sq_n;                // entries in queue
    reg [3:0]  sq_nc;               // committed entries
    wire sq_full = (sq_n == 4'd8);
    assign sq_empty = (sq_n == 4'd0);

    // youngest overlapping older store
    reg        ov_any, ov_full;
    reg [31:0] ov_data;
    reg [2:0]  ovi;
    always @* begin
        ov_any = 1'b0; ov_full = 1'b0; ov_data = 32'd0;
        for (k = 0; k < 8; k = k + 1) begin
            ovi = sq_h + k[2:0];
            if (k < sq_n && sq_addr[ovi] == addr[31:2] && (sq_strb[ovi] & bmask) != 4'b0) begin
                ov_any  = 1'b1;
                ov_full = ((sq_strb[ovi] & bmask) == bmask) && !sq_io[ovi];
                ov_data = sq_data[ovi];
            end
        end
    end

    // ------------------------------------------------------------------ outstanding queue
    reg [3:0]  oq_v, oq_ld, oq_kill, oq_io, oq_fwd, oq_uns;
    reg [4:0]  oq_rob [0:3];
    reg [5:0]  oq_pd  [0:3];
    reg        oq_wen [0:3];
    reg [1:0]  oq_sz  [0:3];
    reg [31:0] oq_addr[0:3];
    reg [31:0] oq_fd  [0:3];
    reg [1:0]  oq_h, oq_t;
    reg [2:0]  oq_n;
    wire oq_full = (oq_n == 3'd4);
    assign mem_idle = (oq_n == 3'd0);
    // ------------------------------------------------------------------ Q stage (registered load request)
    reg        qq_v, qq_wen, qq_io, qq_fwd, qq_uns, qq_conf;
    reg [3:0]  qq_older;          // older stores still in the store queue
    reg        qq_wait_r;         // registered copy of qq_wait (may lag by one cycle)
    reg [4:0]  qq_rob;
    reg [5:0]  qq_pd;
    reg [1:0]  qq_sz;
    reg [31:0] qq_addr, qq_fd;
    // only I/O loads already sent count; one waiting in Q cannot issue while an
    // interrupt is pending (io_hold), so taking the interrupt is safe
    assign io_busy  = |(oq_v & oq_ld & oq_io & ~oq_kill);

    // ------------------------------------------------------------------ A-stage decisions
    wire a_ld = a_v && !a_st;
    // Q stage waits (from registered state only):
    //  * partial overlap with an older store: until the older stores have drained
    //  * I/O load: until it is the oldest instruction, older stores drained,
    //    nothing outstanding and no interrupt pending
    wire q_io_ok = rob_head_valid && (rob_head == qq_rob) && (oq_n == 3'd0) && !io_hold;
    wire qq_wait = ((qq_conf || qq_io) && qq_older != 4'd0) || (qq_io && !q_io_ok);
    // The registered wait may lag: when it says 'go' the conditions can only have
    // improved, except io_hold / outstanding requests, which are checked directly.
    wire ld_req  = qq_v && !qq_wait_r && !(qq_io && (io_hold || oq_n != 3'd0)) && !oq_full;
    wire ld_fire = ld_req && dreq_ready;
    wire q_free  = !qq_v || ld_fire;
    wire ld_mv   = a_ld && !mis && q_free;         // load leaves A into Q
    wire st_do   = a_v && a_st && (mis || !sq_full);
    wire a_go    = !a_v || st_do || (a_ld && (mis || q_free));   // A stage frees this cycle
    // store drain (committed entries only) when no load request is ready
    wire drain_req  = (!qq_v || qq_wait_r) && (sq_nc != 4'd0) && !oq_full;
    wire drain_fire = drain_req && dreq_ready;

    always @* begin
        dreq_valid = 1'b0; dreq_we = 1'b0; dreq_addr = 32'd0; dreq_wdata = 32'd0;
        dreq_wstrb = 4'd0; dreq_size = 2'd2;
        if (qq_v && !qq_wait_r) begin
            dreq_valid = ld_req; dreq_addr = qq_addr; dreq_size = qq_sz;
        end else if (drain_req) begin
            dreq_valid = 1'b1; dreq_we = 1'b1; dreq_addr = {sq_addr[sq_h], 2'b00};
            dreq_wdata = sq_data[sq_h]; dreq_wstrb = sq_strb[sq_h];
            dreq_size = (sq_strb[sq_h] == 4'b1111) ? 2'd2 :
                        (sq_strb[sq_h] == 4'b0011 || sq_strb[sq_h] == 4'b1100) ? 2'd1 : 2'd0;
            if (dreq_size == 2'd0)
                dreq_addr[1:0] = sq_strb[sq_h][1] ? 2'd1 : sq_strb[sq_h][2] ? 2'd2 :
                                 sq_strb[sq_h][3] ? 2'd3 : 2'd0;
            else if (dreq_size == 2'd1) dreq_addr[1:0] = sq_strb[sq_h][2] ? 2'd2 : 2'd0;
        end
    end

    // R moves to A when A frees
    wire r_go = r_v && a_go;
    wire s_go = head_rdy && (!r_v || r_go);
    wire [1:0] ins = {1'b0, m0_valid} + {1'b0, m1_valid};

    // ------------------------------------------------------------------ response
    wire [31:0] rsp_word = oq_fwd[oq_h] ? oq_fd[oq_h] : drsp_rdata;
    wire [1:0]  roff = oq_addr[oq_h][1:0];
    wire [31:0] rsh = rsp_word >> {roff, 3'b000};
    wire [31:0] lval = (oq_sz[oq_h] == 2'd0) ? {{24{rsh[7]  && !oq_uns[oq_h]}}, rsh[7:0]} :
                       (oq_sz[oq_h] == 2'd1) ? {{16{rsh[15] && !oq_uns[oq_h]}}, rsh[15:0]} : rsh;

    // The load-response valid fans out to every wakeup comparator in the
    // machine; it is built four times (same logic, kept apart) so each group
    // of consumers has its own driver: PRF / rename, IQ0, IQ1, LSU queue.
    wire wb_pre = oq_ld[oq_h] && !oq_kill[oq_h] && oq_wen[oq_h] && !flush;
    (* syn_keep = 1 *) wire wb_c0 = drsp_valid && !drsp_error && wb_pre;
    (* syn_keep = 1 *) wire wb_c1 = drsp_valid && !drsp_error && wb_pre;
    (* syn_keep = 1 *) wire wb_c2 = drsp_valid && !drsp_error && wb_pre;
    (* syn_keep = 1 *) wire wb_c3 = drsp_valid && !drsp_error && wb_pre;
    assign wb_valid = wb_c0;
    assign wb_v_q0  = wb_c1;
    assign wb_v_q1  = wb_c2;
    assign wb_v_lsu = wb_c3;
    assign wb_pdst  = oq_pd[oq_h];
    assign wb_data  = lval;

    always @(posedge clk) begin
        // default pulses
        ca_valid <= 1'b0; cr_valid <= 1'b0;
        // ---- data-path writes (no reset).  The payload is written into the
        // tail slots whenever they are free (decided from the registered count
        // only), whether or not an op is inserted this cycle: a free slot's
        // payload is don't-care, and the write enables then do not depend on the
        // late dispatch signals.  Port 1 is only used together with port 0.
        for (i = 0; i < QN; i = i + 1) begin
            if (qf0[i]) begin
                q_rob[i] <= m0_rob; q_pd[i] <= m0_pdst; q_p1[i] <= m0_p1; q_p2[i] <= m0_p2;
                q_wen[i] <= m0_wen; q_uns[i] <= m0_uns; q_sz[i] <= m0_size; q_imm[i] <= m0_imm;
            end else if (qf1[i]) begin
                q_rob[i] <= m1_rob; q_pd[i] <= m1_pdst; q_p1[i] <= m1_p1; q_p2[i] <= m1_p2;
                q_wen[i] <= m1_wen; q_uns[i] <= m1_uns; q_sz[i] <= m1_size; q_imm[i] <= m1_imm;
            end
        end
        if (s_go) begin
            r_rob <= g_rob; r_pd <= g_pd; r_p1 <= g_p1; r_p2 <= g_st ? g_p2 : 6'd0;
            r_wen <= g_wen; r_st <= g_st; r_uns <= g_uns; r_sz <= g_sz;
            r_imm <= g_imm;
        end
        if (r_go) begin
            a_rob <= r_rob; a_pd <= r_pd; a_wen <= r_wen; a_st <= r_st; a_uns <= r_uns;
            a_sz <= r_sz; a_imm <= r_imm;
            a_o1 <= rf_rd1; a_o2 <= rf_rd2;
            a_b1 <= {x1_wv && x1_pdst == r_p1 && r_p1 != 6'd0, x0_wv && x0_pdst == r_p1 && r_p1 != 6'd0};
            a_b2 <= {x1_wv && x1_pdst == r_p2 && r_p2 != 6'd0, x0_wv && x0_pdst == r_p2 && r_p2 != 6'd0};
        end else if (a_v) begin
            // A holds: freeze the operand values (bypass registers move on)
            a_o1 <= op1; a_o2 <= op2; a_b1 <= 2'b00; a_b2 <= 2'b00;
        end
        if (st_do && !mis) begin
            sq_addr[sq_t] <= addr[31:2]; sq_data[sq_t] <= sdata; sq_strb[sq_t] <= bmask;
            sq_io[sq_t] <= is_io;
        end
        if (ld_mv) begin
            qq_rob <= a_rob; qq_pd <= a_pd; qq_wen <= a_wen; qq_sz <= a_sz; qq_uns <= a_uns;
            qq_addr <= addr; qq_io <= is_io; qq_fwd <= ov_any && ov_full; qq_fd <= ov_data;
            qq_conf <= ov_any && !ov_full;
        end
        if (ld_fire || drain_fire) begin
            oq_rob[oq_t] <= qq_rob; oq_pd[oq_t] <= qq_pd; oq_wen[oq_t] <= qq_wen;
            oq_sz[oq_t] <= qq_sz; oq_addr[oq_t] <= qq_addr; oq_fd[oq_t] <= qq_fd;
        end
        // completion port A
        if (!flush && a_v && ((a_st && st_do) || (a_ld && mis))) begin
            ca_valid <= 1'b1; ca_rob <= a_rob; ca_exc <= mis;
            ca_cause <= a_st ? 5'd6 : 5'd4; ca_tval <= addr;
        end
        // response
        if (drsp_valid && oq_ld[oq_h] && !oq_kill[oq_h] && !flush) begin
            cr_valid <= 1'b1; cr_rob <= oq_rob[oq_h]; cr_exc <= drsp_error;
            cr_tval <= oq_addr[oq_h];
        end

        // ---- control state
        if (!resetn) begin
            qv <= {QN{1'b0}}; count <= 5'd0;
            qf0 <= {{(QN-1){1'b0}}, 1'b1}; qf1 <= {{(QN-2){1'b0}}, 2'b10};
            r_v <= 1'b0; a_v <= 1'b0; qq_v <= 1'b0;
            sq_h <= 3'd0; sq_c <= 3'd0; sq_t <= 3'd0; sq_n <= 4'd0; sq_nc <= 4'd0;
            oq_v <= 4'd0; oq_h <= 2'd0; oq_t <= 2'd0; oq_n <= 3'd0;
        end else begin
            // ---- outstanding queue
            if (ld_fire || drain_fire) begin
                oq_v[oq_t] <= 1'b1; oq_ld[oq_t] <= ld_fire; oq_kill[oq_t] <= 1'b0;
                oq_io[oq_t] <= ld_fire && qq_io; oq_fwd[oq_t] <= ld_fire && qq_fwd;
                oq_uns[oq_t] <= qq_uns;
                oq_t <= oq_t + 2'd1;
            end
            if (drsp_valid) begin
                oq_v[oq_h] <= 1'b0;
                oq_h <= oq_h + 2'd1;
            end
            oq_n <= oq_n + ((ld_fire || drain_fire) ? 3'd1 : 3'd0) - (drsp_valid ? 3'd1 : 3'd0);
            if (flush) begin
                for (i = 0; i < 4; i = i + 1) oq_kill[i] <= 1'b1;
                if (ld_fire) oq_kill[oq_t] <= 1'b1;
            end
            // ---- store queue
            if (drain_fire) sq_h <= sq_h + 3'd1;
            sq_c <= sq_c + {1'b0, st_commit};
            sq_nc <= sq_nc + {2'b0, st_commit} - (drain_fire ? 4'd1 : 4'd0);
            if (flush) begin
                // uncommitted stores disappear
                sq_t <= sq_c + {1'b0, st_commit};
                sq_n <= sq_nc + {2'b0, st_commit} - (drain_fire ? 4'd1 : 4'd0);
            end else begin
                if (st_do && !mis) sq_t <= sq_t + 3'd1;
                sq_n <= sq_n + ((st_do && !mis) ? 4'd1 : 4'd0) - (drain_fire ? 4'd1 : 4'd0);
            end
            // ---- issue queue / pipe
            // a new load starts waiting if it needs to (I/O loads always check once)
            if (ld_mv) qq_wait_r <= is_io || ((ov_any && !ov_full) && (sq_n - (drain_fire ? 4'd1 : 4'd0)) != 4'd0);
            else qq_wait_r <= qq_wait;
            if (ld_mv) qq_older <= sq_n - (drain_fire ? 4'd1 : 4'd0);
            else if (drain_fire && qq_older != 4'd0) qq_older <= qq_older - 4'd1;
            if (flush) qq_v <= 1'b0;
            else if (ld_mv) qq_v <= 1'b1;
            else if (ld_fire) qq_v <= 1'b0;
            if (flush) begin
                qv <= {QN{1'b0}}; count <= 5'd0; r_v <= 1'b0; a_v <= 1'b0;
                qf0 <= {{(QN-1){1'b0}}, 1'b1}; qf1 <= {{(QN-2){1'b0}}, 2'b10};
            end else begin
                qf0 <= q_nf0; qf1 <= q_nf1;
                for (i = 0; i < QN; i = i + 1) begin
                    if (qins0[i]) begin
                        qv[i] <= 1'b1; qst[i] <= m0_st;
                        qr1[i] <= m0_r1 || wk(m0_p1); qr2[i] <= m0_r2 || wk(m0_p2);
                        qold[i] <= qv & ~(s_go ? qgnt : {QN{1'b0}});
                        qblk[i] <= m0_st ? (|qv) : (|q_vs);
                    end else if (qins1[i]) begin
                        qv[i] <= 1'b1; qst[i] <= m1_st;
                        qr1[i] <= m1_r1 || wk(m1_p1); qr2[i] <= m1_r2 || wk(m1_p2);
                        qold[i] <= (qv & ~(s_go ? qgnt : {QN{1'b0}})) | qins0;
                        qblk[i] <= m1_st ? 1'b1 : ((|q_vs) || m0_st);
                    end else begin
                        if (s_go && qgnt[i]) qv[i] <= 1'b0;
                        if (wk(q_p1[i])) qr1[i] <= 1'b1;
                        if (wk(q_p2[i])) qr2[i] <= 1'b1;
                        qold[i] <= qold[i] & ~qins0 & ~qins1;
                        qblk[i] <= qst[i] ? (|(qold[i] & qv)) : (|(qold[i] & q_vs));
                    end
                end
                count <= count + {3'b0, ins} - (s_go ? 5'd1 : 5'd0);
                if (s_go) r_v <= 1'b1; else if (r_go) r_v <= 1'b0;
                if (r_go) a_v <= 1'b1; else if (a_go) a_v <= 1'b0;
            end
        end
    end
endmodule
