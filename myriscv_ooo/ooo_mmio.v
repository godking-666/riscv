// ============================================================================
// ooo_mmio  --  system registers at 0x1000_0000 (4 KiB window)
//   0x00 SCRATCH   rw
//   0x04 ID        ro  "OOO2"
//   0x08 CYCLE     ro  free-running cycle counter, low word (CoreMark timer)
//   0x0C STATUS    ro  0
//   0x10 TEST_STAT rw  [1:0] 0 idle / 1 run / 2 pass / 3 fail (drives LED)
//   0x14 LED       rw  [7:0] user LEDs
//   0x18 CLK_HZ    ro  CPU clock frequency
//   0x1C CYCLE_HI  ro  cycle counter, high word
//   0x20/0x24 MTIME      ro  (= cycle counter)
//   0x28/0x2C MTIMECMP   rw  timer interrupt when MTIME >= MTIMECMP
//   0x30 MSIP      rw  [0] software interrupt
// Always ready; responds in the next cycle.
// ============================================================================
module ooo_mmio #(
    parameter integer CLK_HZ = 100_000_000
) (
    input  wire        clk,
    input  wire        resetn,
    input  wire        req_valid,
    input  wire        req_write,
    input  wire [11:0] req_addr,
    input  wire [31:0] req_wdata,
    input  wire [3:0]  req_wstrb,
    output reg         rsp_valid,
    output reg  [31:0] rsp_rdata,
    output reg  [1:0]  test_status,
    output reg  [7:0]  led,
    output wire        irq_timer,
    output wire        irq_soft
);
    reg [31:0] scratch;
    reg [63:0] cycle, mtimecmp;
    reg        msip;
    assign irq_timer = (cycle >= mtimecmp);
    assign irq_soft  = msip;
    function [31:0] merge;
        input [31:0] o, n; input [3:0] s;
        begin
            merge = {s[3] ? n[31:24] : o[31:24], s[2] ? n[23:16] : o[23:16],
                     s[1] ? n[15:8]  : o[15:8],  s[0] ? n[7:0]   : o[7:0]};
        end
    endfunction
    always @(posedge clk) begin
        if (!resetn) begin
            cycle <= 64'd0; mtimecmp <= 64'hffff_ffff_ffff_ffff; msip <= 1'b0;
            scratch <= 32'd0; test_status <= 2'd0; led <= 8'd0;
            rsp_valid <= 1'b0; rsp_rdata <= 32'd0;
        end else begin
            cycle <= cycle + 64'd1;
            rsp_valid <= req_valid;
            if (req_valid && !req_write) begin
                case (req_addr[11:2])
                10'h00: rsp_rdata <= scratch;
                10'h01: rsp_rdata <= 32'h4f4f_4f32;
                10'h02: rsp_rdata <= cycle[31:0];
                10'h04: rsp_rdata <= {30'd0, test_status};
                10'h05: rsp_rdata <= {24'd0, led};
                10'h06: rsp_rdata <= CLK_HZ;
                10'h07: rsp_rdata <= cycle[63:32];
                10'h08: rsp_rdata <= cycle[31:0];
                10'h09: rsp_rdata <= cycle[63:32];
                10'h0a: rsp_rdata <= mtimecmp[31:0];
                10'h0b: rsp_rdata <= mtimecmp[63:32];
                10'h0c: rsp_rdata <= {31'd0, msip};
                default: rsp_rdata <= 32'd0;
                endcase
            end
            if (req_valid && req_write) begin
                case (req_addr[11:2])
                10'h00: scratch <= merge(scratch, req_wdata, req_wstrb);
                10'h04: if (req_wstrb[0]) test_status <= req_wdata[1:0];
                10'h05: if (req_wstrb[0]) led <= req_wdata[7:0];
                10'h0a: mtimecmp[31:0]  <= merge(mtimecmp[31:0], req_wdata, req_wstrb);
                10'h0b: mtimecmp[63:32] <= merge(mtimecmp[63:32], req_wdata, req_wstrb);
                10'h0c: if (req_wstrb[0]) msip <= req_wdata[0];
                default: ;
                endcase
            end
        end
    end
endmodule
