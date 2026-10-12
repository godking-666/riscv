#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把片内 CoreMark 镜像装进 IP，并测试 PDS 的 compile 是否会自动重新生成 IP。

流程：
  1. 记录 inst_rom/data_ram 三个关键文件的哈希
  2. 把镜像复制到 MyCpu_test/coremark_onchip/
  3. 备份并改写两个 IDF 的 INIT_FILE
  4. 打印哈希供外部比较（compile 由外部执行）
"""
import hashlib
import pathlib
import re
import shutil
import sys

ROOT = pathlib.Path(r"D:\riscv\RISCV")
SRC = ROOT / "tests/bsp_workflow/build_onchip/onchip_20261011/performance_60"
DST = ROOT / "MyCpu_test/coremark_onchip"

WATCH = [
    "ipcore/inst_rom/rtl/inst_rom_init_param.v",
    "ipcore/data_ram/rtl/data_ram_init_param.v",
    "ipcore/inst_rom/inst_rom.v",
    "ipcore/data_ram/data_ram.v",
    "ipcore/inst_rom/inst_rom.idf",
    "ipcore/data_ram/data_ram.idf",
]


def sha(p: pathlib.Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()[:16] if p.exists() else "MISSING"


def snapshot():
    return {r: sha(ROOT / r) for r in WATCH}


def check_image(p: pathlib.Path) -> None:
    words = p.read_text(encoding="utf-8").split()
    if len(words) != 4096:
        raise ValueError(f"{p}: expected 4096 words, got {len(words)}")
    for i, w in enumerate(words):
        if len(w) != 8 or any(c not in "0123456789abcdefABCDEF" for c in w):
            raise ValueError(f"{p}: word {i} bad: {w!r}")


def set_init_file(idf: pathlib.Path, dat: pathlib.Path):
    text = idf.read_text(encoding="utf-8")
    pat = re.compile(r"(<name>\s*INIT_FILE\s*</name>\s*<value>)([^<]*)(</value>)")
    m = pat.search(text)
    if not m:
        raise ValueError(f"{idf}: INIT_FILE not found")
    old = m.group(2).strip()
    new = dat.as_posix()
    if old == new:
        return old, new
    bak = idf.with_name(idf.name + ".before_onchip")
    if not bak.exists():
        shutil.copy2(idf, bak)
    with open(idf, "w", encoding="utf-8", newline="\n") as f:
        f.write(text[:m.start(2)] + new + text[m.end(2):])
    return old, new


if __name__ == "__main__":
    if not SRC.exists():
        print("!! 镜像目录不存在:", SRC)
        sys.exit(1)

    DST.mkdir(parents=True, exist_ok=True)
    shutil.copy2(SRC / "inst_rom.dat", DST / "inst_rom.dat")
    shutil.copy2(SRC / "data_ram.dat", DST / "data_ram.dat")
    check_image(DST / "inst_rom.dat")
    check_image(DST / "data_ram.dat")
    print(f"镜像已复制到 {DST}")
    print(f"  inst_rom.dat  {(DST/'inst_rom.dat').stat().st_size} B")
    print(f"  data_ram.dat  {(DST/'data_ram.dat').stat().st_size} B")

    print("\n== BEFORE 哈希 ==")
    before = snapshot()
    for k, v in before.items():
        print(f"   {v}  {k}")
    (ROOT / "_onchip_hash_before.txt").write_text(
        "\n".join(f"{v}  {k}" for k, v in before.items()), encoding="utf-8")

    print("\n== 改写 IDF 的 INIT_FILE ==")
    for ip, name in (("inst_rom", "inst_rom.idf"), ("data_ram", "data_ram.idf")):
        idf = ROOT / "ipcore" / ip / name
        dat = DST / ("inst_rom.dat" if ip == "inst_rom" else "data_ram.dat")
        old, new = set_init_file(idf, dat)
        print(f"   {name}\n     旧: {old}\n     新: {new}")

    print("\n== AFTER 哈希（IDF 应变化，init_param 应该还没变）==")
    after = snapshot()
    for k, v in after.items():
        flag = "  <== 变了" if after[k] != before[k] else ""
        print(f"   {v}  {k}{flag}")
    (ROOT / "_onchip_hash_after_idf.txt").write_text(
        "\n".join(f"{v}  {k}" for k, v in after.items()), encoding="utf-8")
