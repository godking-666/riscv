#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给 myriscv/board_top.v 的 debug 信号加 PAP_MARK_DEBUG 标记（方案 B 第 1 步）。

为什么必须加：
  这 5 根线在 board_top 顶层没有任何负载，ADS 综合会把它们整条链优化掉
  （综合网表里 _floating）。于是打开 Fabric Inserter 时找不到可插的资源，
  保存出来的 .fic 是空的，dev_map 报 E: Flow-0037: Fic file is empty.

语法依据：Fabric Inserter 用户手册 4.1「在 RTL 中标记信号」
  * 必须配合 ADS 综合工具（本工程就是 synthesize -ads）
  * 值必须用英文双引号包裹
  * 用数字标记可同时指定 Inserter 里的排序

本脚本幂等：已经加过就直接退出。
"""
import pathlib
import re
import shutil
import sys

F = pathlib.Path(r"D:\riscv\RISCV\myriscv\board_top.v")
BAK = F.with_name("board_top.v.before_pap_debug")

text = F.read_text(encoding="utf-8")

if "PAP_MARK_DEBUG" in text:
    print("已经加过 PAP_MARK_DEBUG，跳过")
    sys.exit(0)

OLD = """    wire [31:0] debug_wb_pc;
    wire [31:0] debug_inst;
    wire [ 3:0] debug_wb_rf_we;
    wire [ 4:0] debug_wb_rf_wnum;
    wire [31:0] debug_wb_rf_wdata;
"""

NEW = """    // ================================================================
    // DebugCore / Fabric Inserter 观测点
    // ----------------------------------------------------------------
    // 这 5 根线在 board_top 顶层没有负载，ADS 综合会把它们整条链优化掉，
    // 导致 Fabric Inserter 找不到可插资源、生成的 .fic 为空、
    // dev_map 报 E: Flow-0037: Fic file is empty.
    // 加 PAP_MARK_DEBUG 后 ADS 会保留这些 net 并保持 RTL 原名。
    // 语法依据：Fabric Inserter 用户手册 4.1「在 RTL 中标记信号」。
    // ================================================================
    wire [31:0] debug_wb_pc        /* synthesis PAP_MARK_DEBUG="1" */;
    wire [31:0] debug_inst         /* synthesis PAP_MARK_DEBUG="2" */;
    wire [ 3:0] debug_wb_rf_we     /* synthesis PAP_MARK_DEBUG="3" */;
    wire [ 4:0] debug_wb_rf_wnum   /* synthesis PAP_MARK_DEBUG="4" */;
    wire [31:0] debug_wb_rf_wdata  /* synthesis PAP_MARK_DEBUG="5" */;

    // 若 Fabric Inserter 的 Clock 下拉框里找不到 core_clk，把下面两行注释打开，
    // 用"精确标记"直接指定 DebugCore0 的 clock / reset 通道
    // （t=trigger d=data c=clock r=reset）：
    //   wire core_clk    /* synthesis PAP_MARK_DEBUG="<0/c0/0>" */;
    //   wire soc_resetn  /* synthesis PAP_MARK_DEBUG="<0/r0/0>" */;
"""

if OLD not in text:
    print("!! 未找到预期的 wire 声明块，未改动。实际内容：")
    m = re.search(r"wire \[31:0\] debug_wb_pc.*?;", text, re.S)
    print(repr(text[max(0, text.find('debug_wb_pc') - 120):text.find('debug_wb_pc') + 320]))
    sys.exit(1)

shutil.copy2(F, BAK)
with open(F, "w", encoding="utf-8", newline="\n") as f:
    f.write(text.replace(OLD, NEW, 1))

print("OK: 已加 PAP_MARK_DEBUG 标记")
print("   备份 ->", BAK)
print("   生效标记行数:", sum(1 for l in F.read_text(encoding='utf-8').splitlines()
                              if "PAP_MARK_DEBUG" in l and not l.strip().startswith("//")))
