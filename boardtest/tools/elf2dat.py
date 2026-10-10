#!/usr/bin/env python3
"""elf2dat.py --- 把 CoreMark 的 ELF 拆成 Pango 片内 ROM / RAM 的初始化文件

本工程的两块片内存储器是分开的：
    inst_rom  : 4096 x 32 bit  (16 KiB)，只挂指令总线，INIT_FORMAT=HEX
    data_ram  : 4096 x 32 bit  (16 KiB)，只挂数据总线，INIT_FORMAT=HEX
两块 IP 的 INIT_FILE 都是一行一个 8 位十六进制字的文本文件（共 4096 行）。

所以不能简单地用 objcopy -O binary —— .text 与 .data 都在地址 0x0，
一份扁平二进制无法区分它们属于哪块存储器。本脚本直接解析 ELF 段表，
按段属性分流：

    SHF_ALLOC + SHF_EXECINSTR  -> 指令 ROM 镜像
    SHF_ALLOC 且非 EXECINSTR   -> 数据 RAM 镜像（.rodata / .data / .bss ...）

其中 .rodata 必须进 RAM，因为数据总线读不到启动 ROM。

用法：
    python tools/elf2dat.py build/coremark.elf \
        --rom-out build/inst_rom.dat --ram-out build/data_ram.dat
    python tools/elf2dat.py build/coremark_ddr.elf --flat build/coremark_ddr.bin
"""
from __future__ import annotations

import argparse
import struct
import sys

SHF_WRITE = 0x1
SHF_ALLOC = 0x2
SHF_EXECINSTR = 0x4
SHT_NOBITS = 8

ROM_WORDS = 4096
RAM_WORDS = 4096


class Section:
    __slots__ = ("name", "type", "flags", "addr", "offset", "size", "data")

    def __repr__(self) -> str:
        return f"<{self.name} addr=0x{self.addr:08x} size={self.size} flags=0x{self.flags:x}>"


def parse_elf(path: str):
    with open(path, "rb") as f:
        blob = f.read()

    if blob[:4] != b"\x7fELF":
        raise ValueError(f"{path}: not an ELF file")
    if blob[4] != 1:
        raise ValueError(f"{path}: not ELF32")
    if blob[5] != 1:
        raise ValueError(f"{path}: not little-endian")

    (e_shoff,) = struct.unpack_from("<I", blob, 32)
    (e_shentsize,) = struct.unpack_from("<H", blob, 46)
    (e_shnum,) = struct.unpack_from("<H", blob, 48)
    (e_shstrndx,) = struct.unpack_from("<H", blob, 50)
    if e_shoff == 0 or e_shnum == 0:
        raise ValueError(f"{path}: no section headers")

    def shdr(i: int):
        off = e_shoff + i * e_shentsize
        return struct.unpack_from("<IIIIIIIIII", blob, off)

    # 段名字符串表
    _, _, _, _, str_off, str_size, _, _, _, _ = shdr(e_shstrndx)
    strtab = blob[str_off:str_off + str_size]

    def name_of(idx: int) -> str:
        end = strtab.find(b"\x00", idx)
        return strtab[idx:end].decode("utf-8", "replace")

    sections = []
    for i in range(e_shnum):
        (nm, typ, flags, addr, off, size, _link, _info, _align, _ent) = shdr(i)
        if not (flags & SHF_ALLOC):
            continue
        data = b"" if typ == SHT_NOBITS else blob[off:off + size]
        sections.append(Section.__new__(Section))
        s = sections[-1]
        s.name, s.type, s.flags, s.addr, s.offset, s.size, s.data = (
            name_of(nm), typ, flags, addr, off, size, data)
    return sections


def to_words(sections, limit_words: int, base: int, label: str):
    """把段内容合并成一个 32 位字数组（base 为 0）。"""
    words = [0] * limit_words
    used_hi = 0
    rows = []
    for s in sections:
        if s.size == 0:
            continue
        if s.addr % 4:
            raise ValueError(f"{label}: section {s.name} is not 4-byte aligned (0x{s.addr:x})")
        start = (s.addr - base) // 4
        n = (s.size + 3) // 4
        if start < 0 or start + n > limit_words:
            raise ValueError(
                f"{label}: section {s.name} at 0x{s.addr:08x} size {s.size} "
                f"does not fit the {limit_words * 4} byte window")
        if s.data:
            pad = (-len(s.data)) % 4
            payload = s.data + b"\x00" * pad
            for k in range(n):
                words[start + k] = struct.unpack_from("<I", payload, k * 4)[0]
        else:
            # SHT_NOBITS (.bss)：本来就应该是零，镜像里保持 0 即可
            pass
        used_hi = max(used_hi, start + n)
        rows.append((s.name, s.addr, s.size,
                     "EXEC" if s.flags & SHF_EXECINSTR else "DATA",
                     "PROGBITS(有初值)" if s.data else "NOBITS(零填充)",
                     sum(1 for w in words[start:start + n] if w != 0)))
    return words, used_hi, rows


def write_dat(path: str, words) -> None:
    with open(path, "w", encoding="ascii", newline="\n") as f:
        f.write("".join(f"{w:08x}\n" for w in words))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("elf")
    ap.add_argument("--rom-out", default=None, help="片内 ROM 初始化文件 (4096 字)")
    ap.add_argument("--ram-out", default=None, help="片内 RAM 初始化文件 (4096 字)")
    ap.add_argument("--flat", default=None, help="输出扁平二进制（DDR 模型预载用）")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    sections = parse_elf(args.elf)
    rom_secs = [s for s in sections if s.flags & SHF_EXECINSTR]
    ram_secs = [s for s in sections if not (s.flags & SHF_EXECINSTR)]

    print(f"ELF       : {args.elf}")
    print(f"alloc secs: {len(sections)}  (exec {len(rom_secs)} / data {len(ram_secs)})")

    rc = 0

    if args.rom_out:
        words, used, rows = to_words(rom_secs, ROM_WORDS, 0, "ROM")
        write_dat(args.rom_out, words)
        print(f"\n--- 指令 ROM 镜像 -> {args.rom_out}")
        for nm, addr, size, kind, stype, nz in rows:
            print(f"    {nm:<24} 0x{addr:08x}  {size:>6} B  {kind:<4} {stype:<16} 非零字 {nz}")
        print(f"    used {used} / {ROM_WORDS} words  ({used * 4} / {ROM_WORDS * 4} bytes)")
        if used >= ROM_WORDS:
            print("    !! ROM 已满或溢出，请用 -Os、精简 printf，或扩容 ROM IP")
            rc = 1
        if words[0] == 0:
            print("    !! 警告：ROM 第一个字是 0，复位入口可能不对（应看到 start.S 的指令）")
            rc = 1

    if args.ram_out:
        words, used, rows = to_words(ram_secs, RAM_WORDS, 0, "RAM")
        write_dat(args.ram_out, words)
        print(f"\n--- 数据 RAM 镜像 -> {args.ram_out}")
        for nm, addr, size, kind, stype, nz in rows:
            print(f"    {nm:<24} 0x{addr:08x}  {size:>6} B  {kind:<4} {stype:<16} 非零字 {nz}")
        print(f"    used {used} / {RAM_WORDS} words  ({used * 4} / {RAM_WORDS * 4} bytes)")
        if used >= RAM_WORDS:
            print("    !! RAM 已满或溢出")
            rc = 1
        # .rodata/.data 必须真的有内容，否则 CoreMark 的 CRC 一定失败
        for nm, addr, size, kind, stype, nz in rows:
            if stype.startswith("PROGBITS") and nz == 0 and size > 0:
                print(f"    !! 警告：{nm} 标称有初值但全是 0，检查链接脚本是否把它放到了 ROM")
                rc = 1

    if args.flat:
        lo = min(s.addr for s in sections if s.size)
        hi = max(s.addr + s.size for s in sections if s.size)
        size = hi - lo
        buf = bytearray(size)
        for s in sections:
            if s.data:
                o = s.addr - lo
                buf[o:o + len(s.data)] = s.data
        with open(args.flat, "wb") as f:
            f.write(buf)
        print(f"\n--- 扁平镜像 -> {args.flat}  base=0x{lo:08x} size={size} B")

    print("\nRESULT:", "OK" if rc == 0 else "SIZE PROBLEM")
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
