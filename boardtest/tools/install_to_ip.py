#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""install_to_ip.py --- 把 boardtest 镜像装进工程的片内 ROM/RAM IP 配置

做三件事：
  1. 把镜像复制到 MyCpu_test/<name>/（与工程既有的 board_selftest/、coremark/ 同级）
  2. 备份并改写 ipcore/inst_rom/inst_rom.idf 与 ipcore/data_ram/data_ram.idf 的 INIT_FILE
  3. 打印在 PDS 里需要手动执行的步骤

注意：改 IDF 不会让已生成的 IP 网表变化，必须在 PDS 里重新 Generate 这两个 IP。

用法：
    python tools/install_to_ip.py --name boardtest --rom build/inst_rom.dat --ram build/data_ram.dat
    python tools/install_to_ip.py --restore
"""
from __future__ import annotations

import argparse
import re
import shutil
from pathlib import Path

WORDS = 4096
BACKUP_SUFFIX = ".before_install"


def check_image(path: Path) -> None:
    words = path.read_text(encoding="utf-8").split()
    if len(words) != WORDS:
        raise ValueError(f"{path}: expected {WORDS} hex words, found {len(words)}")
    for i, w in enumerate(words):
        if len(w) != 8 or any(c not in "0123456789abcdefABCDEF" for c in w):
            raise ValueError(f"{path}: word {i} is not 8 hex digits: {w!r}")


def set_init_file(idf: Path, dat: Path) -> str:
    text = idf.read_text(encoding="utf-8")
    new = dat.as_posix()
    pat = re.compile(r"(<name>\s*INIT_FILE\s*</name>\s*<value>)([^<]*)(</value>)")
    m = pat.search(text)
    if not m:
        raise ValueError(f"{idf}: INIT_FILE parameter not found")
    old = m.group(2)
    if old == new:
        return old
    bak = idf.with_name(idf.name + BACKUP_SUFFIX)
    if not bak.exists():
        shutil.copy2(idf, bak)
    idf.write_text(text[:m.start(2)] + new + text[m.end(2):], encoding="utf-8", newline="\n")
    return old


def restore(idf: Path) -> bool:
    bak = idf.with_name(idf.name + BACKUP_SUFFIX)
    if not bak.exists():
        print(f"   no backup for {idf.name}")
        return False
    shutil.copy2(bak, idf)
    print(f"   restored {idf.name} from {bak.name}")
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--name", default="boardtest", help="MyCpu_test/<name>/ 目标子目录")
    ap.add_argument("--rom")
    ap.add_argument("--ram")
    ap.add_argument("--restore", action="store_true")
    args = ap.parse_args()

    here = Path(__file__).resolve().parent      # .../boardtest/tools
    proj = here.parent.parent                   # project root

    inst_rom_idf = proj / "ipcore" / "inst_rom" / "inst_rom.idf"
    data_ram_idf = proj / "ipcore" / "data_ram" / "data_ram.idf"
    for p in (inst_rom_idf, data_ram_idf):
        if not p.exists():
            print(f"ERROR: not found: {p}")
            return 2

    print(f"project root : {proj}")

    if args.restore:
        print("\n== restore INIT_FILE ==")
        restore(inst_rom_idf)
        restore(data_ram_idf)
        print("\nremember to re-generate both IPs in PDS afterwards.")
        return 0

    if not args.rom or not args.ram:
        print("ERROR: --rom and --ram are required (or use --restore)")
        return 2

    rom, ram = Path(args.rom).resolve(), Path(args.ram).resolve()
    check_image(rom)
    check_image(ram)
    print(f"rom image    : {rom}  ({WORDS} words)")
    print(f"ram image    : {ram}  ({WORDS} words)")

    dest = proj / "MyCpu_test" / args.name
    dest.mkdir(parents=True, exist_ok=True)
    shutil.copy2(rom, dest / "inst_rom.dat")
    shutil.copy2(ram, dest / "data_ram.dat")
    print(f"\n== copied to {dest}")
    print("   inst_rom.dat")
    print("   data_ram.dat")

    print("\n== update INIT_FILE ==")
    old_rom = set_init_file(inst_rom_idf, dest / "inst_rom.dat")
    print(f"   inst_rom.idf : {old_rom}")
    print(f"               -> {(dest / 'inst_rom.dat').as_posix()}")
    old_ram = set_init_file(data_ram_idf, dest / "data_ram.dat")
    print(f"   data_ram.idf : {old_ram}")
    print(f"               -> {(dest / 'data_ram.dat').as_posix()}")

    print("""
== next steps in Pango PDS (manual) ==
  1. open RISCV.pds
  2. re-generate the inst_rom IP
  3. re-generate the data_ram IP
  4. Compile -> Synthesize -> Device Map -> Place & Route -> Report Timing
  5. Generate Bitstream, download board_top.sbit, press KEY0
  6. serial 115200 8N1 (40pin pin36=TX/AA20, pin35=RX/AA21, GND)
  7. expected: K17 slow blink (RUN) -> steady ON (PASS); serial prints the report

  to go back to another image (e.g. the DDR selftest or CoreMark):
     python tools/install_to_ip.py --restore      then re-generate both IPs
""")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
