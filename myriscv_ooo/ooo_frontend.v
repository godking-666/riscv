// ============================================================================
// ooo_frontend  --  2-wide fetch with zero-bubble BTB prediction and RAS.
//
//  F0 : fetch PC register.  Each cycle a 64-bit aligned packet (2 instructions)
//       is requested; the BTB (two banks: even word / odd word) and RAS are
//       looked up from the same PC and the next PC is chosen in the same cycle,
//       so a correctly predicted taken branch costs no bubble.
//  F1 : TAGE direction prediction for the packet (ooo_tage) is ready.
//  R  : the instruction memory answers in order (any latency); the response is
//       registered.  Responses whose epoch is stale are dropped.
//  R2 : the registered packet is written into the IBUF.  For conditional
//       branches the TAGE direction and the decoded target replace the BTB's
//       fast guess; if the next fetch PC changes, the front end is redirected
//       (younger requests are killed by an epoch bump - a 2-cycle bubble that
//       the IBUF usually hides).
//  IBUF: 16-entry instruction queue, 2 writes / 2 reads per cycle.
//
//  The BTB and TAGE are trained at commit (in order, never by wrong-path
//  instructions).  The speculative path history is updated with the fast
//  prediction at F0, repaired at R2 overrides and at back-end redirects
//  (from the history snapshot of the redirecting instruction's packet).
// ============================================================================
`include "ooo_defs.vh"
module ooo_frontend #(
    parameter [31:0] RESET_PC  = 32'h4000_0000,
    parameter integer BTB_IB   = 6,           // index bits per bank (64 entries / bank)
    parameter integer BTB_TB   = 10           // partial tag bits
) (
    input  wire        clk,
    input  wire        resetn,
    // redirect (already prioritised by the core)
    input  wire        redirect_valid,
    input  wire [31:0] redirect_pc,
    input  wire        ras_fix_valid,         // restore RAS pointer with redirect
    input  wire [2:0]  ras_fix_ptr,
    input  wire        ras_fix_push,          // redirecting instruction is a call
    input  wire [31:0] ras_fix_push_addr,
    input  wire        hf_valid,              // repair the path history with the redirect
    input  wire [5:0]  hf_id,                 //   packet id of the redirecting instruction
    input  wire        hf_taken,              //   it is taken (shift in its history bit)
    input  wire        hf_hb,                 //   its history bit
    // instruction memory (64-bit, in-order responses)
    output wire        ireq_valid,
    output wire [31:0] ireq_addr,
    input  wire        ireq_ready,
    input  wire        irsp_valid,
    input  wire [63:0] irsp_data,
    input  wire        irsp_error,
    // instruction buffer head (two entries)
    output wire [1:0]  ib_cnt,                // 0,1,2 (saturated) entries visible
    output wire [31:0] ib0_inst, ib1_inst,
    output wire [31:0] ib0_pc,   ib1_pc,
    output wire        ib0_ptaken, ib1_ptaken,
    output wire [31:0] ib0_pnext, ib1_pnext,
    output wire        ib0_hit,  ib1_hit,
    output wire [1:0]  ib0_cnt,  ib1_cnt,
    output wire [2:0]  ib0_rasp, ib1_rasp,
    output wire        ib0_err,  ib1_err,
    output wire [7:0]  ib0_pd,   ib1_pd,      // predecoded class bits (see ooo_predecode)
    output wire [5:0]  ib0_pid,  ib1_pid,     // fetch-packet id (history snapshot)
    input  wire [1:0]  ib_pop,                // number of entries consumed this cycle
    // BTB training from commit
    input  wire        upd_valid,
    input  wire [31:0] upd_pc,
    input  wire        upd_taken,
    input  wire [31:0] upd_target,
    input  wire [1:0]  upd_type,
    input  wire        upd_call,
    input  wire        upd_hit,
    input  wire [1:0]  upd_cnt,
    // TAGE training from commit (conditional branches)
    input  wire        tu0_v,
    input  wire [31:0] tu0_pc,
    input  wire        tu0_t,
    input  wire [5:0]  tu0_id,
    input  wire        tu1_v,
    input  wire [31:0] tu1_pc,
    input  wire        tu1_t,
    input  wire [5:0]  tu1_id
);
    localparam integer NB = (1 << BTB_IB);

    // ------------------------------------------------------------------ BTB
    reg [NB-1:0]     b0_v, b1_v;
    reg [BTB_TB-1:0] b0_tag [0:NB-1];
    reg [BTB_TB-1:0] b1_tag [0:NB-1];
    reg [29:0]       b0_tgt [0:NB-1];
    reg [29:0]       b1_tgt [0:NB-1];
    reg [1:0]        b0_typ [0:NB-1];
    reg [1:0]        b1_typ [0:NB-1];
    reg              b0_call[0:NB-1];
    reg              b1_call[0:NB-1];
    reg [1:0]        b0_cnt [0:NB-1];
    reg [1:0]        b1_cnt [0:NB-1];

    // ------------------------------------------------------------------ RAS
    reg [29:0] ras [0:7];
    reg [2:0]  ras_ptr;                        // points to next free slot
    wire [29:0] ras_top = ras[ras_ptr - 3'd1];

    // ------------------------------------------------------------------ F0
    reg  [31:0] f_pc;
    reg  [2:0]  epoch;
    wire [BTB_IB-1:0] fidx = f_pc[3 +: BTB_IB];
    wire [BTB_TB-1:0] ftag = f_pc[3+BTB_IB +: BTB_TB];
    wire slot0_act = !f_pc[2];

    wire h0 = slot0_act && b0_v[fidx] && (b0_tag[fidx] == ftag);
    wire h1 = b1_v[fidx] && (b1_tag[fidx] == ftag);
    wire [1:0] ty0 = b0_typ[fidx], ty1 = b1_typ[fidx];
    wire [1:0] c0 = b0_cnt[fidx],  c1 = b1_cnt[fidx];
    wire t0 = h0 && (ty0 != `BT_COND || c0[1]);
    wire t1 = h1 && (ty1 != `BT_COND || c1[1]);
    wire [31:0] tg0 = (ty0 == `BT_RET) ? {ras_top, 2'b00} : {b0_tgt[fidx], 2'b00};
    wire [31:0] tg1 = (ty1 == `BT_RET) ? {ras_top, 2'b00} : {b1_tgt[fidx], 2'b00};
    wire [31:0] seq_pc = {f_pc[31:3] + 29'd1, 3'b000};
    wire [31:0] next_pc = t0 ? tg0 : (t1 ? tg1 : seq_pc);
    // RAS action of the predicted-taken slot
    wire act_call = t0 ? b0_call[fidx] : (t1 ? b1_call[fidx] : 1'b0);
    wire act_ret  = t0 ? (ty0 == `BT_RET) : (t1 ? (ty1 == `BT_RET) : 1'b0);
    wire [31:0] call_ret_addr = t0 ? {f_pc[31:3], 3'b100} : seq_pc;

    // ------------------------------------------------------------------ in-flight meta FIFO (4)
    reg  [2:0]  inflight;                      // number of outstanding requests
    reg  [1:0]  mq_wp, mq_rp;
    reg  [28:0] mq_pc   [0:3];
    reg         mq_s0   [0:3];                 // slot0 valid
    reg         mq_s1   [0:3];                 // slot1 valid
    reg  [2:0]  mq_ep   [0:3];
    reg         mq_t0   [0:3], mq_t1[0:3];
    reg  [31:0] mq_tg0  [0:3], mq_tg1[0:3];
    reg         mq_h0   [0:3], mq_h1[0:3];
    reg  [1:0]  mq_c0   [0:3], mq_c1[0:3];
    reg  [2:0]  mq_rp_s [0:3];
    reg  [63:0] mq_hist [0:3];                 // path history before the packet
    // TAGE result per in-flight packet (written one cycle after the request)
    reg         tq_d0   [0:3], tq_d1[0:3];

    // ------------------------------------------------------------------ IBUF (16)
    reg  [31:0] q_inst  [0:15];
    reg  [29:0] q_pc    [0:15];
    reg         q_pt    [0:15];
    reg  [29:0] q_pn    [0:15];
    reg         q_hit   [0:15];
    reg  [1:0]  q_cnt   [0:15];
    reg  [2:0]  q_rasp  [0:15];
    reg         q_err   [0:15];
    reg  [7:0]  q_pd    [0:15];
    reg  [5:0]  q_pid   [0:15];
    reg  [3:0]  q_head, q_tail;
    reg  [4:0]  q_count;

    // request when the buffer can absorb everything in flight plus this packet
    reg         rr_v;                          // R register holds a packet
    wire room = ({1'b0, q_count} + {2'b0, inflight, 1'b0} + {4'b0, rr_v, 1'b0} + 6'd2 <= 6'd16) &&
                (inflight < 3'd3);
    assign ireq_valid = resetn && room && !redirect_valid;
    assign ireq_addr  = {f_pc[31:3], 3'b000};
    wire req_fire = ireq_valid && ireq_ready;
    // same as req_fire without the (late) redirect term; used where a redirect
    // already has priority, or for data written without advancing a pointer
    wire req_go   = room && ireq_ready;

    // ------------------------------------------------------------------ path history / TAGE
    reg  [63:0] ghist;                         // speculative path history
    reg         p_v;                           // F1: a lookup was issued last cycle
    reg  [1:0]  p_idx;                         //     for this meta-FIFO slot
    reg  [5:0]  pkt_id;                        // id of the next accepted packet
    wire        tg_d0, tg_d1;
    wire [63:0] fx_hist;
    // history bit of a taken control transfer at pc
    function hbit; input [31:2] pc; hbit = pc[2] ^ pc[3] ^ pc[5]; endfunction

    // ------------------------------------------------------------------ R stage (response register)
    reg  [63:0] rr_data;
    reg         rr_err;
    reg  [1:0]  rr_idx;                        // meta-FIFO slot of the packet
    reg  [2:0]  rr_ep;
    reg         rr_c0, rr_c1;                  // slot is a conditional branch
    reg  [31:0] rr_bt0, rr_bt1;                // branch targets (pc + B-immediate)
    reg         rr_eq0, rr_eq1;                // decoded target == BTB target
    reg         rr_cl0, rr_cl1, rr_rt0, rr_rt1;  // slot is a call / return (RAS action on an override)
    function lnk; input [4:0] r; lnk = (r == 5'd1) || (r == 5'd5); endfunction
    function iscall; input [31:0] in;
        iscall = (in[6:0] == 7'b1101111 || (in[6:0] == 7'b1100111 && in[14:12] == 3'd0)) && lnk(in[11:7]);
    endfunction
    function isret; input [31:0] in;
        isret = in[6:0] == 7'b1100111 && in[14:12] == 3'd0 && lnk(in[19:15]) && in[11:7] == 5'd0 &&
                in[31:20] == 12'd0;
    endfunction
    function isbr; input [31:0] in; isbr = (in[6:0] == 7'b1100011); endfunction
    function [31:0] bimm; input [31:0] in; bimm = {{20{in[31]}}, in[7], in[30:25], in[11:8], 1'b0}; endfunction
    wire [31:0] cpc0 = {mq_pc[mq_rp], 3'b000};
    wire [31:0] cbt0 = cpc0 + bimm(irsp_data[31:0]);
    wire [31:0] cbt1 = {mq_pc[mq_rp], 3'b100} + bimm(irsp_data[63:32]);

    // ------------------------------------------------------------------ R2 : final prediction
    wire [28:0] r_pc = mq_pc[rr_idx];
    wire [31:0] rpc0 = {r_pc, 3'b000};
    wire [31:0] rpc1 = {r_pc, 3'b100};
    wire [31:0] rseq = {r_pc + 29'd1, 3'b000};
    wire        r_s0  = mq_s0[rr_idx];
    wire        f_t0  = mq_t0[rr_idx];                     // fast (BTB) decision
    wire        f_t1  = !f_t0 && mq_t1[rr_idx];
    // (a same-cycle back-end redirect has priority wherever r_ok is used: it
    //  resets the IBUF pointers and wins the PC / history / RAS muxes)
    wire        r_ok  = rr_v && (rr_ep == epoch);
    wire        d0 = rr_c0 ? tq_d0[rr_idx] : f_t0;
    wire        d1 = rr_c1 ? tq_d1[rr_idx] : mq_t1[rr_idx];
    wire        fin0 = r_s0 && d0;
    wire        fin1 = !fin0 && d1;
    wire [31:0] tgt0 = rr_c0 ? rr_bt0 : mq_tg0[rr_idx];
    wire [31:0] tgt1 = rr_c1 ? rr_bt1 : mq_tg1[rr_idx];
    wire        ovr = r_ok && ((fin0 != f_t0) || (fin1 != f_t1) ||
                               (fin0 && rr_c0 && !rr_eq0) || (fin1 && rr_c1 && !rr_eq1));
    wire [31:0] ovr_pc = fin0 ? tgt0 : (fin1 ? tgt1 : rseq);
    wire [63:0] r_hist = mq_hist[rr_idx];
    wire [63:0] ovr_hist = (fin0 || fin1) ? {r_hist[62:0], fin0 ? hbit(rpc0[31:2]) : hbit(rpc1[31:2])} : r_hist;
    // RAS action of the final taken slot (only a non-conditional slot can call / return)
    wire        o_call = fin0 ? rr_cl0 : (fin1 ? rr_cl1 : 1'b0);
    wire        o_ret  = fin0 ? rr_rt0 : (fin1 ? rr_rt1 : 1'b0);
    wire [2:0]  o_rp   = mq_rp_s[rr_idx];
    wire [31:0] o_raddr = fin0 ? rpc1 : rseq;
    wire w0 = r_ok && r_s0;
    wire w1 = r_ok && !fin0;

    // head outputs.  The read pointers are replicated (q_head drove ~560
    // loads): A copies select the decode-critical fields, B copies the rest;
    // n copies hold q_head + 1 so slot 1 needs no adder.
    (* syn_preserve = 1, syn_keep = 1 *) reg [3:0] q_hA, q_hB, q_nA, q_nB;
    assign ib_cnt     = (q_count >= 5'd2) ? 2'd2 : q_count[1:0];
    assign ib0_inst   = q_inst[q_hA];    assign ib1_inst  = q_inst[q_nA];
    assign ib0_err    = q_err[q_hA];     assign ib1_err   = q_err[q_nA];
    assign ib0_pd     = q_pd[q_hA];      assign ib1_pd    = q_pd[q_nA];
    assign ib0_pc     = {q_pc[q_hB], 2'b00}; assign ib1_pc = {q_pc[q_nB], 2'b00};
    assign ib0_ptaken = q_pt[q_hB];      assign ib1_ptaken = q_pt[q_nB];
    assign ib0_pnext  = {q_pn[q_hB], 2'b00}; assign ib1_pnext = {q_pn[q_nB], 2'b00};
    assign ib0_hit    = q_hit[q_hB];     assign ib1_hit   = q_hit[q_nB];
    assign ib0_cnt    = q_cnt[q_hB];     assign ib1_cnt   = q_cnt[q_nB];
    assign ib0_rasp   = q_rasp[q_hB];    assign ib1_rasp  = q_rasp[q_nB];
    assign ib0_pid    = q_pid[q_hB];     assign ib1_pid   = q_pid[q_nB];
    always @(posedge clk) begin
        if (!resetn || redirect_valid) begin
            q_hA <= 4'd0; q_hB <= 4'd0; q_nA <= 4'd1; q_nB <= 4'd1;
        end else begin
            q_hA <= q_hA + {2'd0, ib_pop}; q_hB <= q_hB + {2'd0, ib_pop};
            q_nA <= q_nA + {2'd0, ib_pop}; q_nB <= q_nB + {2'd0, ib_pop};
        end
    end
    wire [7:0] pd_lo, pd_hi;
    ooo_predecode u_pd0 (.inst(rr_data[31:0]),  .pd(pd_lo));
    ooo_predecode u_pd1 (.inst(rr_data[63:32]), .pd(pd_hi));

    ooo_tage u_tage (
        .clk(clk), .resetn(resetn),
        .lk_pc(f_pc[31:3]), .lk_hist(ghist), .pr_d0(tg_d0), .pr_d1(tg_d1),
        .sn_we(r_ok), .sn_id(pkt_id), .sn_hist(r_hist), .fx_id(hf_id), .fx_hist(fx_hist),
        .up0_v(tu0_v), .up0_pc(tu0_pc[31:2]), .up0_t(tu0_t), .up0_id(tu0_id),
        .up1_v(tu1_v), .up1_pc(tu1_pc[31:2]), .up1_t(tu1_t), .up1_id(tu1_id));

    // ------------------------------------------------------------------ sequential
    integer i;
    wire [3:0] wp0 = q_tail;
    wire [3:0] wp1 = q_tail + (w0 ? 4'd1 : 4'd0);
    always @(posedge clk) begin
        // ---- IBUF data writes (no reset needed)
        if (w0) begin
            q_inst[wp0] <= rr_data[31:0];    q_pc[wp0] <= rpc0[31:2];
            q_pt[wp0]   <= fin0;
            q_pn[wp0]   <= fin0 ? tgt0[31:2] : rpc1[31:2];
            q_hit[wp0]  <= mq_h0[rr_idx];    q_cnt[wp0] <= mq_c0[rr_idx];
            q_rasp[wp0] <= o_rp;             q_err[wp0] <= rr_err;   q_pd[wp0] <= pd_lo;
            q_pid[wp0]  <= pkt_id;
        end
        if (w1) begin
            q_inst[wp1] <= rr_data[63:32];   q_pc[wp1] <= rpc1[31:2];
            q_pt[wp1]   <= fin1;
            q_pn[wp1]   <= fin1 ? tgt1[31:2] : rseq[31:2];
            q_hit[wp1]  <= mq_h1[rr_idx];    q_cnt[wp1] <= mq_c1[rr_idx];
            q_rasp[wp1] <= o_rp;             q_err[wp1] <= rr_err;   q_pd[wp1] <= pd_hi;
            q_pid[wp1]  <= pkt_id;
        end
        // ---- R register (data part)
        if (irsp_valid) begin
            rr_data <= irsp_data; rr_err <= irsp_error; rr_idx <= mq_rp; rr_ep <= mq_ep[mq_rp];
            rr_c0 <= mq_s0[mq_rp] && !irsp_error && isbr(irsp_data[31:0]);
            rr_c1 <= !irsp_error && isbr(irsp_data[63:32]);
            rr_bt0 <= cbt0; rr_bt1 <= cbt1;
            rr_cl0 <= iscall(irsp_data[31:0]);  rr_cl1 <= iscall(irsp_data[63:32]);
            rr_rt0 <= isret(irsp_data[31:0]);   rr_rt1 <= isret(irsp_data[63:32]);
            rr_eq0 <= (cbt0[31:2] == mq_tg0[mq_rp][31:2]);
            rr_eq1 <= (cbt1[31:2] == mq_tg1[mq_rp][31:2]);
        end
        // ---- TAGE result for the packet requested last cycle
        if (p_v) begin tq_d0[p_idx] <= tg_d0; tq_d1[p_idx] <= tg_d1; end
        p_idx <= mq_wp;
        // ---- meta FIFO writes (data only; the pointer advances on req_fire)
        if (req_go) begin
            mq_pc[mq_wp] <= f_pc[31:3];
            mq_s0[mq_wp] <= slot0_act;
            mq_s1[mq_wp] <= !t0;
            mq_ep[mq_wp] <= epoch;
            mq_t0[mq_wp] <= t0;  mq_t1[mq_wp] <= t1;
            mq_tg0[mq_wp] <= tg0; mq_tg1[mq_wp] <= tg1;
            mq_h0[mq_wp] <= h0;  mq_h1[mq_wp] <= h1;
            mq_c0[mq_wp] <= c0;  mq_c1[mq_wp] <= c1;
            mq_rp_s[mq_wp] <= ras_ptr;
            mq_hist[mq_wp] <= ghist;
        end
        // ---- RAS data
        if (redirect_valid) begin
            if (ras_fix_valid && ras_fix_push) ras[ras_fix_ptr] <= ras_fix_push_addr[31:2];
        end else if (ovr) begin
            if (o_call) ras[o_rp] <= o_raddr[31:2];
        end else if (req_go && act_call) begin
            ras[ras_ptr] <= call_ret_addr[31:2];
        end
        // ---- BTB training (single write port, bank by pc[2])
        if (upd_valid && (upd_taken || (upd_hit && upd_type == `BT_COND))) begin
            if (!upd_pc[2]) begin
                b0_tag[upd_pc[3 +: BTB_IB]] <= upd_pc[3+BTB_IB +: BTB_TB];
                b0_tgt[upd_pc[3 +: BTB_IB]] <= upd_target[31:2];
                b0_typ[upd_pc[3 +: BTB_IB]] <= upd_type;
                b0_call[upd_pc[3 +: BTB_IB]] <= upd_call;
                b0_cnt[upd_pc[3 +: BTB_IB]] <= btb_newcnt(upd_hit, upd_cnt, upd_taken);
            end else begin
                b1_tag[upd_pc[3 +: BTB_IB]] <= upd_pc[3+BTB_IB +: BTB_TB];
                b1_tgt[upd_pc[3 +: BTB_IB]] <= upd_target[31:2];
                b1_typ[upd_pc[3 +: BTB_IB]] <= upd_type;
                b1_call[upd_pc[3 +: BTB_IB]] <= upd_call;
                b1_cnt[upd_pc[3 +: BTB_IB]] <= btb_newcnt(upd_hit, upd_cnt, upd_taken);
            end
        end

        if (!resetn) begin
            f_pc <= RESET_PC; epoch <= 3'd0; inflight <= 3'd0; mq_wp <= 2'd0; mq_rp <= 2'd0;
            q_head <= 4'd0; q_tail <= 4'd0; q_count <= 5'd0; ras_ptr <= 3'd0;
            ghist <= 64'd0; p_v <= 1'b0; pkt_id <= 6'd0; rr_v <= 1'b0;
            b0_v <= {NB{1'b0}}; b1_v <= {NB{1'b0}};
        end else begin
            // in-flight accounting
            if (req_fire) mq_wp <= mq_wp + 2'd1;
            if (irsp_valid) mq_rp <= mq_rp + 2'd1;
            inflight <= inflight + (req_fire ? 3'd1 : 3'd0) - (irsp_valid ? 3'd1 : 3'd0);
            rr_v   <= irsp_valid && (mq_ep[mq_rp] == epoch) && !redirect_valid && !ovr;
            p_v    <= req_fire;
            if (r_ok) pkt_id <= pkt_id + 6'd1;
            // PC / epoch / RAS pointer / path history
            if (redirect_valid) begin
                f_pc  <= redirect_pc;
                epoch <= epoch + 3'd1;
                if (ras_fix_valid) ras_ptr <= ras_fix_ptr + (ras_fix_push ? 3'd1 : 3'd0);
                if (hf_valid) ghist <= hf_taken ? {fx_hist[62:0], hf_hb} : fx_hist;
            end else if (ovr) begin
                f_pc  <= ovr_pc;
                epoch <= epoch + 3'd1;
                ras_ptr <= o_rp + (o_call ? 3'd1 : 3'd0) - (o_ret ? 3'd1 : 3'd0);
                ghist <= ovr_hist;
            end else if (req_go) begin
                f_pc <= next_pc;
                if (act_call) ras_ptr <= ras_ptr + 3'd1;
                else if (act_ret) ras_ptr <= ras_ptr - 3'd1;
                if (t0 || t1) ghist <= {ghist[62:0], f_pc[3] ^ f_pc[5] ^ !t0};
            end
            // IBUF pointers
            if (redirect_valid) begin
                q_head <= 4'd0; q_tail <= 4'd0; q_count <= 5'd0;
            end else begin
                q_tail  <= q_tail + {3'd0, w0} + {3'd0, w1};
                q_head  <= q_head + {2'd0, ib_pop};
                q_count <= q_count + {4'd0, w0} + {4'd0, w1} - {3'd0, ib_pop};
            end
            // BTB valid bits
            if (upd_valid && (upd_taken || (upd_hit && upd_type == `BT_COND))) begin
                if (!upd_pc[2]) b0_v[upd_pc[3 +: BTB_IB]] <= 1'b1;
                else            b1_v[upd_pc[3 +: BTB_IB]] <= 1'b1;
            end
        end
    end

    function [1:0] btb_newcnt;
        input hit; input [1:0] c; input taken;
        begin
            if (!hit) btb_newcnt = 2'b10;
            else if (taken) btb_newcnt = (c == 2'b11) ? 2'b11 : c + 2'd1;
            else btb_newcnt = (c == 2'b00) ? 2'b00 : c - 2'd1;
        end
    endfunction
endmodule

// ----------------------------------------------------------------------------
// ooo_predecode -- class bits computed when an instruction enters the IBUF, so
// the rename stage's dispatch decision does not wait for the full decoder.
//  [0] exc (illegal / bad CSR / ecall / ebreak)  [1] serial  [2] ctrl  [3] mem
//  [4] mul  [5] csr  [6] no-issue (exc or non-CSR system op)  [7] plain ALU
// ----------------------------------------------------------------------------
module ooo_predecode (input wire [31:0] inst, output wire [7:0] pd);
    wire [4:0] rs1, rs2, rd; wire use1, use2, wen, s1pc, s2imm, br, jal, jalr, call, ret;
    wire mul, ld, st, uns, csri, ill; wire [3:0] aop; wire [31:0] imm; wire [1:0] mop, msz, csrop;
    wire [2:0] sys;
    ooo_decode u_d (.inst(inst), .rs1(rs1), .rs2(rs2), .rd(rd), .use1(use1), .use2(use2), .wen(wen),
        .alu_op(aop), .src1_pc(s1pc), .src2_imm(s2imm), .imm(imm), .is_br(br), .is_jal(jal),
        .is_jalr(jalr), .is_call(call), .is_ret(ret), .is_mul(mul), .mul_op(mop), .is_load(ld),
        .is_store(st), .mem_size(msz), .mem_unsigned(uns), .sys_op(sys), .csr_op(csrop),
        .csr_imm(csri), .illegal(ill));
    reg csrbad;
    wire wi = (csrop == 2'd1) || (inst[19:15] != 5'd0);
    always @* begin
        case (inst[31:20])
        12'h300, 12'h301, 12'h304, 12'h305, 12'h310, 12'h340, 12'h341, 12'h342, 12'h343, 12'h344:
            csrbad = 1'b0;
        12'hf11, 12'hf12, 12'hf13, 12'hf14, 12'hf15: csrbad = wi;
        default: csrbad = 1'b1;
        endcase
    end
    wire exc = ill || (sys == `SYS_CSR && csrbad) || sys == `SYS_ECALL || sys == `SYS_EBREAK;
    wire ctrl = !exc && (br || jal || jalr);
    wire mem  = !exc && (ld || st);
    wire isml = !exc && mul;
    wire csr  = !exc && sys == `SYS_CSR;
    wire none = exc || (sys != `SYS_NONE && sys != `SYS_CSR);
    wire alu  = !none && !ctrl && !mem && !isml && !csr;
    assign pd = {alu, none, csr, isml, mem, ctrl, !exc && sys != `SYS_NONE, exc};
endmodule
