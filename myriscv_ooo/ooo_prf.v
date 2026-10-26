// ============================================================================
// ooo_prf  --  64 x 32 physical register file, 6 read / 4 write ports.
//
// FPGA implementation: one distributed-RAM bank per write port (each bank is
// replicated per read port by synthesis) plus a Live-Value Table (LVT) that
// records which bank holds the newest value of every register.
// Reads are asynchronous; a write is visible to reads in the next cycle.
// Physical register 0 is the hard-wired zero (never written).
// ============================================================================
module ooo_prf (
    input  wire        clk,
    input  wire        resetn,
    input  wire [3:0]  we,
    input  wire [5:0]  wa0, wa1, wa2, wa3,
    input  wire [31:0] wd0, wd1, wd2, wd3,
    input  wire [5:0]  ra0, ra1, ra2, ra3, ra4, ra5,
    output wire [31:0] rd0, rd1, rd2, rd3, rd4, rd5
);
    // Must be distributed RAM: reads are asynchronous and a value written at a
    // clock edge has to be visible to a read in the very next cycle.
    (* syn_ramstyle = "select_ram" *) reg [31:0] b0 [0:63];
    (* syn_ramstyle = "select_ram" *) reg [31:0] b1 [0:63];
    (* syn_ramstyle = "select_ram" *) reg [31:0] b2 [0:63];
    (* syn_ramstyle = "select_ram" *) reg [31:0] b3 [0:63];
    reg [1:0]  lvt [0:63];
    integer i;
`ifdef OOO_SIM
    initial for (i = 0; i < 64; i = i + 1) begin
        b0[i] = 32'd0; b1[i] = 32'd0; b2[i] = 32'd0; b3[i] = 32'd0;
    end
`endif
    always @(posedge clk) begin
        if (we[0]) b0[wa0] <= wd0;
        if (we[1]) b1[wa1] <= wd1;
        if (we[2]) b2[wa2] <= wd2;
        if (we[3]) b3[wa3] <= wd3;
    end
    always @(posedge clk) begin
        if (!resetn) begin
            for (i = 0; i < 64; i = i + 1) lvt[i] <= 2'd0;
        end else begin
            if (we[0]) lvt[wa0] <= 2'd0;
            if (we[1]) lvt[wa1] <= 2'd1;
            if (we[2]) lvt[wa2] <= 2'd2;
            if (we[3]) lvt[wa3] <= 2'd3;
        end
    end
    function [31:0] rd;
        input [5:0] a;
        begin
            if (a == 6'd0) rd = 32'd0;
            else case (lvt[a])
                2'd0: rd = b0[a];
                2'd1: rd = b1[a];
                2'd2: rd = b2[a];
                default: rd = b3[a];
            endcase
        end
    endfunction
    assign rd0 = rd(ra0); assign rd1 = rd(ra1); assign rd2 = rd(ra2);
    assign rd3 = rd(ra3); assign rd4 = rd(ra4); assign rd5 = rd(ra5);
endmodule
