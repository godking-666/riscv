// ============================================================================
// ooo_defs.vh  --  shared constants for the 2-wide out-of-order core (ooo_*)
// ============================================================================
`ifndef OOO_DEFS_VH
`define OOO_DEFS_VH

// ALU operation codes (4 bits)
`define ALU_ADD   4'd0
`define ALU_SUB   4'd1
`define ALU_SLL   4'd2
`define ALU_SLT   4'd3
`define ALU_SLTU  4'd4
`define ALU_XOR   4'd5
`define ALU_SRL   4'd6
`define ALU_SRA   4'd7
`define ALU_OR    4'd8
`define ALU_AND   4'd9
`define ALU_PASSB 4'd10   // LUI / CSR operand pass-through
`define ALU_LINK  4'd11   // JAL / JALR link value: a + 4 (a = pc)

// Branch / jump type held in the BTB
`define BT_COND   2'd0
`define BT_JAL    2'd1
`define BT_JALR   2'd2
`define BT_RET    2'd3

// Issue-queue routing chosen at rename
`define RT_NONE   2'd0    // completes at dispatch (system ops, decode exceptions)
`define RT_IQ0    2'd1    // ALU lane 0 (+ branches, CSR operand)
`define RT_IQ1    2'd2    // ALU lane 1 (+ multiplier)
`define RT_IQM    2'd3    // memory pipe

// System op encoding (one-hot-ish 3 bits)
`define SYS_NONE   3'd0
`define SYS_CSR    3'd1
`define SYS_ECALL  3'd2
`define SYS_EBREAK 3'd3
`define SYS_MRET   3'd4
`define SYS_WFI    3'd5
`define SYS_FENCE  3'd6
`define SYS_FENCEI 3'd7

// Exception causes
`define EXC_IMISALIGN 5'd0
`define EXC_IFAULT    5'd1
`define EXC_ILLEGAL   5'd2
`define EXC_BREAK     5'd3
`define EXC_LMISALIGN 5'd4
`define EXC_LFAULT    5'd5
`define EXC_SMISALIGN 5'd6
`define EXC_SFAULT    5'd7
`define EXC_ECALL     5'd11

`endif
