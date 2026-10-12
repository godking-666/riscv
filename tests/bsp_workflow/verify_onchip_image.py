#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""验证重新生成的 IP 初始化数据确实等于我给的 .dat 镜像。

inst_*_init_param.v 里每个 288 位常量把 9 个 32 位字按 MSB 优先串联：
    localparam INIT_00_0_0 = 288'h<72 hex digits>
                              |word0  |word1  | ... |word8  |
所以每个常量的前 8 个十六进制字符就是该组第一个 32 位字。
"""
import pathlib
import re

ROOT = pathlib.Path(r"D:\riscv\RISCV")

CASES = [
    ("ipcore/inst_rom/rtl/inst_rom_init_param.v",
     "MyCpu_test/coremark_onchip/inst_rom.dat", "inst_rom"),
    ("ipcore/data_ram/rtl/data_ram_init_param.v",
     "MyCpu_test/coremark_onchip/data_ram.dat", "data_ram"),
]

ok_all = True

for vfile, datfile, label in CASES:
    v = (ROOT / vfile).read_text(encoding="utf-8", errors="replace")
    words_hex = (ROOT / datfile).read_text(encoding="utf-8").split()

    # 抓所有 localparam INIT_xx 的 288 位值
    pats = re.findall(r"localparam\s+INIT_(\w+)\s*=\s*288'h([0-9a-fA-F]+)", v)
    print("=" * 70)
    print("%s : %d 个 288 位常量 (每个含 9 个字)" % (label, len(pats)))

    # 展开成 32 位字序列（按出现顺序）
    rom = []
    for _, hexval in pats:
        if len(hexval) % 8:
            hexval = hexval.zfill((len(hexval) + 7) // 8 * 8)
        for k in range(0, len(hexval), 8):
            rom.append(hexval[k:k + 8].lower())

    n = min(len(rom), len(words_hex))
    same = sum(1 for i in range(n) if rom[i] == words_hex[i].lower())
    print("  展开后字数 : %d" % len(rom))
    print("  .dat 字数  : %d" % len(words_hex))
    print("  前 %d 字逐一比对: %d 个相同" % (n, same))

    if same == n and len(rom) >= len(words_hex):
        print("  => OK：IP 里的初始化数据与 .dat 镜像一致")
    else:
        ok_all = False
        print("  => 不一致！前若干字对照：")
        for i in range(min(8, n)):
            print("       [%d] ip=%s dat=%s %s" %
                  (i, rom[i], words_hex[i].lower(),
                   "OK" if rom[i] == words_hex[i].lower() else "DIFF"))

    # 首字非零检查（复位入口）
    print("  首个 32 位字: ip=%s  dat=%s  %s" %
          (rom[0] if rom else "?",
           words_hex[0].lower() if words_hex else "?",
           "OK（非零，入口有效）" if rom and rom[0] != "00000000" else "!! 为零，入口可疑"))
    print()

print("=" * 70)
print("RESULT:", "PASS" if ok_all else "FAIL")
