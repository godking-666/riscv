#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""团队交付包（完整 CoreMark 版 riscv-master） vs 当前工程 的文件级对比。

输出：
  * 只在当前工程里的文件（我们新增）
  * 只在团队包里有的文件（我们删/归档）
  * 两边都有但内容不同的文件（我们改了）
  * 未变的文件数（说明合并时团队成果被完整保留）
"""
import hashlib
import pathlib
import re

TEAM = pathlib.Path(r"D:\riscv\riscv-master\riscv-master")
NOW = pathlib.Path(r"D:\riscv\RISCV")

# 只比对"源"类文件
EXTS = {".v", ".vh", ".sv", ".c", ".h", ".s", ".ld", ".py", ".tcl", ".pds",
        ".fdc", ".sdc", ".md", ".txt", ".idf", ".csv", ".yml", ".yaml",
        ".sh", ".bat", ".ps1", ".dat", ".json", ".prj", ".cfg"}
# 编译/日志产物目录（不比对）
SKIP_DIRS = {
    "compile", "synthesize", "device_map", "place_route", "generate_bitstream",
    "report_timing", "report_power", "generate_netlist", "logbackup",
    "temp_projects", "build", "build_onchip", "__pycache__", ".git",
    "rev_1", "sim_out", "dump", "waves",
    # 工具链是 junction 指进工程的，不算源文件
    "xpack-riscv-none-elf-gcc-15.2.0-1", "riscv-none-elf",
    # 归档与第三方
    "_archive", "coremark-main", "riscv-master", "difftest",
}
# 这些顶层目录整棵不比对（临时脚本、第三方副本、厂商资料）
SKIP_TOP = {"_archive", "xpack-riscv-none-elf-gcc-15.2.0-1", "riscv-master"}
SKIP_NAME = re.compile(r"(\.log$|\.adb$|\.prr$|\.prt$|\.rtr$|\.db$|\.lock$|"
                       r"\.netlist$|\.bgr$|\.smsk$|\.sbit$|\.sfc$|\.map$)", re.I)


def walk(root):
    out = {}
    for p in root.rglob("*"):
        if not p.is_file():
            continue
        rel = p.relative_to(root)
        parts = set(rel.parts[:-1])
        if parts & SKIP_DIRS:
            continue
        if p.suffix.lower() not in EXTS:
            continue
        if SKIP_NAME.search(p.name):
            continue
        out[str(rel).replace("\\", "/")] = p
    return out


def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


team = walk(TEAM)
now = walk(NOW)
print(f"团队包 {TEAM}  源文件 {len(team)}")
print(f"当前   {NOW}  源文件 {len(now)}")
print()

only_now = sorted(set(now) - set(team))
only_team = sorted(set(team) - set(now))
common = sorted(set(now) & set(team))

modified = []
same = 0
for rel in common:
    if sha(now[rel]) != sha(team[rel]):
        modified.append(rel)
    else:
        same += 1

print(f"=== 新增（只在当前工程）: {len(only_now)} ===")
for r in only_now:
    print("  +", r)
print()
print(f"=== 删除/归档（只在团队包）: {len(only_team)} ===")
for r in only_team:
    print("  -", r)
print()
print(f"=== 修改（两边都有、内容不同）: {len(modified)} ===")
for r in modified:
    print("  ~", r)
print()
print(f"=== 未变: {same} ===")
