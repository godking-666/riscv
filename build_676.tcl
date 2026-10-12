#=============================================================================
# build_676.tcl -- 从零创建 PG2L200H-FBB676 新板工程
#
# 用法（★ 必须先 cd 到目标目录，实测 -work_dir 会被忽略）：
#   cd D:\riscv\RISCV_676
#   & "E:\pangu\PDS_2022.2-SP6.4\bin\pds_shell.exe" -file D:/riscv/RISCV/build_676.tcl
#
# 依据：《Pango Design Suite User Guide》5.2/5.3 节
#
# D2 范围：CPU + 片内 ROM/RAM + MMIO + UART + GPIO + **视觉子系统（OV5640）**。
#   core_clk 先走 27MHz 直驱（board_top_676 的 USE_PLL=0）；DDR3 暂不接。
#
# ★★ 关键：PDS ADS 的 rtl_analyze 是**顺序解析**，被例化的模块必须排在例化它的
#    文件**之前**（自底向上）。否则报：
#      E: Verilog-4072: ... vision_top is referenced to undefined module
#    所以文件顺序是：叶子模块 -> 中间层 -> soc_top -> board_top。
#=============================================================================

#-----------------------------------------------------------------------------
# 1) 器件：PG2L200H + FBB676
#    ★ 实测教训：PG2L100H 的封装是 FBG676，**PG2L200H 的封装是 FBB676**。
#      写错报 E: Flow-0148: Package 'FBG676' is not defined for device 'PG2L200H'.
#      厂商 5_1_ov5640 例程位流内即 "PG2L200H + FBB676"，与之吻合。
#-----------------------------------------------------------------------------
set_arch -family Logos2 -device PG2L200H -speedgrade -6 -package FBB676

#-----------------------------------------------------------------------------
# 2) CPU 核（叶子模块优先）
#-----------------------------------------------------------------------------
add_design "D:/riscv/RISCV/myriscv/alu.v"
add_design "D:/riscv/RISCV/myriscv/br_alu.v"
add_design "D:/riscv/RISCV/myriscv/l_alu.v"
add_design "D:/riscv/RISCV/myriscv/regfile.v"
add_design "D:/riscv/RISCV/myriscv/csr_defs.vh"
add_design "D:/riscv/RISCV/myriscv/csr_file.v"
add_design "D:/riscv/RISCV/myriscv/mycpu_sync.v"

#-----------------------------------------------------------------------------
# 3) 总线与存储器适配
#-----------------------------------------------------------------------------
add_design "D:/riscv/RISCV/myriscv/inst_bus_interconnect.v"
add_design "D:/riscv/RISCV/myriscv/inst_bram_adapter.v"
add_design "D:/riscv/RISCV/myriscv/data_bus_interconnect.v"
add_design "D:/riscv/RISCV/myriscv/data_bram_adapter.v"

#-----------------------------------------------------------------------------
# 4) 外设：MMIO / UART（含 FIFO）/ GPIO
#-----------------------------------------------------------------------------
add_design "D:/riscv/RISCV/myriscv/simple_mmio.v"
add_design "D:/riscv/RISCV/myriscv/uart_tx.v"
add_design "D:/riscv/RISCV/myriscv/uart_rx.v"
add_design "D:/riscv/RISCV/myriscv/uart_rx_fifo.v"
add_design "D:/riscv/RISCV/myriscv/uart_mmio.v"
add_design "D:/riscv/RISCV/myriscv/gpio_mmio.v"

#-----------------------------------------------------------------------------
# 5) DDR 桥（本工程 ENABLE_DDR=0，落在 generate 的 false 分支不例化；
#    放进文件表只为避免解析阶段报"模块未定义"）
#-----------------------------------------------------------------------------
add_design "D:/riscv/RISCV/myriscv/dual_sram_to_pango_ddr_bridge.v"

#-----------------------------------------------------------------------------
# 6) 视觉子系统（接口契约 v1.0，D2 接入）—— 同样自底向上
#    依赖树（实测 grep 确认）：
#      vision_top ─┬─ ov5640_cam_ctrl ── ov5640_sccb ── `include "ov5640_init_table.vh"
#                  ├─ ov5640_capture
#                  ├─ roi_stats
#                  ├─ vision_classifier ── div_u32_seq
#                  └─ vision_regs
#
#    ★ 刻意不加的文件及原因：
#      - vision/uart_tx.v  : 与 myriscv/uart_tx.v **模块同名**，加了必然重复定义；
#                            且契约 §0 明确结果行由 CPU 软件 uart_putc 发出。
#      - vision_demo_top.v : demo 专用顶层（搭档是总线 BFM demo_bus_master）。
#      - vision_report.v   : demo 专用结果行发送。
#      - cnn_*.v / vision_cnn_top.v / cnn_weights.vh :
#                            CNN 尚未接入 vision_top（交付版例化的是
#                            vision_classifier 规则分类器 = "识别物品"功能所在）。
#                            后续接 CNN 时再追加，并按契约 §9 补 USE_CNN 参数
#                            与 AI_CYCLES / AI_CONF / AI_STATUS 寄存器。
#-----------------------------------------------------------------------------
add_design "D:/riscv/RISCV/myriscv/vision/div_u32_seq.v"
add_design "D:/riscv/RISCV/myriscv/vision/ov5640_init_table.vh"
add_design "D:/riscv/RISCV/myriscv/vision/ov5640_sccb.v"
add_design "D:/riscv/RISCV/myriscv/vision/ov5640_cam_ctrl.v"
add_design "D:/riscv/RISCV/myriscv/vision/ov5640_capture.v"
add_design "D:/riscv/RISCV/myriscv/vision/roi_stats.v"
add_design "D:/riscv/RISCV/myriscv/vision/vision_classifier.v"
add_design "D:/riscv/RISCV/myriscv/vision/vision_regs.v"
add_design "D:/riscv/RISCV/myriscv/vision/vision_top.v"

#-----------------------------------------------------------------------------
# 7) SoC 顶层与板级顶层（必须排在所有子模块之后）
#-----------------------------------------------------------------------------
add_design "D:/riscv/RISCV/myriscv/soc_top.v"
add_design "D:/riscv/RISCV/myriscv/board_top_676.v"

#-----------------------------------------------------------------------------
# 8) 片内 IP（ROM 里目前装的是片内 CoreMark 镜像；RAM 同理）
#-----------------------------------------------------------------------------
add_design "D:/riscv/RISCV/ipcore/inst_rom/inst_rom.idf"
add_design "D:/riscv/RISCV/ipcore/data_ram/data_ram.idf"

#-----------------------------------------------------------------------------
# 9) 约束（IO_LOC + 27MHz 主时钟 + OV5640 CAM1）
#-----------------------------------------------------------------------------
add_constraint "D:/riscv/RISCV/constraint_check/board_top_676.fdc"

#-----------------------------------------------------------------------------
# 10) 全流程（顶层 board_top_676）
#     include_path 里放视觉目录，供 `include "ov5640_init_table.vh" 解析
#-----------------------------------------------------------------------------
compile -top_module board_top_676 -include_path {D:/riscv/RISCV/myriscv/vision D:/riscv/RISCV/myriscv D:/riscv/RISCV}
synthesize -ads -selected_syn_tool_opt 2
dev_map
pnr -gplace_seed 2 -gplace_times 4 -mode {performance}
report_timing
report_power
gen_netlist
gen_bit_stream
