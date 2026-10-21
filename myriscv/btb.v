//==============================================================================
// btb.v  --  小型 BTB + 2-bit 饱和计数器分支预测器
//
// 结构:
//   64 项, index = pc[7:2], tag = pc[31:8]
//   每项: valid / tag / target / 2-bit counter
//
// 预测:
//   hit && counter[1] -> 预测 taken, 目标 target
//   否则             -> 预测 not-taken (顺序 pc+4)
//
// 更新:
//   分支/jal/jalr 在 ID 级判定完成时写入; jal/jalr 恒为 taken, 直接把计数器
//   拉到 2'b11, 这样第二次执行就能命中; B 型分支用饱和计数器学习。
//==============================================================================

module btb #(
    parameter INDEX_BITS = 6,
    parameter ENTRIES    = 64
) (
    input  wire        clk,
    input  wire        resetn,

    // IF 级查询
    input  wire [31:0] pc_if,
    output wire        pred_taken,
    output wire [31:0] pred_target,

    // ID 级更新
    input  wire        update_en,
    input  wire [31:0] update_pc,
    input  wire [31:0] update_target,
    input  wire        update_taken,
    input  wire        update_always_taken
);

    localparam TAG_BITS = 32 - INDEX_BITS - 2;

    reg              valid   [0:ENTRIES-1];
    reg [TAG_BITS-1:0] tag   [0:ENTRIES-1];
    reg [31:0]       target  [0:ENTRIES-1];
    reg [1:0]        counter [0:ENTRIES-1];

    wire [INDEX_BITS-1:0] idx_if  = pc_if[INDEX_BITS+1:2];
    wire [TAG_BITS-1:0]   tag_if  = pc_if[31:INDEX_BITS+2];
    wire                  hit_if  = valid[idx_if] && (tag[idx_if] == tag_if);

    assign pred_taken  = hit_if && counter[idx_if][1];
    assign pred_target = target[idx_if];

    wire [INDEX_BITS-1:0] idx_upd = update_pc[INDEX_BITS+1:2];
    wire [TAG_BITS-1:0]   tag_upd = update_pc[31:INDEX_BITS+2];

    integer i;
    always @(posedge clk) begin
        if (!resetn) begin
            for (i = 0; i < ENTRIES; i = i + 1) begin
                valid[i]   <= 1'b0;
                tag[i]     <= {TAG_BITS{1'b0}};
                target[i]  <= 32'h0000_0000;
                counter[i] <= 2'b01;      // weakly not-taken
            end
        end
        else if (update_en) begin
            valid[idx_upd]  <= 1'b1;
            tag[idx_upd]    <= tag_upd;
            target[idx_upd] <= {update_target[31:2], 2'b00};

            if (!valid[idx_upd] || (tag[idx_upd] != tag_upd)) begin
                counter[idx_upd] <= update_always_taken ? 2'b11 :
                                    (update_taken ? 2'b10 : 2'b01);
            end
            else if (update_always_taken) begin
                counter[idx_upd] <= 2'b11;
            end
            else if (update_taken) begin
                counter[idx_upd] <= (counter[idx_upd] == 2'b11) ?
                                    2'b11 : (counter[idx_upd] + 1'b1);
            end
            else begin
                counter[idx_upd] <= (counter[idx_upd] == 2'b00) ?
                                    2'b00 : (counter[idx_upd] - 1'b1);
            end
        end
    end

endmodule
