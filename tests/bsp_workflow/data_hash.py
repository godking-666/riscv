#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""只对 init_param.v 里的 localparam 数据行取哈希，排除时间戳/注释干扰。"""
import hashlib
import pathlib
import re
import sys

ROOT = pathlib.Path(r"D:\riscv\RISCV")
FILES = [
    "ipcore/inst_rom/rtl/inst_rom_init_param.v",
    "ipcore/data_ram/rtl/data_ram_init_param.v",
]


def data_hash(p):
    if not p.exists():
        return "MISSING", 0
    lines = [l.strip() for l in p.read_text(encoding="utf-8", errors="replace").splitlines()
             if "localparam" in l]
    blob = "\n".join(lines).encode("utf-8")
    return hashlib.sha256(blob).hexdigest()[:16], len(lines)


mode = sys.argv[1] if len(sys.argv) > 1 else "show"

if mode == "head":
    p = ROOT / FILES[0]
    print("=== %s 前 8 行 ===" % FILES[0])
    for l in p.read_text(encoding="utf-8", errors="replace").splitlines()[:8]:
        print("   ", l[:150])
else:
    tag = sys.argv[2] if len(sys.argv) > 2 else None
    out = []
    for f in FILES:
        h, n = data_hash(ROOT / f)
        out.append("%s  %-6d %s" % (h, n, f))
        print("   %s  (%d 个 localparam)  %s" % (h, n, f))
    if tag:
        (ROOT / ("_onchip_datahash_%s.txt" % tag)).write_text("\n".join(out), encoding="utf-8")
        print("   已记录", tag)
