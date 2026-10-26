// ============================================================================
// ooo_core  --  2-wide out-of-order RV32IM(Zmmul)+Zicsr core
//
// Pipeline (one line = one clock):
//   F0   PC + BTB/RAS prediction, 64-bit fetch request        (ooo_frontend)
//   F1   instruction memory response -> 16-entry IBUF
//   DR   decode x2, rename x2 (RAT/free list), ROB allocate, resource check
//   DS   dispatch: ROB fields, issue-queue / LSU insert, ready bits
//   S    select  (IQ0, IQ1: oldest ready; LSU: in order)    -- ALU wakeup here
//   R    PRF read (6 ports) + bypass select
//   X    ALU0+branch | ALU1 / MUL stage 1 | AGU + store-queue check + D request
//   BR   branch outcome registered: redirect / ROB completion
//   (MUL X2, X3)  (load response)
//   C    commit up to 2 in order; exceptions / interrupts / CSR at commit
//
// Recovery: a mispredicted branch redirects the front end immediately (BR
// stage) and blocks rename; when the branch reaches commit the whole back end
// is flushed and the speculative RAT is restored from the committed RAT.
// Exceptions, interrupts and MRET use the same flush plus a front-end redirect.
// ============================================================================
`include "ooo_defs.vh"
module ooo_core #(
    parameter [31:0] RESET_PC  = 32'h4000_0000,
    parameter [31:0] MTVEC_RST = 32'h0000_0100,
    parameter [31:0] ORD0_BASE = 32'h4000_0000, parameter [31:0] ORD0_MASK = 32'he000_0000,
    parameter [31:0] ORD1_BASE = 32'h0000_0000, parameter [31:0] ORD1_MASK = 32'hfff0_0000
) (
    input  wire        clk,
    input  wire        resetn,
    input  wire        irq_external, irq_software, irq_timer,
    // instruction memory: 64-bit, read-only, in-order responses
    output wire        ireq_valid,
    output wire [31:0] ireq_addr,
    input  wire        ireq_ready,
    input  wire        irsp_valid,
    input  wire [63:0] irsp_data,
    input  wire        irsp_error,
    // data memory: 32-bit, every request gets one in-order response
    output wire        dreq_valid,
    output wire        dreq_we,
    output wire [31:0] dreq_addr,
    output wire [31:0] dreq_wdata,
    output wire [3:0]  dreq_wstrb,
    output wire [1:0]  dreq_size,
    input  wire        dreq_ready,
    input  wire        drsp_valid,
    input  wire [31:0] drsp_rdata,
    input  wire        drsp_error,
    // cache maintenance for FENCE.I: clean D-cache + invalidate I-cache
    output wire        cmo_req,
    input  wire        cmo_done,
    // commit trace (slot 0 / slot 1)
    output wire [1:0]  dbg_cvalid,
    output wire [31:0] dbg_c0_pc, dbg_c1_pc,
    output wire        dbg_c0_wen, dbg_c1_wen,
    output wire [4:0]  dbg_c0_rd, dbg_c1_rd,
    output wire [5:0]  dbg_c0_pdst, dbg_c1_pdst,
    output wire        dbg_trap,
    // performance events
    output wire [7:0]  perf_ev
);
    reg irq_req;   // [sim] 声明上移（原在 L632，L542 已使用）
    // ======================================================================
    // global control wires
    // ======================================================================
    reg         flush_r;            // flush the back end this cycle
    reg         flush_fe;           // ... and redirect the front end
    reg  [31:0] flush_tgt;
    wire        flush = flush_r;

    // ======================================================================
    // front end
    // ======================================================================
    wire [1:0]  ib_cnt;
    wire [31:0] ib0_inst, ib1_inst, ib0_pc, ib1_pc, ib0_pnext, ib1_pnext;
    wire        ib0_ptaken, ib1_ptaken, ib0_hit, ib1_hit, ib0_err, ib1_err;
    wire [1:0]  ib0_cnt, ib1_cnt;
    wire [2:0]  ib0_rasp, ib1_rasp;
    wire [7:0]  ib0_pd, ib1_pd;
    wire [5:0]  ib0_pid, ib1_pid;
    reg  [1:0]  ib_pop;

    reg         fe_redir;
    reg  [31:0] fe_redir_pc;
    reg         fe_ras_fix, fe_ras_push;
    reg  [2:0]  fe_ras_ptr;
    reg  [31:0] fe_ras_addr;
    reg         fe_hf_v, fe_hf_t, fe_hf_hb;    // path-history repair for the redirect
    reg  [5:0]  fe_hf_id;
    reg         tu0_v, tu1_v, tu0_t, tu1_t;    // TAGE training (registered, from commit)
    reg  [31:0] tu0_pc, tu1_pc;
    reg  [5:0]  tu0_id, tu1_id;

    reg         btb_upd;              // registered training request (one cycle after commit)
    reg  [31:0] btb_upd_pc, btb_upd_tgt;
    reg         btb_upd_taken, btb_upd_call, btb_upd_hit;
    reg  [1:0]  btb_upd_type, btb_upd_cnt;

    ooo_frontend #(.RESET_PC(RESET_PC)) u_fe (
        .clk(clk), .resetn(resetn),
        .redirect_valid(fe_redir), .redirect_pc(fe_redir_pc),
        .ras_fix_valid(fe_ras_fix), .ras_fix_ptr(fe_ras_ptr),
        .ras_fix_push(fe_ras_push), .ras_fix_push_addr(fe_ras_addr),
        .hf_valid(fe_hf_v), .hf_id(fe_hf_id), .hf_taken(fe_hf_t), .hf_hb(fe_hf_hb),
        .ib0_pid(ib0_pid), .ib1_pid(ib1_pid),
        .tu0_v(tu0_v), .tu0_pc(tu0_pc), .tu0_t(tu0_t), .tu0_id(tu0_id),
        .tu1_v(tu1_v), .tu1_pc(tu1_pc), .tu1_t(tu1_t), .tu1_id(tu1_id),
        .ireq_valid(ireq_valid), .ireq_addr(ireq_addr), .ireq_ready(ireq_ready),
        .irsp_valid(irsp_valid), .irsp_data(irsp_data), .irsp_error(irsp_error),
        .ib_cnt(ib_cnt), .ib0_inst(ib0_inst), .ib1_inst(ib1_inst), .ib0_pc(ib0_pc), .ib1_pc(ib1_pc),
        .ib0_ptaken(ib0_ptaken), .ib1_ptaken(ib1_ptaken), .ib0_pnext(ib0_pnext), .ib1_pnext(ib1_pnext),
        .ib0_hit(ib0_hit), .ib1_hit(ib1_hit), .ib0_cnt(ib0_cnt), .ib1_cnt(ib1_cnt),
        .ib0_rasp(ib0_rasp), .ib1_rasp(ib1_rasp), .ib0_err(ib0_err), .ib1_err(ib1_err), .ib0_pd(ib0_pd), .ib1_pd(ib1_pd),
        .ib_pop(ib_pop),
        .upd_valid(btb_upd), .upd_pc(btb_upd_pc), .upd_taken(btb_upd_taken), .upd_target(btb_upd_tgt),
        .upd_type(btb_upd_type), .upd_call(btb_upd_call), .upd_hit(btb_upd_hit), .upd_cnt(btb_upd_cnt));

    // ======================================================================
    // DR : decode
    // ======================================================================
    wire [4:0]  d0_rs1, d0_rs2, d0_rd, d1_rs1, d1_rs2, d1_rd;
    wire        d0_use1, d0_use2, d0_wen, d1_use1, d1_use2, d1_wen;
    wire [3:0]  d0_aop, d1_aop;
    wire        d0_s1pc, d0_s2imm, d1_s1pc, d1_s2imm;
    wire [31:0] d0_imm, d1_imm;
    wire        d0_br, d0_jal, d0_jalr, d0_call, d0_ret, d1_br, d1_jal, d1_jalr, d1_call, d1_ret;
    wire        d0_mul, d1_mul, d0_ld, d1_ld, d0_st, d1_st, d0_uns, d1_uns, d0_csri, d1_csri;
    wire [1:0]  d0_mop, d1_mop, d0_msz, d1_msz, d0_csrop, d1_csrop;
    wire [2:0]  d0_sys, d1_sys;
    wire        d0_ill, d1_ill;

    ooo_decode u_dec0 (.inst(ib0_inst), .rs1(d0_rs1), .rs2(d0_rs2), .rd(d0_rd), .use1(d0_use1), .use2(d0_use2),
        .wen(d0_wen), .alu_op(d0_aop), .src1_pc(d0_s1pc), .src2_imm(d0_s2imm), .imm(d0_imm),
        .is_br(d0_br), .is_jal(d0_jal), .is_jalr(d0_jalr), .is_call(d0_call), .is_ret(d0_ret),
        .is_mul(d0_mul), .mul_op(d0_mop), .is_load(d0_ld), .is_store(d0_st), .mem_size(d0_msz),
        .mem_unsigned(d0_uns), .sys_op(d0_sys), .csr_op(d0_csrop), .csr_imm(d0_csri), .illegal(d0_ill));
    ooo_decode u_dec1 (.inst(ib1_inst), .rs1(d1_rs1), .rs2(d1_rs2), .rd(d1_rd), .use1(d1_use1), .use2(d1_use2),
        .wen(d1_wen), .alu_op(d1_aop), .src1_pc(d1_s1pc), .src2_imm(d1_s2imm), .imm(d1_imm),
        .is_br(d1_br), .is_jal(d1_jal), .is_jalr(d1_jalr), .is_call(d1_call), .is_ret(d1_ret),
        .is_mul(d1_mul), .mul_op(d1_mop), .is_load(d1_ld), .is_store(d1_st), .mem_size(d1_msz),
        .mem_unsigned(d1_uns), .sys_op(d1_sys), .csr_op(d1_csrop), .csr_imm(d1_csri), .illegal(d1_ill));

    // exceptions detected at decode (fetch fault has priority)
    // CSR address legality (mirrors csr_file): implemented set, read-only info CSRs
    function csr_bad;
        input [11:0] a; input wi;
        begin
            case (a)
            12'h300, 12'h301, 12'h304, 12'h305, 12'h310, 12'h340, 12'h341, 12'h342, 12'h343, 12'h344:
                csr_bad = 1'b0;
            12'hf11, 12'hf12, 12'hf13, 12'hf14, 12'hf15: csr_bad = wi;
            default: csr_bad = 1'b1;
            endcase
        end
    endfunction
    wire d0_csrbad = d0_sys == `SYS_CSR && csr_bad(ib0_inst[31:20], d0_csrop == 2'd1 || ib0_inst[19:15] != 5'd0);
    wire d1_csrbad = d1_sys == `SYS_CSR && csr_bad(ib1_inst[31:20], d1_csrop == 2'd1 || ib1_inst[19:15] != 5'd0);
    // exception flag from the predecode bits (computed when the instruction
    // entered the IBUF: illegal / bad CSR / ECALL / EBREAK); the full decoder
    // is only needed for the cause code, which is not timing critical
    wire        e0_exc = ib0_err || ib0_pd[0];
    wire        e1_exc = ib1_err || ib1_pd[0];
    wire [4:0]  e0_cause = ib0_err ? `EXC_IFAULT : (d0_ill || d0_csrbad) ? `EXC_ILLEGAL :
                           (d0_sys == `SYS_ECALL) ? `EXC_ECALL : `EXC_BREAK;
    wire [4:0]  e1_cause = ib1_err ? `EXC_IFAULT : (d1_ill || d1_csrbad) ? `EXC_ILLEGAL :
                           (d1_sys == `SYS_ECALL) ? `EXC_ECALL : `EXC_BREAK;
    // dispatch-relevant class bits come from the IBUF predecode (fast path);
    // the full decode above only feeds DS registers.
    wire u0_wen = d0_wen && !e0_exc, u1_wen = d1_wen && !e1_exc;
    wire u0_serial = !ib0_err && ib0_pd[1], u1_serial = !ib1_err && ib1_pd[1];
    wire u0_ctrl = !ib0_err && ib0_pd[2],   u1_ctrl = !ib1_err && ib1_pd[2];
    wire u0_mem  = !ib0_err && ib0_pd[3],   u1_mem  = !ib1_err && ib1_pd[3];
    wire u0_mul  = !ib0_err && ib0_pd[4],   u1_mul  = !ib1_err && ib1_pd[4];
    wire u0_csr  = !ib0_err && ib0_pd[5],   u1_csr  = !ib1_err && ib1_pd[5];
    wire u0_none = ib0_err || ib0_pd[6],    u1_none = ib1_err || ib1_pd[6];
    wire u0_alu  = !ib0_err && ib0_pd[7],   u1_alu  = !ib1_err && ib1_pd[7];


    // ======================================================================
    // rename state
    // ======================================================================
    reg  [5:0]  rat  [0:31];         // speculative map
    reg  [5:0]  crat [0:31];         // committed map
    reg  [5:0]  fl   [0:31];         // free list (circular)
    reg  [5:0]  fl_h, fl_t, fl_ch;   // head, tail, committed head (6-bit with wrap)
    reg  [4:0]  fl_t1;               // fl_t + 1 (low bits)
    wire [5:0]  fl_n = fl_t - fl_h;
    reg  [63:0] prdy;                // physical register ready (value available/soon)

    // ROB pointers
    reg  [4:0]  rob_h, rob_t;
    reg  [5:0]  rob_n;
    wire        rob_empty = (rob_n == 6'd0);

    // DS stage registers (declared early: resource reservation needs them)
    reg         ds_v0, ds_v1;
    reg  [1:0]  ds_rt0, ds_rt1;

    // issue-queue occupancy
    wire [3:0]  iq0_cnt, iq1_cnt;
    wire [4:0]  iqm_cnt;               // memory queue: 16 entries

    reg         rn_block;            // a mispredicted branch is waiting for commit
    reg  [4:0]  pend_rob;
    reg         serial_pend;         // a serialising instruction is in flight
    reg         dec_redir_r;         // decode-time redirect issued last cycle
    reg  [31:0] dec_redir_pc;
    reg         dec_ras_push, dec_ras_ret;
    reg  [2:0]  dec_ras_ptr;
    reg  [31:0] dec_ras_addr;
    reg  [5:0]  dec_pid;                 // history repair for the decode redirect
    reg         dec_tk, dec_hb;

    // ---------------- routing of ALU ops between the two ALU lanes
    // ALU ops: slot 0 goes to the emptier lane (registered), slot 1 to the other
    reg  pref1;
    reg  [1:0] rt0, rt1;
    always @* begin
        if (u0_none)                 rt0 = `RT_NONE;
        else if (u0_mem)             rt0 = `RT_IQM;
        else if (u0_ctrl || u0_csr)  rt0 = `RT_IQ0;
        else if (u0_mul)             rt0 = `RT_IQ1;
        else                         rt0 = pref1 ? `RT_IQ1 : `RT_IQ0;
        if (u1_none)                 rt1 = `RT_NONE;
        else if (u1_mem)             rt1 = `RT_IQM;
        else if (u1_ctrl || u1_csr)  rt1 = `RT_IQ0;
        else if (u1_mul)             rt1 = `RT_IQ1;
        else                         rt1 = pref1 ? `RT_IQ0 : `RT_IQ1;
    end


    // ---------------- resource check (registered counts, minus DS in flight)
    wire [3:0] ds_q0 = (ds_v0 && ds_rt0 == `RT_IQ0 ? 4'd1 : 4'd0) + (ds_v1 && ds_rt1 == `RT_IQ0 ? 4'd1 : 4'd0);
    wire [3:0] ds_q1 = (ds_v0 && ds_rt0 == `RT_IQ1 ? 4'd1 : 4'd0) + (ds_v1 && ds_rt1 == `RT_IQ1 ? 4'd1 : 4'd0);
    wire [3:0] ds_qm = (ds_v0 && ds_rt0 == `RT_IQM ? 4'd1 : 4'd0) + (ds_v1 && ds_rt1 == `RT_IQM ? 4'd1 : 4'd0);
    always @(posedge clk) pref1 <= (iq1_cnt + ds_q1 < iq0_cnt + ds_q0);
    wire [4:0] free0 = 5'd8 - iq0_cnt - ds_q0;
    wire [4:0] free1 = 5'd8 - iq1_cnt - ds_q1;
    wire [4:0] freem = 5'd16 - iqm_cnt - {1'b0, ds_qm};
    wire [1:0] n0_q0 = (rt0 == `RT_IQ0) ? 2'd1 : 2'd0, n1_q0 = (rt1 == `RT_IQ0) ? 2'd1 : 2'd0;
    wire [1:0] n0_q1 = (rt0 == `RT_IQ1) ? 2'd1 : 2'd0, n1_q1 = (rt1 == `RT_IQ1) ? 2'd1 : 2'd0;
    wire [1:0] n0_qm = (rt0 == `RT_IQM) ? 2'd1 : 2'd0, n1_qm = (rt1 == `RT_IQM) ? 2'd1 : 2'd0;
    // capacity flags depend on registers only, so they are ready early in the
    // cycle; the late decode/routing signals only pass through a small mux.
    wire c0_1 = (free0 >= 5'd1), c0_2 = (free0 >= 5'd2);
    wire c1_1 = (free1 >= 5'd1), c1_2 = (free1 >= 5'd2);
    wire cm_1 = (freem >= 5'd1), cm_2 = (freem >= 5'd2);
    wire base1 = (rob_n <= 6'd31) && (fl_n >= 6'd1);
    wire base2 = (rob_n <= 6'd30) && (fl_n >= 6'd2);
    wire fit0 = base1 && (rt0 != `RT_IQ0 || c0_1) && (rt0 != `RT_IQ1 || c1_1) && (rt0 != `RT_IQM || cm_1);
    wire both_q0 = (rt0 == `RT_IQ0) && (rt1 == `RT_IQ0), any_q0 = (rt0 == `RT_IQ0) || (rt1 == `RT_IQ0);
    wire both_q1 = (rt0 == `RT_IQ1) && (rt1 == `RT_IQ1), any_q1 = (rt0 == `RT_IQ1) || (rt1 == `RT_IQ1);
    wire both_qm = (rt0 == `RT_IQM) && (rt1 == `RT_IQM), any_qm = (rt0 == `RT_IQM) || (rt1 == `RT_IQM);
    wire fit2 = base2 && (both_q0 ? c0_2 : (!any_q0 || c0_1)) && (both_q1 ? c1_2 : (!any_q1 || c1_1)) &&
                (both_qm ? cm_2 : (!any_qm || cm_1));
    // registered terms only; a same-cycle branch redirect lets DR take wrong-path
    // instructions, which are discarded when the branch flushes at commit.
    wire dr_block = rn_block || serial_pend || flush_r || dec_redir_r;
    wire take0 = (ib_cnt != 2'd0) && !dr_block && fit0 &&
                 (!u0_serial || (rob_empty && !ds_v0 && !ds_v1));
    wire take1 = take0 && (ib_cnt == 2'd2) && !u0_serial && !u1_serial && fit2;
    always @* ib_pop = take1 ? 2'd2 : (take0 ? 2'd1 : 2'd0);

    // ---------------- rename (with intra-group bypass)
    wire [5:0] new0 = fl[fl_h[4:0]];
    wire [5:0] new1 = u0_wen ? fl[fl_h[4:0] + 5'd1] : fl[fl_h[4:0]];
    wire [5:0] rn0_p1 = rat[d0_rs1], rn0_p2 = rat[d0_rs2], r0_old = rat[d0_rd];
    wire       b1_1 = u0_wen && d1_rs1 == d0_rd, b1_2 = u0_wen && d1_rs2 == d0_rd, b1_o = u0_wen && d1_rd == d0_rd;
    wire [5:0] rn1_p1 = b1_1 ? new0 : rat[d1_rs1];
    wire [5:0] rn1_p2 = b1_2 ? new0 : rat[d1_rs2];
    wire [5:0] r1_old = b1_o ? new0 : rat[d1_rd];
    wire       alloc0 = take0 && u0_wen, alloc1 = take1 && u1_wen;

    // DS stage payload
    reg  [4:0]  ds_rob0, ds_rob1;
    reg  [5:0]  ds_pd0, ds_pd1, ds_p10, ds_p11, ds_p20, ds_p21, ds_old0, ds_old1;
    reg         ds_wen0, ds_wen1;
    reg  [4:0]  ds_rd0, ds_rd1;
    reg  [31:0] ds_pc0, ds_pc1, ds_imm0, ds_imm1, ds_pn0, ds_pn1;
    reg  [3:0]  ds_aop0, ds_aop1;
    reg         ds_s1pc0, ds_s1pc1, ds_s2imm0, ds_s2imm1;
    reg         ds_br0, ds_br1, ds_jal0, ds_jal1, ds_jalr0, ds_jalr1, ds_call0, ds_call1, ds_ret0, ds_ret1;
    reg  [2:0]  ds_f30, ds_f31, ds_rasp0, ds_rasp1, ds_sys0, ds_sys1;
    reg  [5:0]  ds_pid0, ds_pid1;
    reg         ds_mul0, ds_mul1, ds_ld0, ds_ld1, ds_st0, ds_st1, ds_uns0, ds_uns1, ds_csri0, ds_csri1;
    reg  [1:0]  ds_mop0, ds_mop1, ds_msz0, ds_msz1, ds_csrop0, ds_csrop1, ds_cnt0, ds_cnt1;
    reg         ds_hit0, ds_hit1, ds_exc0, ds_exc1, ds_wi0, ds_wi1;
    reg  [11:0] ds_csra0, ds_csra1;
    reg         ds_pt0, ds_pt1;          // predicted taken
    reg  [4:0]  ds_cause0, ds_cause1;

    // ======================================================================
    // wakeup broadcast buses
    // ======================================================================
    wire        iq0_sv, iq1_sv, iq0_sbc, iq1_sbc;
    wire [5:0]  iq0_sp1, iq0_sp2, iq0_spd, iq1_sp1, iq1_sp2, iq1_spd;
    localparam integer PW = 120;
    wire [PW-1:0] iq0_spay, iq1_spay;
    reg         csr_wb_v;            // CSR result written at commit
    reg  [5:0]  csr_wb_pd;
    reg  [31:0] csr_wb_val;
    wire        lsu_wb_v, lsu_wb_q0, lsu_wb_q1;
    wire [5:0]  lsu_wb_pd;
    wire [31:0] lsu_wb_val;
    reg         mul3_v;               // multiplier result stage
    reg  [5:0]  mul3_pd;
    reg         mul3_wen;
    wire [3:0]  wk_v;
    wire [5:0]  wk_t0, wk_t1, wk_t2, wk_t3;
    assign wk_v[0] = iq0_sv && iq0_sbc;
    assign wk_t0   = iq0_spd;
    assign wk_v[1] = iq1_sv && iq1_sbc;
    assign wk_t1   = iq1_spd;
    // CSR results use the multiplier's write port: a CSR instruction commits
    // with nothing younger renamed, so no multiply can be in flight
    assign wk_v[2] = (mul3_v && mul3_wen) || csr_wb_v;
    assign wk_t2   = csr_wb_v ? csr_wb_pd : mul3_pd;
    assign wk_v[3] = lsu_wb_v;
    assign wk_t3   = lsu_wb_pd;
    function wkm;
        input [5:0] t;
        begin
            wkm = (wk_v[0] && t == wk_t0) || (wk_v[1] && t == wk_t1) ||
                  (wk_v[2] && t == wk_t2) || (wk_v[3] && t == wk_t3);
        end
    endfunction

    // ======================================================================
    // DS : dispatch into ROB / issue queues
    // ======================================================================
    // (same-cycle wakeups are merged inside the IQ/LSU insert logic)
    wire ds_r10 = prdy[ds_p10], ds_r20 = prdy[ds_p20];
    // slot-1 sources produced by slot 0 of the same group are never ready yet
    wire ds_dep1 = ds_v0 && ds_wen0 && ds_p11 == ds_pd0;
    wire ds_dep2 = ds_v0 && ds_wen0 && ds_p21 == ds_pd0;
    wire ds_r11 = !ds_dep1 && prdy[ds_p11];
    wire ds_r21 = !ds_dep2 && prdy[ds_p21];
    // ---------------- decode-time prediction fix-up (DS stage)
    // A JAL's target is known here; a non-control instruction predicted taken
    // (BTB alias) continues sequentially.  The front end is redirected and
    // the instruction flushes everything younger when it commits.
    reg  [31:0] ds_jt0, ds_jt1;          // JAL targets, added in DR
    wire ds_ctl0 = ds_br0 || ds_jal0 || ds_jalr0, ds_ctl1 = ds_br1 || ds_jal1 || ds_jalr1;
    wire ds_fx0 = ds_v0 && ((ds_jal0 && !(ds_pt0 && ds_pn0 == ds_jt0)) || (!ds_ctl0 && !ds_exc0 && ds_pt0));
    wire ds_fx1 = ds_v1 && !ds_fx0 &&
                  ((ds_jal1 && !(ds_pt1 && ds_pn1 == ds_jt1)) || (!ds_ctl1 && !ds_exc1 && ds_pt1));
    wire [31:0] ds_fpc0 = ds_jal0 ? ds_jt0 : ds_pc0 + 32'd4;
    wire [31:0] ds_fpc1 = ds_jal1 ? ds_jt1 : ds_pc1 + 32'd4;
    wire [31:0] ds_pc_n0 = ds_fx0 ? ds_fpc0 : ds_pn0;     // corrected predicted next PC
    wire [31:0] ds_pc_n1 = ds_fx1 ? ds_fpc1 : ds_pn1;
    // IQ payload layout (PW bits)
    //  [4:0] rob  [5] wen  [9:6] aop  [10] s1pc  [11] s2imm  [43:12] imm  [73:44] pc[31:2]
    //  [74] br [75] jal [76] jalr [79:77] f3 [109:80] pnext[31:2] [110] call [111] ret
    //  [114:112] rasp [115] csr [116] csri [117] mul [119:118] mop
    wire [PW-1:0] pay0 = {ds_mop0, ds_mul0, ds_csri0, (ds_sys0 == `SYS_CSR), ds_rasp0, ds_ret0, ds_call0,
                          ds_pc_n0[31:2], ds_f30, ds_jalr0, ds_jal0, ds_br0, ds_pc0[31:2], ds_imm0,
                          ds_s2imm0, ds_s1pc0, ds_aop0, ds_wen0, ds_rob0};
    wire [PW-1:0] pay1 = {ds_mop1, ds_mul1, ds_csri1, (ds_sys1 == `SYS_CSR), ds_rasp1, ds_ret1, ds_call1,
                          ds_pc_n1[31:2], ds_f31, ds_jalr1, ds_jal1, ds_br1, ds_pc1[31:2], ds_imm1,
                          ds_s2imm1, ds_s1pc1, ds_aop1, ds_wen1, ds_rob1};
    // queue routing of the two DS slots, registered when DS is loaded (equal to
    // ds_vX && ds_rtX == queue).  Separate copies for the valid logic (_v) and
    // the payload multiplexer select (_s): the select drives ~150 mux bits.
    (* syn_preserve = 1, syn_keep = 1 *) reg q0a_v, q0b_v, q1a_v, q1b_v, qma_v, qmb_v;
    (* syn_preserve = 1, syn_keep = 1 *) reg q0a_s, q1a_s, qma_s;
    wire q0_a = q0a_v, q0_b = q0b_v;
    wire q1_a = q1a_v, q1_b = q1b_v;
    wire qm_a = qma_v, qm_b = qmb_v;
    // broadcast-at-select for plain ALU / branch ops (not MUL, not CSR)
    wire bc0 = ds_wen0 && !ds_mul0 && ds_sys0 != `SYS_CSR;
    wire bc1 = ds_wen1 && !ds_mul1 && ds_sys1 != `SYS_CSR;

    ooo_iq #(.N(8), .PW(PW)) u_iq0 (
        .clk(clk), .resetn(resetn), .flush(flush),
        .i0_valid(q0_a || q0_b), .i0_pay(q0a_s ? pay0 : pay1),
        .i0_p1(q0a_s ? ds_p10 : ds_p11), .i0_p2(q0a_s ? ds_p20 : ds_p21), .i0_pdst(q0a_s ? ds_pd0 : ds_pd1),
        .i0_r1(q0_a ? ds_r10 : ds_r11), .i0_r2(q0_a ? ds_r20 : ds_r21), .i0_bc(q0_a ? bc0 : bc1),
        .i1_valid(q0_a && q0_b), .i1_pay(pay1), .i1_p1(ds_p11), .i1_p2(ds_p21), .i1_pdst(ds_pd1),
        .i1_r1(ds_r11), .i1_r2(ds_r21), .i1_bc(bc1),
        .wk_v({lsu_wb_q0, wk_v[2:0]}), .wk_t0(wk_t0), .wk_t1(wk_t1), .wk_t2(wk_t2), .wk_t3(wk_t3),
        .s_valid(iq0_sv), .s_pay(iq0_spay), .s_p1(iq0_sp1), .s_p2(iq0_sp2), .s_pdst(iq0_spd), .s_bc(iq0_sbc),
        .count(iq0_cnt));
    ooo_iq #(.N(8), .PW(PW)) u_iq1 (
        .clk(clk), .resetn(resetn), .flush(flush),
        .i0_valid(q1_a || q1_b), .i0_pay(q1a_s ? pay0 : pay1),
        .i0_p1(q1a_s ? ds_p10 : ds_p11), .i0_p2(q1a_s ? ds_p20 : ds_p21), .i0_pdst(q1a_s ? ds_pd0 : ds_pd1),
        .i0_r1(q1_a ? ds_r10 : ds_r11), .i0_r2(q1_a ? ds_r20 : ds_r21), .i0_bc(q1_a ? bc0 : bc1),
        .i1_valid(q1_a && q1_b), .i1_pay(pay1), .i1_p1(ds_p11), .i1_p2(ds_p21), .i1_pdst(ds_pd1),
        .i1_r1(ds_r11), .i1_r2(ds_r21), .i1_bc(bc1),
        .wk_v({lsu_wb_q1, wk_v[2:0]}), .wk_t0(wk_t0), .wk_t1(wk_t1), .wk_t2(wk_t2), .wk_t3(wk_t3),
        .s_valid(iq1_sv), .s_pay(iq1_spay), .s_p1(iq1_sp1), .s_p2(iq1_sp2), .s_pdst(iq1_spd), .s_bc(iq1_sbc),
        .count(iq1_cnt));

    // ======================================================================
    // PRF
    // ======================================================================
    wire [5:0]  rf_ra [0:5];
    wire [31:0] rf_rd [0:5];
    wire [3:0]  rf_we;
    wire [5:0]  rf_wa0, rf_wa1, rf_wa2, rf_wa3;
    wire [31:0] rf_wd0, rf_wd1, rf_wd2, rf_wd3;
    ooo_prf u_prf (.clk(clk), .resetn(resetn), .we(rf_we),
        .wa0(rf_wa0), .wa1(rf_wa1), .wa2(rf_wa2), .wa3(rf_wa3),
        .wd0(rf_wd0), .wd1(rf_wd1), .wd2(rf_wd2), .wd3(rf_wd3),
        .ra0(rf_ra[0]), .ra1(rf_ra[1]), .ra2(rf_ra[2]), .ra3(rf_ra[3]), .ra4(rf_ra[4]), .ra5(rf_ra[5]),
        .rd0(rf_rd[0]), .rd1(rf_rd[1]), .rd2(rf_rd[2]), .rd3(rf_rd[3]), .rd4(rf_rd[4]), .rd5(rf_rd[5]));

    // ======================================================================
    // ALU lanes:  S -> R -> X
    // ======================================================================
    // R stage
    reg          r0_v, r1_v;
    reg [PW-1:0] r0_pay, r1_pay;
    reg [5:0]    r0_p1, r0_p2, r0_pd, r1_p1, r1_p2, r1_pd;
    // X stage
    reg          x0_v, x1_v;
    reg [PW-1:0] x0_pay, x1_pay;
    reg [5:0]    x0_pd, x1_pd;
    reg [31:0]   x0_o1, x0_o2, x1_o1, x1_o2;
    reg [1:0]    x0_b1, x0_b2, x1_b1, x1_b2;
    // XR: results registered at the end of X (bypass source for the next cycle)
    reg [31:0]   xr0, xr1;
    assign rf_ra[0] = r0_p1; assign rf_ra[1] = r0_p2;
    assign rf_ra[2] = r1_p1; assign rf_ra[3] = r1_p2;
    // lanes writing the PRF at the end of this cycle (bypass candidates for R)
    wire x0_wv = x0_v && x0_pay[5] && !x0_pay[115];
    wire x1_wv = x1_v && x1_pay[5] && !x1_pay[117];
    function [1:0] bsel;
        input [5:0] p;
        begin
            bsel = {x1_wv && x1_pd == p && p != 6'd0, x0_wv && x0_pd == p && p != 6'd0};
        end
    endfunction

    // ---------------- lane 0 execute (ALU + branch + CSR operand)
    wire [31:0] a0 = x0_b1[0] ? xr0 : (x0_b1[1] ? xr1 : x0_o1);
    wire [31:0] b0 = x0_b2[0] ? xr0 : (x0_b2[1] ? xr1 : x0_o2);
    wire [31:0] x0_pc  = {x0_pay[73:44], 2'b00};
    wire [31:0] x0_imm = x0_pay[43:12];
    wire [31:0] alu0_a = x0_pay[10] ? x0_pc : a0;
    wire [31:0] alu0_b = x0_pay[11] ? x0_imm : b0;
    wire [31:0] alu0_y;
    ooo_alu u_alu0 (.op(x0_pay[9:6]), .a(alu0_a), .b(alu0_b), .y(alu0_y));
    wire        x0_br = x0_pay[74], x0_jal = x0_pay[75], x0_jalr = x0_pay[76];
    wire [2:0]  x0_f3 = x0_pay[79:77];
    wire        cond_eq = (a0 == b0);
    wire        cond_lt = ($signed(a0) < $signed(b0));
    wire        cond_ltu = (a0 < b0);
    reg         cond;
    always @* begin
        case (x0_f3)
        3'b000: cond = cond_eq;   3'b001: cond = !cond_eq;
        3'b100: cond = cond_lt;   3'b101: cond = !cond_lt;
        3'b110: cond = cond_ltu;  3'b111: cond = !cond_ltu;
        default: cond = 1'b0;
        endcase
    end
    wire        x0_taken = x0_jal || x0_jalr || (x0_br && cond);
    wire [31:0] x0_tgt  = x0_jalr ? ((a0 + x0_imm) & 32'hffff_fffe) : (x0_pc + x0_imm);
    wire [31:0] x0_seq  = x0_pc + 32'd4;
    wire [31:0] x0_next = x0_taken ? x0_tgt : x0_seq;
    wire        x0_ctl  = x0_br || x0_jal || x0_jalr;
    wire        x0_mis  = x0_ctl && (x0_next[31:2] != x0_pay[109:80]);
    wire        x0_texc = x0_ctl && x0_taken && x0_tgt[1];
    // JAL / JALR compute their link value in the ALU (ALU_LINK), so the result
    // goes straight to the PRF / bypass register without another mux level
    wire [31:0] x0_res  = alu0_y;

    // ---------------- lane 1 execute (ALU + multiplier stage 1)
    wire [31:0] a1 = x1_b1[0] ? xr0 : (x1_b1[1] ? xr1 : x1_o1);
    wire [31:0] b1 = x1_b2[0] ? xr0 : (x1_b2[1] ? xr1 : x1_o2);
    wire [31:0] alu1_y;
    ooo_alu u_alu1 (.op(x1_pay[9:6]), .a(x1_pay[10] ? {x1_pay[73:44], 2'b00} : a1),
                    .b(x1_pay[11] ? x1_pay[43:12] : b1), .y(alu1_y));
    wire        x1_mul = x1_pay[117];
    wire [1:0]  x1_mop = x1_pay[119:118];
    // 33x33 signed multiplier, 2 pipeline registers (APM)
    wire [32:0] mul_a = {(x1_mop == 2'd1 || x1_mop == 2'd2) && a1[31], a1};
    wire [32:0] mul_b = {(x1_mop == 2'd1) && b1[31], b1};
    wire [65:0] mul_p;
    mul u_mul (.ce(1'b1), .rst(!resetn), .clk(clk), .a(mul_a), .b(mul_b), .p(mul_p));
    reg         mul2_v, mul2_wen, mul2_hi;
    reg  [5:0]  mul2_pd;
    reg  [4:0]  mul2_rob, mul3_rob;
    reg         mul3_hi;
    wire [31:0] mul_res = mul3_hi ? mul_p[63:32] : mul_p[31:0];

    // PRF write ports
    assign rf_we[0] = x0_wv;
    assign rf_wa0   = x0_pd;
    assign rf_wd0   = x0_res;
    assign rf_we[1] = x1_wv;
    assign rf_wa1   = x1_pd;
    assign rf_wd1   = alu1_y;
    assign rf_we[2] = (mul3_v && mul3_wen) || csr_wb_v;
    assign rf_wa2   = csr_wb_v ? csr_wb_pd : mul3_pd;
    assign rf_wd2   = csr_wb_v ? csr_wb_val : mul_res;
    assign rf_we[3] = lsu_wb_v;
    assign rf_wa3   = lsu_wb_pd;
    assign rf_wd3   = lsu_wb_val;

    // BR stage (lane 0 outcome) and lane-1 completion registers
    reg         br_v, br_ctl, br_mis, br_taken, br_exc, br_call, br_ret;
    reg  [4:0]  br_rob;
    reg  [31:0] br_next, br_tgt, br_seq;
    reg  [2:0]  br_rasp;
    reg         br_hb;                   // path-history bit of the branch pc
    reg         c1_v;
    reg  [4:0]  c1_rob;
    reg         cm_v;               // multiplier completion
    reg  [4:0]  cm_rob;
    reg  [31:0] csr_src;            // CSR operand captured in lane 0

    // ======================================================================
    // LSU
    // ======================================================================
    wire        ca_v, ca_exc, cr_v, cr_exc;
    wire [4:0]  ca_rob, ca_cause, cr_rob;
    wire [31:0] ca_tval, cr_tval;
    wire        sq_empty, mem_idle, io_busy;
    reg  [1:0]  st_commit;
    ooo_lsu #(.ORD0_BASE(ORD0_BASE), .ORD0_MASK(ORD0_MASK), .ORD1_BASE(ORD1_BASE), .ORD1_MASK(ORD1_MASK)) u_lsu (
        .clk(clk), .resetn(resetn), .flush(flush),
        .m0_valid(qm_a || qm_b),
        .m0_wen(qm_a ? ds_wen0 : ds_wen1), .m0_r1(qm_a ? ds_r10 : ds_r11), .m0_r2(qm_a ? ds_r20 : ds_r21),
        .m0_st(qma_s ? ds_st0 : ds_st1), .m0_uns(qma_s ? ds_uns0 : ds_uns1), .m0_rob(qma_s ? ds_rob0 : ds_rob1),
        .m0_pdst(qma_s ? ds_pd0 : ds_pd1), .m0_p1(qma_s ? ds_p10 : ds_p11), .m0_p2(qma_s ? ds_p20 : ds_p21),
        .m0_size(qma_s ? ds_msz0 : ds_msz1), .m0_imm(qma_s ? ds_imm0 : ds_imm1),
        .m1_valid(qm_a && qm_b), .m1_wen(ds_wen1), .m1_r1(ds_r11), .m1_r2(ds_r21), .m1_st(ds_st1),
        .m1_uns(ds_uns1), .m1_rob(ds_rob1), .m1_pdst(ds_pd1), .m1_p1(ds_p11), .m1_p2(ds_p21),
        .m1_size(ds_msz1), .m1_imm(ds_imm1),
        .count(iqm_cnt),
        .wk_v(wk_v), .wk_t0(wk_t0), .wk_t1(wk_t1), .wk_t2(wk_t2), .wk_t3(wk_t3),
        .rf_ra1(rf_ra[4]), .rf_ra2(rf_ra[5]), .rf_rd1(rf_rd[4]), .rf_rd2(rf_rd[5]),
        .x0_wv(x0_wv), .x1_wv(x1_wv), .x0_pdst(x0_pd), .x1_pdst(x1_pd), .xr0(xr0), .xr1(xr1),
        .rob_head_valid(!rob_empty), .rob_head(rob_h), .st_commit(st_commit),
        .ca_valid(ca_v), .ca_rob(ca_rob), .ca_exc(ca_exc), .ca_cause(ca_cause), .ca_tval(ca_tval),
        .cr_valid(cr_v), .cr_rob(cr_rob), .cr_exc(cr_exc), .cr_tval(cr_tval),
        .wb_valid(lsu_wb_v), .wb_v_q0(lsu_wb_q0), .wb_v_q1(lsu_wb_q1), .wb_pdst(lsu_wb_pd), .wb_data(lsu_wb_val),
        .dreq_valid(dreq_valid), .dreq_we(dreq_we), .dreq_addr(dreq_addr), .dreq_wdata(dreq_wdata),
        .dreq_wstrb(dreq_wstrb), .dreq_size(dreq_size), .dreq_ready(dreq_ready),
        .drsp_valid(drsp_valid), .drsp_rdata(drsp_rdata), .drsp_error(drsp_error),
        .sq_empty(sq_empty), .mem_idle(mem_idle), .io_busy(io_busy), .io_hold(irq_req));

    // ======================================================================
    // ROB storage
    // ======================================================================
    // static fields, banked by index parity (one write + one read per bank)
    //  [29:0] pc  [34:30] rd  [35] wen  [41:36] pdst  [47:42] old  [48] br [49] jal [50] jalr
    //  [51] call [52] ret [53] st [56:54] sys [58:57] csrop [59] csri [71:60] csraddr
    //  [72] hit [74:73] cnt [75] ld
    localparam integer RW = 76;
    // asynchronous-read tables: keep them in distributed RAM
    (* syn_ramstyle = "select_ram" *) reg  [RW-1:0] robE [0:15];
    (* syn_ramstyle = "select_ram" *) reg  [RW-1:0] robO [0:15];
    wire [RW-1:0] ds_e0 = {ds_ld0, ds_cnt0, ds_hit0, ds_csra0, ds_wi0, ds_csrop0,
                           ds_sys0, ds_st0, ds_ret0, ds_call0, ds_jalr0, ds_jal0, ds_br0, ds_old0, ds_pd0,
                           ds_wen0, ds_rd0, ds_pc0[31:2]};
    wire [RW-1:0] ds_e1 = {ds_ld1, ds_cnt1, ds_hit1, ds_csra1, ds_wi1, ds_csrop1,
                           ds_sys1, ds_st1, ds_ret1, ds_call1, ds_jalr1, ds_jal1, ds_br1, ds_old1, ds_pd1,
                           ds_wen1, ds_rd1, ds_pc1[31:2]};
    reg  [31:0] rob_done, rob_exc, rob_mis, rob_taken, rob_ff;
    reg  [4:0]  rob_cause [0:31];
    (* syn_ramstyle = "select_ram" *) reg  [31:0] rob_tval  [0:31];
    (* syn_ramstyle = "select_ram" *) reg  [29:0] rob_tgt   [0:31];
    // fetch-packet id of every ROB entry (banked like robE/robO)
    reg  [5:0] pidE [0:15];
    reg  [5:0] pidO [0:15];
    always @(posedge clk) begin
        if (ds_v0) begin
            if (ds_rob0[0]) pidO[ds_rob0[4:1]] <= ds_pid0; else pidE[ds_rob0[4:1]] <= ds_pid0;
        end
        if (ds_v1) begin
            if (ds_rob1[0]) pidO[ds_rob1[4:1]] <= ds_pid1; else pidE[ds_rob1[4:1]] <= ds_pid1;
        end
        if (ds_v0) begin
            if (ds_rob0[0]) robO[ds_rob0[4:1]] <= ds_e0; else robE[ds_rob0[4:1]] <= ds_e0;
        end
        if (ds_v1) begin
            if (ds_rob1[0]) robO[ds_rob1[4:1]] <= ds_e1; else robE[ds_rob1[4:1]] <= ds_e1;
        end
        if (br_v && br_ctl) rob_tgt[br_rob] <= br_tgt[31:2];
        if (ca_v) rob_tval[ca_rob] <= ca_tval;
        else if (cr_v) rob_tval[cr_rob] <= cr_tval;
        else if (br_v && br_exc) rob_tval[br_rob] <= br_tgt;
    end
    reg  [4:0]    rob_h1;            // always rob_h + 1
    // private copies of the head pointers for the ROB static-field reads (the
    // main copies drive ~140 loads; syn_preserve keeps synthesis from merging)
    (* syn_preserve = 1, syn_keep = 1 *) reg [4:0] rob_hS;
    (* syn_preserve = 1, syn_keep = 1 *) reg [4:0] rob_h1S;
    wire [RW-1:0] hE = robE[rob_hS[0] ? rob_h1S[4:1] : rob_hS[4:1]];
    wire [RW-1:0] hO = robO[rob_hS[4:1]];
    wire [RW-1:0] h0 = rob_hS[0] ? hO : hE;
    wire [RW-1:0] h1 = rob_hS[0] ? hE : hO;
    wire [5:0]    pE = pidE[rob_hS[0] ? rob_h1S[4:1] : rob_hS[4:1]];
    wire [5:0]    pO = pidO[rob_hS[4:1]];
    wire [5:0]    h0_pid = rob_hS[0] ? pO : pE;
    wire [5:0]    h1_pid = rob_hS[0] ? pE : pO;

    // ======================================================================
    // commit
    // ======================================================================
    reg         h0_v, h1_v;          // registered: rob_n >= 1 / >= 2
    wire        h0_d = rob_done[rob_h], h1_d = rob_done[rob_h1];
    wire [31:0] h0_pc = {h0[29:0], 2'b00}, h1_pc = {h1[29:0], 2'b00};
    wire [4:0]  h0_rd = h0[34:30], h1_rd = h1[34:30];
    wire        h0_wen = h0[35], h1_wen = h1[35];
    wire [5:0]  h0_pd = h0[41:36], h1_pd = h1[41:36], h0_old = h0[47:42], h1_old = h1[47:42];
    wire        h0_ctl = h0[48] || h0[49] || h0[50], h1_ctl = h1[48] || h1[49] || h1[50];
    wire        h0_st = h0[53], h1_st = h1[53];
    wire [2:0]  h0_sys = h0[56:54], h1_sys = h1[56:54];
    wire [1:0]  h0_csrop = h0[58:57];
    wire        h0_wi = h0[59];
    wire [11:0] h0_csra = h0[71:60];
    // csr file
    wire [31:0] csr_rdata, trap_target, mret_target, irq_pending, irq_enable;
    wire        csr_exists, csr_ro, csr_illegal, irq_gie;
    wire        csr_rd_en = (h0_csrop == 2'd1) ? (h0_rd != 5'd0) : 1'b1;
    // CSR instructions commit in three steps, so no path runs from the ROB
    // head pointer through the CSR file into the CSR registers:
    //   1. the head is a CSR op: its fields are registered (cq_*), csr_arm set
    //   2. commit: read the CSR (old value -> rd), compute the new value
    //   3. the next cycle: write the CSR (csr_wp).  Commit pauses for that cycle
    //      so a trap / MRET cannot collide with the write.
    // CSR ops are serialising, so the two extra cycles cost almost nothing.
    reg         csr_arm, cq_wi, cq_rden, csr_wp;
    reg  [11:0] cq_a, wq_a;
    reg  [1:0]  cq_op;
    reg  [31:0] wq_d;
    wire [31:0] csr_wdata = (cq_op == 2'd1) ? csr_src :
                            (cq_op == 2'd2) ? (csr_rdata | csr_src) : (csr_rdata & ~csr_src);
    // [sim-hoisted] reg         irq_req;          // registered: an enabled interrupt is pending
    // events this cycle
    // the head entry must have left DS (its ROB fields are written at DS)
    wire h0_disp = !(ds_v0 && ds_rob0 == rob_h) && !(ds_v1 && ds_rob1 == rob_h);
    wire c_irq   = !flush_r && irq_req && h0_v && h0_disp && !io_busy && !csr_wp;
    wire c0_ok   = !flush_r && !c_irq && h0_v && h0_d && !csr_wp;
    wire c0_exc  = c0_ok && rob_exc[rob_h];
    wire c0_csr_wait = h0_sys == `SYS_CSR && !csr_arm;
    wire c0_csr  = c0_ok && !rob_exc[rob_h] && h0_sys == `SYS_CSR && csr_arm;
    wire c0_csr_bad = 1'b0;          // checked at dispatch
    wire c0_mret = c0_ok && !rob_exc[rob_h] && h0_sys == `SYS_MRET;
    wire c0_fi_wait = h0_sys == `SYS_FENCEI && !(sq_empty && mem_idle && cmo_done);
    assign cmo_req = h0_v && h0_d && h0_sys == `SYS_FENCEI && !rob_exc[rob_h] && sq_empty && mem_idle;
    wire c0_fencei = c0_ok && !rob_exc[rob_h] && h0_sys == `SYS_FENCEI && !c0_fi_wait;
    wire c0_mis  = c0_ok && !rob_exc[rob_h] && (rob_mis[rob_h] || rob_ff[rob_h]);
    wire c0_norm = c0_ok && !rob_exc[rob_h] && !c0_csr_bad && !c0_fi_wait && !c0_mret && !c0_csr_wait;
    wire c1_norm = c0_norm && !c0_mis && h0_sys == `SYS_NONE && h1_v && h1_d && !rob_exc[rob_h1] &&
                   h1_sys == `SYS_NONE && !rob_mis[rob_h1] && !rob_ff[rob_h1] && !(h0_ctl && h1_ctl);
    wire c_trap  = c_irq || c0_exc || c0_csr_bad;
    wire [4:0] trap_cause = c_irq ? (irq_pending[11] && irq_enable[11] ? 5'd11 :
                                     irq_pending[3]  && irq_enable[3]  ? 5'd3 : 5'd7)
                                  : (c0_csr_bad ? `EXC_ILLEGAL : rob_cause[rob_h]);
    wire [31:0] trap_tval = (c_irq || c0_csr_bad) ? 32'd0 :
                            (rob_cause[rob_h] == `EXC_IFAULT) ? h0_pc :
                            (rob_cause[rob_h] == `EXC_ILLEGAL || rob_cause[rob_h] == `EXC_ECALL ||
                             rob_cause[rob_h] == `EXC_BREAK) ? 32'd0 : rob_tval[rob_h];

    csr_file #(.MTVEC_RESET_ADDR(MTVEC_RST)) u_csr (
        .clk(clk), .resetn(resetn),
        .csr_addr(csr_wp ? wq_a : cq_a), .csr_read_en(c0_csr && cq_rden), .csr_write_intent(csr_wp),
        .csr_wdata(wq_d), .csr_commit(csr_wp), .csr_rdata(csr_rdata),
        .csr_exists(csr_exists), .csr_readonly_addr(csr_ro), .csr_access_illegal(csr_illegal),
        .trap_enter(c_trap), .trap_pc(h0_pc), .trap_is_interrupt(c_irq), .trap_cause(trap_cause),
        .trap_tval(trap_tval), .mret_commit(c0_mret),
        .irq_external(irq_external), .irq_software(irq_software), .irq_timer(irq_timer),
        .trap_target(trap_target), .mret_target(mret_target), .irq_pending(irq_pending),
        .irq_enable(irq_enable), .irq_global_enable(irq_gie));

    always @(posedge clk) begin
        q0a_s <= take0 && rt0 == `RT_IQ0; q1a_s <= take0 && rt0 == `RT_IQ1; qma_s <= take0 && rt0 == `RT_IQM;
        cq_a <= h0_csra; cq_op <= h0_csrop; cq_wi <= h0_wi; cq_rden <= csr_rd_en;
        wq_a <= cq_a; wq_d <= csr_wdata;
        if (!resetn) begin
            csr_arm <= 1'b0; csr_wp <= 1'b0;
        end else begin
            // the head stays the same next cycle unless it commits or is flushed
            csr_arm <= !flush_r && !c_trap && h0_v && h0_disp && !rob_exc[rob_h] &&
                       h0_sys == `SYS_CSR && !c0_csr;
            csr_wp  <= c0_csr && cq_wi;
        end
    end

    wire [1:0] n_commit = c1_norm ? 2'd2 : (c0_norm ? 2'd1 : 2'd0);
    always @(posedge clk)
        if (!resetn) begin rob_hS <= 5'd0; rob_h1S <= 5'd1; end
        else begin rob_hS <= rob_hS + {3'd0, n_commit}; rob_h1S <= rob_h1S + {3'd0, n_commit}; end
    wire cw0 = c0_norm && h0_wen, cw1 = c1_norm && h1_wen;

    // BTB training from the oldest committing control instruction
    wire        bu_sel1 = !(c0_norm && h0_ctl);
    wire [RW-1:0] bu_e   = bu_sel1 ? h1 : h0;
    always @(posedge clk) begin
        tu0_v <= resetn && c0_norm && h0[48]; tu0_pc <= h0_pc; tu0_t <= rob_taken[rob_h];  tu0_id <= h0_pid;
        tu1_v <= resetn && c1_norm && h1[48]; tu1_pc <= h1_pc; tu1_t <= rob_taken[rob_h1]; tu1_id <= h1_pid;
        btb_upd       <= resetn && ((c0_norm && h0_ctl) || (c1_norm && h1_ctl));
        btb_upd_pc    <= bu_sel1 ? h1_pc : h0_pc;
        btb_upd_taken <= bu_sel1 ? rob_taken[rob_h1] : rob_taken[rob_h];
        btb_upd_tgt   <= {bu_sel1 ? rob_tgt[rob_h1] : rob_tgt[rob_h], 2'b00};
        btb_upd_type  <= bu_e[52] ? `BT_RET : bu_e[50] ? `BT_JALR : bu_e[49] ? `BT_JAL : `BT_COND;
        btb_upd_call  <= bu_e[51];
        btb_upd_hit   <= bu_e[72];
        btb_upd_cnt   <= bu_e[74:73];
    end

    // ======================================================================
    // front-end redirect selection
    // ======================================================================
    wire [4:0] age_br   = br_rob - rob_h;
    wire [4:0] age_pend = pend_rob - rob_h;
    wire [5:0] br_pid = br_rob[0] ? pidO[br_rob[4:1]] : pidE[br_rob[4:1]];
    wire br_redir = br_v && br_ctl && br_mis && !br_exc && !flush_r && (!rn_block || age_br < age_pend);
    always @* begin
        fe_redir = 1'b0; fe_redir_pc = 32'd0; fe_ras_fix = 1'b0; fe_ras_push = 1'b0;
        fe_ras_ptr = 3'd0; fe_ras_addr = 32'd0;
        fe_hf_v = 1'b0; fe_hf_id = br_pid; fe_hf_t = br_taken; fe_hf_hb = br_hb;
        if (flush_r) begin
            fe_redir = flush_fe; fe_redir_pc = flush_tgt;
        end else if (br_redir) begin
            fe_redir = 1'b1; fe_redir_pc = br_next; fe_ras_fix = 1'b1;
            fe_ras_push = br_call; fe_ras_addr = br_seq;
            fe_ras_ptr = br_ret ? br_rasp - 3'd1 : br_rasp;
            fe_hf_v = 1'b1;
        end else if (dec_redir_r) begin
            fe_hf_v = 1'b1; fe_hf_id = dec_pid; fe_hf_t = dec_tk; fe_hf_hb = dec_hb;
            fe_redir = 1'b1; fe_redir_pc = dec_redir_pc; fe_ras_fix = 1'b1;
            fe_ras_push = dec_ras_push; fe_ras_addr = dec_ras_addr;
            fe_ras_ptr = dec_ras_ret ? dec_ras_ptr - 3'd1 : dec_ras_ptr;
        end
    end

    // ======================================================================
    // sequential logic
    // ======================================================================
    integer i;
    always @(posedge clk) begin
        // ---------------- DR -> DS payload
        begin   // data always loaded; ds_v0 qualifies it
            ds_rob0 <= rob_t; ds_pd0 <= u0_wen ? new0 : 6'd0; ds_p10 <= rn0_p1; ds_p20 <= rn0_p2;
            ds_old0 <= r0_old; ds_wen0 <= u0_wen; ds_rd0 <= d0_rd; ds_pc0 <= ib0_pc; ds_imm0 <= d0_imm;
            ds_pn0 <= ib0_pnext; ds_jt0 <= ib0_pc + d0_imm; ds_pt0 <= ib0_ptaken && !ib0_err; ds_aop0 <= d0_aop; ds_s1pc0 <= d0_s1pc; ds_s2imm0 <= d0_s2imm;
            ds_br0 <= d0_br && !e0_exc; ds_jal0 <= d0_jal && !e0_exc; ds_jalr0 <= d0_jalr && !e0_exc;
            ds_call0 <= d0_call && !e0_exc; ds_ret0 <= d0_ret && !e0_exc;
            ds_f30 <= ib0_inst[14:12]; ds_rasp0 <= ib0_rasp; ds_sys0 <= e0_exc ? `SYS_NONE : d0_sys;
            ds_mul0 <= u0_mul; ds_ld0 <= d0_ld && !e0_exc; ds_st0 <= d0_st && !e0_exc; ds_uns0 <= d0_uns;
            ds_csri0 <= d0_csri; ds_mop0 <= d0_mop; ds_msz0 <= d0_msz; ds_csrop0 <= d0_csrop;
            ds_cnt0 <= ib0_cnt; ds_hit0 <= ib0_hit; ds_exc0 <= e0_exc; ds_cause0 <= e0_cause;
            ds_rt0 <= rt0; ds_csra0 <= ib0_inst[31:20]; ds_pid0 <= ib0_pid;
            ds_wi0 <= (d0_csrop == 2'd1) || (ib0_inst[19:15] != 5'd0);
        end
        begin
            ds_rob1 <= rob_t + 5'd1; ds_pd1 <= u1_wen ? new1 : 6'd0; ds_p11 <= rn1_p1; ds_p21 <= rn1_p2;
            ds_old1 <= r1_old; ds_wen1 <= u1_wen; ds_rd1 <= d1_rd; ds_pc1 <= ib1_pc; ds_imm1 <= d1_imm;
            ds_pn1 <= ib1_pnext; ds_jt1 <= ib1_pc + d1_imm; ds_pt1 <= ib1_ptaken && !ib1_err; ds_aop1 <= d1_aop; ds_s1pc1 <= d1_s1pc; ds_s2imm1 <= d1_s2imm;
            ds_br1 <= d1_br && !e1_exc; ds_jal1 <= d1_jal && !e1_exc; ds_jalr1 <= d1_jalr && !e1_exc;
            ds_call1 <= d1_call && !e1_exc; ds_ret1 <= d1_ret && !e1_exc;
            ds_f31 <= ib1_inst[14:12]; ds_rasp1 <= ib1_rasp; ds_sys1 <= e1_exc ? `SYS_NONE : d1_sys;
            ds_mul1 <= u1_mul; ds_ld1 <= d1_ld && !e1_exc; ds_st1 <= d1_st && !e1_exc; ds_uns1 <= d1_uns;
            ds_csri1 <= d1_csri; ds_mop1 <= d1_mop; ds_msz1 <= d1_msz; ds_csrop1 <= d1_csrop;
            ds_cnt1 <= ib1_cnt; ds_hit1 <= ib1_hit; ds_exc1 <= e1_exc; ds_cause1 <= e1_cause;
            ds_rt1 <= rt1; ds_csra1 <= ib1_inst[31:20]; ds_pid1 <= ib1_pid;
            ds_wi1 <= (d1_csrop == 2'd1) || (ib1_inst[19:15] != 5'd0);
        end

        // ---------------- S -> R
        r0_pay <= iq0_spay; r0_p1 <= iq0_sp1; r0_p2 <= iq0_sp2; r0_pd <= iq0_spd;
        r1_pay <= iq1_spay; r1_p1 <= iq1_sp1; r1_p2 <= iq1_sp2; r1_pd <= iq1_spd;
        // ---------------- R -> X
        x0_pay <= r0_pay; x0_pd <= r0_pd; x0_o1 <= rf_rd[0]; x0_o2 <= rf_rd[1];
        x0_b1 <= bsel(r0_p1); x0_b2 <= bsel(r0_p2);
        x1_pay <= r1_pay; x1_pd <= r1_pd; x1_o1 <= rf_rd[2]; x1_o2 <= rf_rd[3];
        x1_b1 <= bsel(r1_p1); x1_b2 <= bsel(r1_p2);
        // ---------------- X results
        xr0 <= x0_res; xr1 <= alu1_y;
        br_rob <= x0_pay[4:0]; br_ctl <= x0_ctl; br_mis <= x0_mis; br_taken <= x0_taken;
        br_exc <= x0_texc; br_next <= x0_next; br_tgt <= x0_tgt; br_seq <= x0_seq;
        br_call <= x0_pay[110]; br_ret <= x0_pay[111]; br_rasp <= x0_pay[114:112];
        br_hb <= x0_pay[44] ^ x0_pay[45] ^ x0_pay[47];
        if (x0_v && x0_pay[115]) csr_src <= x0_pay[116] ? x0_imm : a0;
        c1_rob <= x1_pay[4:0];
        mul2_pd <= x1_pd; mul2_wen <= x1_pay[5]; mul2_rob <= x1_pay[4:0]; mul2_hi <= (x1_mop != 2'd0);
        mul3_pd <= mul2_pd; mul3_wen <= mul2_wen; mul3_rob <= mul2_rob; mul3_hi <= mul2_hi;
        cm_rob <= mul3_rob;
        // ---------------- CSR write-back at commit
        csr_wb_v <= 1'b0;
        // ---------------- ROB per-entry results
        if (br_v && br_ctl) rob_taken[br_rob] <= br_taken;

        if (!resetn) begin
            ds_v0 <= 1'b0; ds_v1 <= 1'b0;
            q0a_v <= 1'b0; q0b_v <= 1'b0; q1a_v <= 1'b0; q1b_v <= 1'b0; qma_v <= 1'b0; qmb_v <= 1'b0;
            r0_v <= 1'b0; r1_v <= 1'b0; x0_v <= 1'b0; x1_v <= 1'b0;
            br_v <= 1'b0; c1_v <= 1'b0; mul2_v <= 1'b0; mul3_v <= 1'b0; cm_v <= 1'b0;
            flush_r <= 1'b0; flush_fe <= 1'b0; flush_tgt <= 32'd0; irq_req <= 1'b0;
            rn_block <= 1'b0; serial_pend <= 1'b0; dec_redir_r <= 1'b0; pend_rob <= 5'd0;
            h0_v <= 1'b0; h1_v <= 1'b0; rob_h <= 5'd0; rob_h1 <= 5'd1; rob_t <= 5'd0; rob_n <= 6'd0;
            rob_done <= 32'd0; rob_exc <= 32'd0; rob_mis <= 32'd0;
            fl_h <= 6'd0; fl_t <= 6'd32; fl_t1 <= 5'd1; fl_ch <= 6'd0;
            prdy <= {64{1'b1}};
            for (i = 0; i < 32; i = i + 1) begin
                rat[i] <= i[5:0]; crat[i] <= i[5:0]; fl[i] <= 6'd32 + i[5:0];
            end
        end else begin
            // ================= pipeline valid bits
            ds_v0 <= take0 && !flush; ds_v1 <= take1 && !flush;
            q0a_v <= take0 && !flush && rt0 == `RT_IQ0; q0b_v <= take1 && !flush && rt1 == `RT_IQ0;
            q1a_v <= take0 && !flush && rt0 == `RT_IQ1; q1b_v <= take1 && !flush && rt1 == `RT_IQ1;
            qma_v <= take0 && !flush && rt0 == `RT_IQM; qmb_v <= take1 && !flush && rt1 == `RT_IQM;
            r0_v <= iq0_sv && !flush; r1_v <= iq1_sv && !flush;
            x0_v <= r0_v && !flush;   x1_v <= r1_v && !flush;
            br_v <= x0_v && !flush;
            c1_v <= x1_v && !x1_mul && !flush;
            mul2_v <= x1_v && x1_mul && !flush;
            mul3_v <= mul2_v && !flush;
            cm_v <= mul3_v && !flush;

            // ================= free list / RAT
            if (flush) begin
                for (i = 0; i < 32; i = i + 1) rat[i] <= crat[i];
                fl_h <= fl_ch;
                prdy <= {64{1'b1}};
            end else begin
                if (alloc0) rat[d0_rd] <= new0;
                if (alloc1) rat[d1_rd] <= new1;
                fl_h <= fl_h + {5'd0, alloc0} + {5'd0, alloc1};
                // ready bits: set by broadcasts, cleared by allocation
                for (i = 0; i < 64; i = i + 1) begin
                    if (wkm(i[5:0])) prdy[i] <= 1'b1;
                end
                if (ds_v0 && ds_wen0) prdy[ds_pd0] <= 1'b0;
                if (ds_v1 && ds_wen1) prdy[ds_pd1] <= 1'b0;
            end
            // commit: free old mappings, update committed RAT
            if (cw0) begin
                crat[h0_rd] <= h0_pd;
                fl[fl_t[4:0]] <= h0_old;
            end
            if (cw1) begin
                crat[h1_rd] <= h1_pd;
                fl[cw0 ? fl_t1 : fl_t[4:0]] <= h1_old;
            end
            fl_t  <= fl_t  + {5'd0, cw0} + {5'd0, cw1};
            fl_t1 <= fl_t1 + {4'd0, cw0} + {4'd0, cw1};
            fl_ch <= fl_ch + {5'd0, cw0} + {5'd0, cw1};

            // ================= ROB pointers / flags
            for (i = 0; i < 32; i = i + 1) begin
                // completion
                if ((br_v && br_rob == i[4:0]) || (c1_v && c1_rob == i[4:0]) || (cm_v && cm_rob == i[4:0]) ||
                    (ca_v && ca_rob == i[4:0]) || (cr_v && cr_rob == i[4:0]))
                    rob_done[i] <= 1'b1;
            end
            if (br_v) begin
                rob_mis[br_rob] <= br_mis && br_ctl && !br_exc;
                if (br_exc) begin rob_exc[br_rob] <= 1'b1; rob_cause[br_rob] <= `EXC_IMISALIGN; end
            end
            if (ca_v && ca_exc) begin rob_exc[ca_rob] <= 1'b1; rob_cause[ca_rob] <= ca_cause; end
            if (cr_v && cr_exc) begin rob_exc[cr_rob] <= 1'b1; rob_cause[cr_rob] <= `EXC_LFAULT; end
            // dispatch (DS) initialises flags; ops with no execution complete now
            if (ds_v0) begin
                rob_exc[ds_rob0] <= ds_exc0; rob_cause[ds_rob0] <= ds_cause0; rob_mis[ds_rob0] <= 1'b0; rob_ff[ds_rob0] <= ds_fx0;
                rob_done[ds_rob0] <= (ds_rt0 == `RT_NONE);
            end
            if (ds_v1) begin
                rob_exc[ds_rob1] <= ds_exc1; rob_cause[ds_rob1] <= ds_cause1; rob_mis[ds_rob1] <= 1'b0; rob_ff[ds_rob1] <= ds_fx1;
                rob_done[ds_rob1] <= (ds_rt1 == `RT_NONE);
            end
            // commit
            if (n_commit != 2'd0) begin
                rob_done[rob_h] <= 1'b0;
                if (n_commit == 2'd2) rob_done[rob_h1] <= 1'b0;
            end
            rob_h <= rob_h + {3'd0, n_commit};
            rob_h1 <= rob_h1 + {3'd0, n_commit};
            if (flush) begin
                rob_t <= rob_h; rob_n <= 6'd0; rob_done <= 32'd0; h0_v <= 1'b0; h1_v <= 1'b0;
            end else begin
                rob_t <= rob_t + {3'd0, ib_pop};
                rob_n <= rob_n + {4'd0, ib_pop} - {4'd0, n_commit};
                h0_v <= (rob_n + {4'd0, ib_pop} - {4'd0, n_commit}) != 6'd0;
                h1_v <= (rob_n + {4'd0, ib_pop} - {4'd0, n_commit}) >= 6'd2;
            end

            // ================= CSR execution at commit
            if (c0_csr && !c0_csr_bad && h0_wen) begin
                csr_wb_v <= 1'b1; csr_wb_pd <= h0_pd; csr_wb_val <= csr_rdata;
            end

            // ================= serialisation / redirect bookkeeping
            if (take0 && u0_serial) serial_pend <= 1'b1;
            if (c0_norm && h0_sys != `SYS_NONE) serial_pend <= 1'b0;
            if (br_redir) begin rn_block <= 1'b1; pend_rob <= br_rob; end
            dec_redir_r <= 1'b0;
            // decode fix-up: ignored when an older redirect is pending/happening
            if (!rn_block && !br_redir && !flush) begin
                if (ds_fx0) begin
                    rn_block <= 1'b1; pend_rob <= ds_rob0;
                    dec_redir_r <= 1'b1; dec_redir_pc <= ds_fpc0;
                    dec_ras_push <= ds_call0 && ds_jal0; dec_ras_ret <= 1'b0;
                    dec_ras_ptr <= ds_rasp0; dec_ras_addr <= ds_pc0 + 32'd4;
                    dec_pid <= ds_pid0; dec_tk <= ds_jal0; dec_hb <= ds_pc0[2] ^ ds_pc0[3] ^ ds_pc0[5];
                end else if (ds_fx1) begin
                    rn_block <= 1'b1; pend_rob <= ds_rob1;
                    dec_redir_r <= 1'b1; dec_redir_pc <= ds_fpc1;
                    dec_ras_push <= ds_call1 && ds_jal1; dec_ras_ret <= 1'b0;
                    dec_ras_ptr <= ds_rasp1; dec_ras_addr <= ds_pc1 + 32'd4;
                    dec_pid <= ds_pid1; dec_tk <= ds_jal1; dec_hb <= ds_pc1[2] ^ ds_pc1[3] ^ ds_pc1[5];
                end
            end

            irq_req <= (|(irq_pending & irq_enable)) && irq_gie && !c_trap && !c0_mret;
            // ================= flush generation (takes effect next cycle)
            flush_r <= 1'b0; flush_fe <= 1'b0;
            if (c_trap) begin
                flush_r <= 1'b1; flush_fe <= 1'b1; flush_tgt <= trap_target;
            end else if (c0_mret) begin
                flush_r <= 1'b1; flush_fe <= 1'b1; flush_tgt <= mret_target;
            end else if (c0_fencei) begin
                flush_r <= 1'b1; flush_fe <= 1'b1; flush_tgt <= h0_pc + 32'd4;
            end else if (c0_mis) begin
                flush_r <= 1'b1; flush_fe <= 1'b0;
            end
            if (flush) begin
                rn_block <= 1'b0; serial_pend <= 1'b0; dec_redir_r <= 1'b0;
            end
        end
    end
    // stores committed this cycle go straight to the LSU
    always @* st_commit = {1'b0, c0_norm && h0_st} + {1'b0, c1_norm && h1_st};

    // ======================================================================
    // debug / perf
    // ======================================================================
    assign dbg_cvalid = {c1_norm, c0_norm};
    assign dbg_c0_pc = h0_pc; assign dbg_c1_pc = h1_pc;
    assign dbg_c0_wen = h0_wen; assign dbg_c1_wen = h1_wen;
    assign dbg_c0_rd = h0_rd; assign dbg_c1_rd = h1_rd;
    assign dbg_c0_pdst = h0_pd; assign dbg_c1_pdst = h1_pd;
    assign dbg_trap = c_trap;
    assign perf_ev = {c_trap, c0_mis, br_redir, dec_redir_r, take1, take0, c1_norm, c0_norm};
endmodule

// ----------------------------------------------------------------------------
module ooo_alu (
    input  wire [3:0]  op,
    input  wire [31:0] a, b,
    output reg  [31:0] y
);
    wire [31:0] sum  = a + b;
    wire [31:0] diff = a - b;
    always @* begin
        case (op)
        `ALU_ADD:   y = sum;
        `ALU_SUB:   y = diff;
        `ALU_SLL:   y = a << b[4:0];
        `ALU_SLT:   y = {31'd0, $signed(a) < $signed(b)};
        `ALU_SLTU:  y = {31'd0, a < b};
        `ALU_XOR:   y = a ^ b;
        `ALU_SRL:   y = a >> b[4:0];
        `ALU_SRA:   y = $signed(a) >>> b[4:0];
        `ALU_OR:    y = a | b;
        `ALU_AND:   y = a & b;
        `ALU_LINK:  y = a + 32'd4;
        default:    y = b;
        endcase
    end
endmodule
