// ============================================================================
// ooo_ram  --  block-RAM primitives used by the SoC (inference templates).
// Every RAM of the design goes through these two modules, so they can be
// replaced by vendor DRM IP without touching the rest of the RTL.
// ============================================================================

// 32-bit true dual-port RAM: port A read-only, port B read/write (byte enables).
// Both ports: synchronous read, 1-cycle latency, read-first.
module ooo_tdp_ram32 #(
    parameter integer AW = 13,                 // address bits (words)
    parameter         INIT_FILE = ""
) (
    input  wire          clk,
    input  wire          a_en,
    input  wire [AW-1:0] a_addr,
    output reg  [31:0]   a_dout,
    input  wire          b_en,
    input  wire [3:0]    b_we,
    input  wire [AW-1:0] b_addr,
    input  wire [31:0]   b_din,
    output reg  [31:0]   b_dout
);
    (* syn_ramstyle = "block_ram" *) reg [31:0] mem [0:(1<<AW)-1];
    integer i;
    // Program image (hex, one 32-bit word per line).  Block RAM powers up as
    // zero, so the explicit zero fill is simulation-only (a 16K-iteration loop
    // exceeds the synthesis tool's loop limit).
    initial begin
`ifdef OOO_SIM
        for (i = 0; i < (1 << AW); i = i + 1) mem[i] = 32'd0;
`endif
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    end
    always @(posedge clk) if (a_en) a_dout <= mem[a_addr];
    always @(posedge clk) if (b_en) begin
        b_dout <= mem[b_addr];
        if (b_we[0]) mem[b_addr][7:0]   <= b_din[7:0];
        if (b_we[1]) mem[b_addr][15:8]  <= b_din[15:8];
        if (b_we[2]) mem[b_addr][23:16] <= b_din[23:16];
        if (b_we[3]) mem[b_addr][31:24] <= b_din[31:24];
    end
endmodule

// Simple dual-port RAM: one write port (with byte enables), one read port.
module ooo_sdp_ram #(
    parameter integer AW = 8,
    parameter integer DW = 64
) (
    input  wire            clk,
    input  wire [DW/8-1:0] we,
    input  wire [AW-1:0]   waddr,
    input  wire [DW-1:0]   din,
    input  wire            re,
    input  wire [AW-1:0]   raddr,
    output reg  [DW-1:0]   dout
);
    (* syn_ramstyle = "block_ram" *) reg [DW-1:0] mem [0:(1<<AW)-1];
    integer i;
`ifdef OOO_SIM
    initial for (i = 0; i < (1 << AW); i = i + 1) mem[i] = {DW{1'b0}};
`endif
    always @(posedge clk) begin
        for (i = 0; i < DW/8; i = i + 1)
            if (we[i]) mem[waddr][i*8 +: 8] <= din[i*8 +: 8];
    end
    always @(posedge clk) if (re) dout <= mem[raddr];
endmodule
