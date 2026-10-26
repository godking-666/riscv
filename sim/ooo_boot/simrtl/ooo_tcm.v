// ============================================================================
// ooo_tcm  --  tightly coupled memory shared by instruction and data ports.
// Two 32-bit banks (even / odd words).  The instruction port reads both banks
// at once (64-bit fetch packet); the data port reads/writes one bank.
// Both ports are fully pipelined with a fixed 1-cycle latency.
// Address inputs are local byte offsets (base already removed).
// ============================================================================
module ooo_tcm #(
    parameter integer BYTES = 65536,
    parameter         INIT_EVEN = "",
    parameter         INIT_ODD  = ""
) (
    input  wire        clk,
    input  wire        resetn,
    input  wire        i_valid,
    input  wire [31:0] i_addr,
    output reg         i_rsp_valid,
    output wire [63:0] i_rsp_data,
    input  wire        d_valid,
    input  wire        d_we,
    input  wire [31:0] d_addr,
    input  wire [31:0] d_wdata,
    input  wire [3:0]  d_wstrb,
    output reg         d_rsp_valid,
    output wire [31:0] d_rsp_rdata
);
    localparam integer AW = $clog2(BYTES / 8);
    wire [AW-1:0] ia = i_addr[AW+2:3];
    wire [AW-1:0] da = d_addr[AW+2:3];
    wire [31:0] ie, io, de, dob;
    reg d_odd;
    ooo_tdp_ram32 #(.AW(AW), .INIT_FILE(INIT_EVEN)) u_even (
        .clk(clk), .a_en(i_valid), .a_addr(ia), .a_dout(ie),
        .b_en(d_valid && !d_addr[2]), .b_we((d_we && !d_addr[2]) ? d_wstrb : 4'b0),
        .b_addr(da), .b_din(d_wdata), .b_dout(de));
    ooo_tdp_ram32 #(.AW(AW), .INIT_FILE(INIT_ODD)) u_odd (
        .clk(clk), .a_en(i_valid), .a_addr(ia), .a_dout(io),
        .b_en(d_valid && d_addr[2]), .b_we((d_we && d_addr[2]) ? d_wstrb : 4'b0),
        .b_addr(da), .b_din(d_wdata), .b_dout(dob));
    assign i_rsp_data  = {io, ie};
    assign d_rsp_rdata = d_odd ? dob : de;
    always @(posedge clk) begin
        if (!resetn) begin
            i_rsp_valid <= 1'b0; d_rsp_valid <= 1'b0;
        end else begin
            i_rsp_valid <= i_valid;
            d_rsp_valid <= d_valid;
        end
        if (d_valid) d_odd <= d_addr[2];
    end
endmodule
