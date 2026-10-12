#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""build_onchip.py --- CoreMark 片内 ROM/RAM 运行变体的构建入口

与 build.py 的关系
------------------
build.py 构建的是**经 UART Loader 载入 DDR 执行**的版本（已实板验收，不要动它）。
本脚本构建的是**常驻片内 ROM/RAM**的版本，用途是把 CoreMark 从慢速 DDR 桥里搬出来，
拿到接近 1 周期取指的分数。

设计约束（来自 AGENTS.md）
--------------------------
* 片内 ROM 只接指令总线，片内 RAM 只接数据总线，各 16 KiB，同基址 0x0
* 数据总线**读不到** ROM => .rodata/.data/.bss/栈全部必须落在 RAM
* 两块存储器的 IP 初始化文件是"一行一个 8 位十六进制 32 位字"，各 4096 行

用法
----
    python tests/bsp_workflow/build_onchip.py --iterations 60 --tag onchip_20261011

产物（全部在新目录里，不覆盖任何已有构建）
    build_onchip/<tag>/performance_<N>/
        program.elf / program.map / size.txt / program.dis / symbols.txt
        inst_rom.dat    <- 4096 字，装进 ipcore/inst_rom 的 INIT_FILE
        data_ram.dat    <- 4096 字，装进 ipcore/data_ram 的 INIT_FILE
        fit_report.txt  <- 体积与放置检查结果
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
TOOL = ROOT / "xpack-riscv-none-elf-gcc-15.2.0-1" / "bin"
ELF2DAT = HERE / "elf2dat.py"


def run(tool: str, args, log_path: Path, cwd: Path) -> str:
    exe = TOOL / f"riscv-none-elf-{tool}.exe"
    r = subprocess.run([str(exe), *map(str, args)], cwd=cwd,
                       capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    log_path.write_text(r.stdout + r.stderr, encoding="utf-8")
    if r.returncode != 0:
        print(f"!! {tool} 失败，见 {log_path}")
        print(r.stdout + r.stderr)
        raise SystemExit(1)
    return r.stdout + r.stderr


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--iterations", type=int, default=60)
    ap.add_argument("--hz", type=int, default=27000000,
                    help="core_clk 实际频率(Hz)。新板 PG2L200H 直驱=27000000；"
                         "切 PLL 到 54MHz 时传 54000000。同时定义 BSP_CLOCK_HZ 与 CLOCKS_PER_SEC。")
    ap.add_argument("--tag", required=True)
    ap.add_argument("--mode", default="performance", choices=["performance", "validation"])
    args = ap.parse_args()

    name = f"{args.mode}_{args.iterations}"
    out = HERE / "build_onchip" / args.tag / name
    if out.exists():
        print(f"!! {out} 已存在，换一个 --tag（保留旧构建）")
        return 1
    out.mkdir(parents=True)

    ck = ROOT / "coremark-main"
    sources = [
        HERE / "startup.S", HERE / "trap.S", HERE / "trap.c",
        HERE / "uart.c", HERE / "timer.c", HERE / "crc32.c",
        HERE / "core_portme.c", HERE / "ee_printf.c",
        ck / "core_main.c", ck / "core_list_join.c", ck / "core_matrix.c",
        ck / "core_state.c", ck / "core_util.c",
    ]
    missing = [p for p in sources if not p.exists()]
    if missing:
        print("!! 缺少源文件:", *[str(p) for p in missing], sep="\n   ")
        return 1

    # flags 与 build.py 保持一致，只改链接脚本并加 --no-check-sections
    # （ROM 与 RAM 在同一基址 0x0，两段 LMA 重叠是合法的哈佛结构用法）
    flags = [
        "-march=rv32i", "-mabi=ilp32", "-Os", "-g", "-Wall", "-Wextra",
        "-ffreestanding", "-fno-builtin", "-fno-pic", "-fno-pie",
        "-msmall-data-limit=0", "-ffunction-sections", "-fdata-sections",
        "-fstack-usage", "-nostdlib", "-nostartfiles",
        "-Wl,--no-relax", "-Wl,--build-id=none", "-Wl,--gc-sections",
        "-Wl,--no-check-sections",
        "-I", str(HERE),
        "-DBSP_CLOCK_HZ=%du" % args.hz, "-DTOTAL_DATA_SIZE=2000", f"-DCLOCKS_PER_SEC={args.hz}",
        f"-DITERATIONS={args.iterations}", f"-D{args.mode.upper()}_RUN=1",
        '-DFLAGS_STR="onchip -Os -march=rv32i -mabi=ilp32"',
        "-I", str(ck),
    ]

    elf = out / "program.elf"
    print(f"=== 构建片内版 {name} -> {out}")
    run("gcc", flags + [str(s) for s in sources]
        + ["-T", str(HERE / "linker_onchip.ld"),
           f"-Wl,-Map={out / 'program.map'}", "-o", str(elf), "-lgcc"],
        out / "compile.log", out)

    run("size", [elf], out / "size.txt", out)
    run("objdump", ["-d", elf], out / "program.dis", out)
    run("nm", ["-n", elf], out / "symbols.txt", out)
    run("readelf", ["-h", "-l", "-S", elf], out / "program.readelf.txt", out)

    # ---- 拆分 ROM / RAM 镜像 ----
    r = subprocess.run([sys.executable, str(ELF2DAT), str(elf),
                        "--rom-out", str(out / "inst_rom.dat"),
                        "--ram-out", str(out / "data_ram.dat")],
                       capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    (out / "fit_report.txt").write_text(r.stdout + r.stderr, encoding="utf-8")
    print(r.stdout)
    if r.stderr.strip():
        print(r.stderr)

    if r.returncode != 0:
        print("!! 体积或放置检查未通过 —— 见 fit_report.txt")
        return r.returncode

    print(f"RESULT: PASS {name}  {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
