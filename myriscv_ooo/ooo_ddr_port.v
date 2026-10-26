// ============================================================================
// ooo_ddr_port  --  cache line port -> Pango DDR3 IP (reduced AXI), across
//                   the CPU clock domain and the DDR core_clk domain.
//
// CPU side: two line ports (I-cache read-only, D-cache read/write), D first.
// One line transfer is in flight at a time.  Clock crossing uses a mailbox:
// the request fields are held stable in the CPU domain while a toggle is
// synchronised into core_clk; the read data is held stable in the DDR domain
// while the acknowledge toggle is synchronised back.  Only the two toggles
// need synchronisers; the data buses are quasi-static (set false-path /
// max-delay constraints on mb_* and rd_buf in the .fdc).
//
// DDR side: one burst per line, BEATS = LINE/32 beats of 256 bits
// (x32 DDR3, BL8).  Address unit = 32-bit word, beat aligned (low 3 bits 0).
// Reduced AXI as used by the IP: no WVALID (data held stable, one beat taken
// per WREADY), no RREADY (every RVALID beat must be taken).
// ============================================================================
module ooo_ddr_port #(
    parameter integer LINE = 64,
    parameter integer CTRL_ADDR_WIDTH = 28
) (
    // ---------------- CPU domain
    input  wire               clk, resetn,
    input  wire               i_valid,
    input  wire [31:0]        i_addr,
    output wire               i_ready,
    output reg                i_rsp_valid,
    output wire [LINE*8-1:0]  i_rsp_data,
    output wire               i_rsp_error,
    input  wire               d_valid,
    input  wire               d_we,
    input  wire [31:0]        d_addr,
    input  wire [LINE*8-1:0]  d_wdata,
    output wire               d_ready,
    output reg                d_rsp_valid,
    output wire [LINE*8-1:0]  d_rsp_data,
    output wire               d_rsp_error,
    // ---------------- DDR domain
    input  wire               ddr_clk,
    input  wire               ddr_resetn,
    input  wire               ddr_init_done,
    output wire [CTRL_ADDR_WIDTH-1:0] axi_awaddr,
    output wire               axi_awuser_ap,
    output wire [3:0]         axi_awuser_id,
    output wire [3:0]         axi_awlen,
    input  wire               axi_awready,
    output wire               axi_awvalid,
    output wire [255:0]       axi_wdata,
    output wire [31:0]        axi_wstrb,
    input  wire               axi_wready,
    output wire [CTRL_ADDR_WIDTH-1:0] axi_araddr,
    output wire               axi_aruser_ap,
    output wire [3:0]         axi_aruser_id,
    output wire [3:0]         axi_arlen,
    input  wire               axi_arready,
    output wire               axi_arvalid,
    input  wire [255:0]       axi_rdata,
    input  wire               axi_rvalid
);
    localparam integer BEATS = LINE / 32;
    localparam integer BB = (BEATS <= 1) ? 1 : $clog2(BEATS);

    // ===================================================== CPU domain
    reg               busy, owner_d;       // owner of the transfer in flight
    reg               mb_we;
    reg  [31:0]       mb_addr;
    reg  [LINE*8-1:0] mb_wdata;
    reg               req_tgl;
    reg  [2:0]        ack_s;               // synchroniser + edge detect
    wire [LINE*8-1:0] rd_buf;
    wire ack_edge = ack_s[2] ^ ack_s[1];

    assign d_ready = !busy;
    assign i_ready = !busy && !d_valid;
    assign i_rsp_data = rd_buf;  assign i_rsp_error = 1'b0;
    assign d_rsp_data = rd_buf;  assign d_rsp_error = 1'b0;

    always @(posedge clk) begin
        if (!resetn) begin
            busy <= 1'b0; req_tgl <= 1'b0; ack_s <= 3'b000;
            i_rsp_valid <= 1'b0; d_rsp_valid <= 1'b0;
        end else begin
            ack_s <= {ack_s[1:0], ack_tgl};
            i_rsp_valid <= 1'b0; d_rsp_valid <= 1'b0;
            if (!busy) begin
                if (d_valid) begin
                    busy <= 1'b1; owner_d <= 1'b1; mb_we <= d_we; mb_addr <= d_addr;
                    mb_wdata <= d_wdata; req_tgl <= !req_tgl;
                end else if (i_valid) begin
                    busy <= 1'b1; owner_d <= 1'b0; mb_we <= 1'b0; mb_addr <= i_addr;
                    req_tgl <= !req_tgl;
                end
            end else if (ack_edge) begin
                busy <= 1'b0;
                if (owner_d) d_rsp_valid <= 1'b1; else i_rsp_valid <= 1'b1;
            end
        end
    end

    // ===================================================== DDR domain
    reg  [2:0]  req_s;
    reg         ack_tgl;
    reg  [LINE*8-1:0] rbuf;
    assign rd_buf = rbuf;
    localparam [2:0] D_IDLE = 3'd0, D_AR = 3'd1, D_R = 3'd2, D_AW = 3'd3, D_W = 3'd4, D_DONE = 3'd5;
    reg  [2:0]  dst;
    reg  [BB:0] rcnt, wcnt;
    reg  [CTRL_ADDR_WIDTH-1:0] caddr;
    wire req_edge = req_s[2] ^ req_s[1];
    reg  req_pend;

    assign axi_awaddr = caddr;  assign axi_araddr = caddr;
    assign axi_awuser_ap = 1'b0; assign axi_aruser_ap = 1'b0;
    assign axi_awuser_id = 4'd1; assign axi_aruser_id = 4'd0;
    assign axi_awlen = BEATS - 1; assign axi_arlen = BEATS - 1;
    assign axi_awvalid = (dst == D_AW);
    assign axi_arvalid = (dst == D_AR);
    assign axi_wdata = mb_wdata[wcnt[BB-1:0]*256 +: 256];
    assign axi_wstrb = 32'hffff_ffff;
    wire w_take = ((dst == D_AW) && axi_awready && axi_wready) || ((dst == D_W) && axi_wready);
    wire r_take = ((dst == D_AR) || (dst == D_R)) && axi_rvalid;

    always @(posedge ddr_clk) begin
        if (!ddr_resetn) begin
            req_s <= 3'b000; ack_tgl <= 1'b0; dst <= D_IDLE; rcnt <= 0; wcnt <= 0;
        end else begin
            req_s <= {req_s[1:0], req_tgl};
            if (r_take) begin
                rbuf[rcnt[BB-1:0]*256 +: 256] <= axi_rdata;
                rcnt <= rcnt + 1'b1;
            end
            if (w_take) wcnt <= wcnt + 1'b1;
            case (dst)
            D_IDLE: begin
                if (req_pend && ddr_init_done) begin
                    caddr <= {mb_addr[CTRL_ADDR_WIDTH+1:5], 3'b000};
                    rcnt <= 0; wcnt <= 0;
                    dst <= mb_we ? D_AW : D_AR;
                end
            end
            D_AR: if (axi_arready) dst <= D_R;
            D_R:  if (r_take && rcnt == BEATS - 1) dst <= D_DONE;
            D_AW: if (axi_awready) dst <= (w_take && wcnt == BEATS - 1) ? D_DONE : D_W;
            D_W:  if (w_take && wcnt == BEATS - 1) dst <= D_DONE;
            D_DONE: begin ack_tgl <= !ack_tgl; dst <= D_IDLE; end
            default: dst <= D_IDLE;
            endcase
            // a read whose last beat arrives together with AR acceptance
            if (dst == D_AR && axi_arready && r_take && rcnt == BEATS - 1) dst <= D_DONE;
        end
    end
    // pending request: a toggle edge seen and not yet served
    always @(posedge ddr_clk) begin
        if (!ddr_resetn) req_pend <= 1'b0;
        else if (req_edge) req_pend <= 1'b1;
        else if (dst == D_IDLE && req_pend && ddr_init_done) req_pend <= 1'b0;
    end
endmodule
