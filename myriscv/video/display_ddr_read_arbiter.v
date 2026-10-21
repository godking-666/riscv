`timescale 1ns/1ps
//=============================================================================
// display_ddr_read_arbiter.v —— 显示读与既有读链的锁定式仲裁
//
// 把显示读作为「最后一个读源」插在既有读链（cpu+preprocess+cnn 仲裁后的
// axi_ar*/axi_r*）与 DDR3 IP 之间。语义沿用 preprocess_ddr_read_arbiter：
// 一次只放行一个源，锁到整条 burst 数完 remaining 才换下一个，用 rid 校验响应。
//
// 差异：
//   * disp 侧用固定 DISP_LEN 长突发（显示按 16 beat 突发读帧）
//   * 把 rlast/rid 透传给 cpu（既有链）侧，使其内部校验逻辑继续可用
//=============================================================================
module display_ddr_read_arbiter #(
    parameter [3:0] DISP_ID  = 4'd8,
    parameter [3:0] DISP_LEN = 4'd15      // 16 beats（256bit × 16 = 512 B）
) (
    input  wire        clk, resetn,
    // ---- cpu 侧 = 既有读链（addr/len/id/ap 原样透传）----
    input  wire [27:0] cpu_addr,
    input  wire [3:0]  cpu_len, cpu_id,
    input  wire        cpu_ap, cpu_valid,
    output wire        cpu_ready, cpu_rvalid,
    output wire        cpu_rlast,
    output wire [3:0]  cpu_rid,
    // ---- disp 侧 = 显示读 ----
    input  wire [27:0] disp_addr,
    input  wire        disp_valid,
    output wire        disp_ready, disp_rvalid,
    output wire        disp_rlast,
    // ---- 合并后的 AR/R → DDR3 IP ----
    output wire [27:0] araddr,
    output wire [3:0]  arlen, arid,
    output wire        arap, arvalid,
    input  wire        arready, rvalid, rlast,
    input  wire [3:0]  rid,
    output reg         protocol_error
);
    localparam IDLE=0, ADDR=1, DATA=2;
    reg [1:0]  state;
    reg        owner, last_owner;
    reg [4:0]  remaining;
    reg [3:0]  accepted_id;

    wire ar_fire = arvalid && arready;
    wire response_window = (state==DATA) || ar_fire;
    wire [4:0] beats_left = (state==DATA) ? remaining : {1'b0, arlen} + 5'd1;
    wire [3:0] expected_id = (state==DATA) ? accepted_id : arid;
    // 畸形响应隔离，绝不下发给 cpu/显示
    wire r_fire = resetn && !protocol_error && rvalid && response_window &&
                  rid==expected_id && rlast==(beats_left==1);

    assign arvalid = resetn && !protocol_error && state==ADDR && (owner ? disp_valid : cpu_valid);
    assign araddr  = owner ? disp_addr : cpu_addr;
    assign arlen   = owner ? DISP_LEN  : cpu_len;
    assign arid    = owner ? DISP_ID   : cpu_id;
    assign arap    = owner ? 1'b0      : cpu_ap;

    assign cpu_ready  = resetn && !protocol_error && !owner && state==ADDR && arready;
    assign disp_ready = resetn && !protocol_error &&  owner && state==ADDR && arready;

    assign cpu_rvalid  = r_fire && !owner;
    assign disp_rvalid = r_fire &&  owner;
    // rlast/rid 仅在对应 rvalid 有效时才有意义，消费端用 rvalid 门控即可
    assign cpu_rlast  = rlast;
    assign cpu_rid    = rid;
    assign disp_rlast = rlast;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            state<=IDLE; owner<=0; last_owner<=1; remaining<=0; accepted_id<=0; protocol_error<=0;
        end else if (!protocol_error) begin
            case (state)
                IDLE: if (cpu_valid || disp_valid) begin
                    owner <= (cpu_valid && disp_valid) ? !last_owner : disp_valid;
                    state <= ADDR;
                end
                ADDR: if (ar_fire) begin
                    remaining <= {1'b0, arlen} + 5'd1;
                    accepted_id <= arid;
                    state <= DATA;
                end
                default: begin end
            endcase
            if (rvalid) begin
                if (!response_window || rid!=expected_id || rlast!=(beats_left==1))
                    protocol_error <= 1;
                else begin
                    remaining <= beats_left - 1'b1;
                    if (beats_left==1) begin state<=IDLE; last_owner<=owner; end
                end
            end
        end
    end
endmodule
