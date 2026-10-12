#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""比对 IP 相关文件在改动前后的哈希，判断 PDS compile 是否重新生成了 IP。"""
import hashlib
import pathlib
import sys

ROOT = pathlib.Path(r"D:\riscv\RISCV")
WATCH = [
    "ipcore/inst_rom/rtl/inst_rom_init_param.v",
    "ipcore/data_ram/rtl/data_ram_init_param.v",
    "ipcore/inst_rom/inst_rom.v",
    "ipcore/data_ram/data_ram.v",
    "ipcore/inst_rom/inst_rom.idf",
    "ipcore/data_ram/data_ram.idf",
]


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()[:16] if p.exists() else "MISSING"


def load(tag):
    f = ROOT / ("_onchip_hash_%s.txt" % tag)
    if not f.exists():
        return {}
    out = {}
    for line in f.read_text(encoding="utf-8").splitlines():
        if "  " in line:
            h, k = line.split("  ", 1)
            out[k] = h
    return out


mode = sys.argv[1] if len(sys.argv) > 1 else "snapshot"

if mode == "snapshot":
    tag = sys.argv[2]
    lines = ["%s  %s" % (sha(ROOT / r), r) for r in WATCH]
    (ROOT / ("_onchip_hash_%s.txt" % tag)).write_text("\n".join(lines), encoding="utf-8")
    print("已记录", tag)
    for l in lines:
        print("   ", l)
else:
    a, b = load(sys.argv[2]), load(sys.argv[3])
    print("=== %s -> %s ===" % (sys.argv[2], sys.argv[3]))
    changed = 0
    for r in WATCH:
        ha, hb = a.get(r, "?"), b.get(r, "?")
        mark = "**变了**" if ha != hb else "没变"
        if ha != hb:
            changed += 1
        print("   %s -> %s  %-8s %s" % (ha, hb, mark, r))
    print("变化文件数:", changed)
