// ============================================================================
// ooo_decode  --  combinational RV32IM + Zicsr decoder for one instruction.
// Produces a "micro-op" description used by rename / dispatch.
// ============================================================================
`include "ooo_defs.vh"
module ooo_decode (
    input  wire [31:0] inst,
    output reg  [4:0]  rs1, rs2, rd,
    output reg         use1, use2,     // reads rs1 / rs2 from the register file
    output reg         wen,            // writes rd (rd != x0)
    output reg  [3:0]  alu_op,
    output reg         src1_pc,        // operand 1 = PC   (AUIPC)
    output reg         src2_imm,       // operand 2 = imm
    output reg  [31:0] imm,
    // control flow
    output reg         is_br,          // conditional branch
    output reg         is_jal,
    output reg         is_jalr,
    output reg         is_call,
    output reg         is_ret,
    // functional class
    output reg         is_mul,
    output reg  [1:0]  mul_op,         // 0 mul, 1 mulh, 2 mulhsu, 3 mulhu
    output reg         is_load,
    output reg         is_store,
    output reg  [1:0]  mem_size,
    output reg         mem_unsigned,
    output reg  [2:0]  sys_op,         // `SYS_*
    output reg  [1:0]  csr_op,         // 1 RW, 2 RS, 3 RC
    output reg         csr_imm,        // uses zimm (rs1 field) instead of rs1
    output reg         illegal
);
    wire [6:0] opc = inst[6:0];
    wire [2:0] f3  = inst[14:12];
    wire [6:0] f7  = inst[31:25];
    wire [31:0] imm_i = {{20{inst[31]}}, inst[31:20]};
    wire [31:0] imm_s = {{20{inst[31]}}, inst[31:25], inst[11:7]};
    wire [31:0] imm_b = {{19{inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0};
    wire [31:0] imm_u = {inst[31:12], 12'b0};
    wire [31:0] imm_j = {{11{inst[31]}}, inst[31], inst[19:12], inst[20], inst[30:21], 1'b0};
    wire rd_link  = (inst[11:7] == 5'd1) || (inst[11:7] == 5'd5);
    wire rs1_link = (inst[19:15] == 5'd1) || (inst[19:15] == 5'd5);

    always @* begin
        rs1 = inst[19:15]; rs2 = inst[24:20]; rd = inst[11:7];
        use1 = 1'b0; use2 = 1'b0; wen = 1'b0;
        alu_op = `ALU_ADD; src1_pc = 1'b0; src2_imm = 1'b0; imm = 32'b0;
        is_br = 1'b0; is_jal = 1'b0; is_jalr = 1'b0; is_call = 1'b0; is_ret = 1'b0;
        is_mul = 1'b0; mul_op = 2'd0; is_load = 1'b0; is_store = 1'b0;
        mem_size = 2'd0; mem_unsigned = 1'b0;
        sys_op = `SYS_NONE; csr_op = 2'd0; csr_imm = 1'b0; illegal = 1'b0;
        case (opc)
        7'b0110111: begin // LUI
            wen = 1'b1; alu_op = `ALU_PASSB; src2_imm = 1'b1; imm = imm_u;
        end
        7'b0010111: begin // AUIPC
            wen = 1'b1; alu_op = `ALU_ADD; src1_pc = 1'b1; src2_imm = 1'b1; imm = imm_u;
        end
        7'b1101111: begin // JAL
            wen = 1'b1; is_jal = 1'b1; imm = imm_j; is_call = rd_link;
            alu_op = `ALU_LINK; src1_pc = 1'b1;     // link value from the ALU
        end
        7'b1100111: begin // JALR
            if (f3 != 3'b000) illegal = 1'b1;
            wen = 1'b1; use1 = 1'b1; is_jalr = 1'b1; imm = imm_i;
            alu_op = `ALU_LINK; src1_pc = 1'b1;     // target uses rs1 directly
            is_call = rd_link;
            is_ret  = rs1_link && (inst[11:7] == 5'd0) && (inst[31:20] == 12'd0);
        end
        7'b1100011: begin // branches
            if (f3 == 3'b010 || f3 == 3'b011) illegal = 1'b1;
            use1 = 1'b1; use2 = 1'b1; is_br = 1'b1; imm = imm_b;
        end
        7'b0000011: begin // loads
            use1 = 1'b1; wen = 1'b1; is_load = 1'b1; imm = imm_i;
            mem_size = f3[1:0]; mem_unsigned = f3[2];
            if (f3 == 3'b011 || f3 == 3'b110 || f3 == 3'b111) illegal = 1'b1;
        end
        7'b0100011: begin // stores
            use1 = 1'b1; use2 = 1'b1; is_store = 1'b1; imm = imm_s; mem_size = f3[1:0];
            if (f3[2] || f3[1:0] == 2'b11) illegal = 1'b1;
        end
        7'b0010011: begin // OP-IMM
            use1 = 1'b1; wen = 1'b1; src2_imm = 1'b1; imm = imm_i;
            case (f3)
            3'b000: alu_op = `ALU_ADD;
            3'b010: alu_op = `ALU_SLT;
            3'b011: alu_op = `ALU_SLTU;
            3'b100: alu_op = `ALU_XOR;
            3'b110: alu_op = `ALU_OR;
            3'b111: alu_op = `ALU_AND;
            3'b001: begin alu_op = `ALU_SLL; if (f7 != 7'b0) illegal = 1'b1; end
            3'b101: begin
                alu_op = f7[5] ? `ALU_SRA : `ALU_SRL;
                if (f7 != 7'b0 && f7 != 7'b0100000) illegal = 1'b1;
            end
            endcase
        end
        7'b0110011: begin // OP
            use1 = 1'b1; use2 = 1'b1; wen = 1'b1;
            if (f7 == 7'b0000001) begin
                if (!f3[2]) begin is_mul = 1'b1; mul_op = f3[1:0]; end
                else illegal = 1'b1;               // no divider (Zmmul)
            end else if (f7 == 7'b0000000 || (f7 == 7'b0100000 && (f3 == 3'b000 || f3 == 3'b101))) begin
                case (f3)
                3'b000: alu_op = f7[5] ? `ALU_SUB : `ALU_ADD;
                3'b001: alu_op = `ALU_SLL;
                3'b010: alu_op = `ALU_SLT;
                3'b011: alu_op = `ALU_SLTU;
                3'b100: alu_op = `ALU_XOR;
                3'b101: alu_op = f7[5] ? `ALU_SRA : `ALU_SRL;
                3'b110: alu_op = `ALU_OR;
                3'b111: alu_op = `ALU_AND;
                endcase
            end else illegal = 1'b1;
        end
        7'b0001111: begin // FENCE / FENCE.I
            if (f3 == 3'b001) sys_op = `SYS_FENCEI;
            else sys_op = `SYS_FENCE;
        end
        7'b1110011: begin // SYSTEM
            if (f3 == 3'b000) begin
                case (inst[31:7])
                25'h0000000: sys_op = `SYS_ECALL;
                25'h0002000: sys_op = `SYS_EBREAK;
                25'h0604000: sys_op = `SYS_MRET;     // 0x30200073
                25'h020a000: sys_op = `SYS_WFI;      // 0x10500073
                default:     illegal = 1'b1;
                endcase
            end else if (f3 == 3'b100) illegal = 1'b1;
            else begin
                sys_op = `SYS_CSR; csr_op = f3[1:0]; csr_imm = f3[2];
                use1 = !f3[2]; wen = 1'b1; alu_op = `ALU_PASSB;
                imm = {27'b0, inst[19:15]};            // zimm (used when csr_imm)
            end
        end
        default: illegal = 1'b1;
        endcase
        if (rd == 5'd0) wen = 1'b0;
        if (!use1) rs1 = 5'd0;
        if (!use2) rs2 = 5'd0;
        if (illegal) begin
            wen = 1'b0; use1 = 1'b0; use2 = 1'b0; rs1 = 5'd0; rs2 = 5'd0;
            is_br = 1'b0; is_jal = 1'b0; is_jalr = 1'b0; is_call = 1'b0; is_ret = 1'b0;
            is_mul = 1'b0; is_load = 1'b0; is_store = 1'b0; sys_op = `SYS_NONE;
        end
    end
endmodule
