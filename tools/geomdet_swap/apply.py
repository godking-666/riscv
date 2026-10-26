#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""把主工程的 CNN 从 digits10 换成队友的 geomdet（3 类物体 + 4 个框回归）。

对应位流：8/16/32 通道引擎，6123 词模型（ball/cube/cylinder）。
只换两个 RTL 文件，并给队友的 cnn_mmio 补一个 osd_class 输出（我们的 HDMI OSD 要用）。
"""
import pathlib
import shutil
import sys

ROOT = pathlib.Path(r'D:\riscv\RISCV')
SRC = pathlib.Path(r'D:\riscv\_geomdet_peek\geomdet_handoff_20261021\08_RTL参考_myriscv_cnn\_旧版备份_8_16_32')

TARGETS = {
    'cnn_digits_engine.v': SRC / 'cnn_digits_engine.v',
    'cnn_mmio.v':          SRC / 'cnn_mmio.v',
}


def read_text(p):
    return p.read_text(encoding='utf-8', errors='replace')


def write_text(p, t):
    with open(p, 'w', encoding='utf-8', newline='\n') as f:
        f.write(t)


def main():
    # ---- 0) 预检 ----
    for name, src in TARGETS.items():
        if not src.exists():
            sys.exit('  ✗ 源文件不存在: %s' % src)
    print('  源目录: %s' % SRC.name)

    # ---- 1) 备份 ----
    print('\n[1] 备份现有文件')
    for name in TARGETS:
        dst = ROOT / 'myriscv' / name
        bak = dst.with_name(dst.name + '.before_geomdet')
        if dst.exists() and not bak.exists():
            shutil.copy2(dst, bak)
            print('  ✓ %s -> %s' % (dst.name, bak.name))
        elif bak.exists():
            print('  备份已存在: %s' % bak.name)

    # ---- 2) 复制队友的 RTL ----
    print('\n[2] 复制队友的 geomdet RTL')
    for name, src in TARGETS.items():
        dst = ROOT / 'myriscv' / name
        shutil.copy2(src, dst)
        print('  ✓ %s  (%d B)' % (name, dst.stat().st_size))

    # ---- 3) 给 cnn_mmio 补 osd_class ----
    print('\n[3] 给 cnn_mmio 补 osd_class 输出')
    p = ROOT / 'myriscv' / 'cnn_mmio.v'
    t = read_text(p)

    if 'osd_class' in t:
        print('  已含 osd_class，跳过')
    else:
        # (a) 端口：pp_hold 后面加一个输出
        old_port = '    output wire pp_hold,'
        new_port = ('    output wire pp_hold,\n'
                    '    // 当前识别类别（= 引擎的 prediction）。给 HDMI OSD 叠加用。\n'
                    '    // 本行是整合 geomdet 时补的，不动 data_bus_interconnect。\n'
                    '    output wire [3:0] osd_class,')
        if old_port not in t:
            sys.exit('  ✗ 找不到端口锚点 "%s"' % old_port)
        t = t.replace(old_port, new_port, 1)

        # (b) 赋值：engine_class 声明后面接上
        old_wire = '    wire [3:0] engine_class;'
        new_wire = ('    wire [3:0] engine_class;\n'
                    '    assign osd_class = engine_class;')
        if old_wire not in t:
            sys.exit('  ✗ 找不到 engine_class 锚点')
        t = t.replace(old_wire, new_wire, 1)

        write_text(p, t)
        print('  ✓ 已插入 2 处（端口 + 赋值）')

    # ---- 4) 校验 ----
    print('\n[4] 校验')
    checks = [
        ('cnn_mmio.v', 'output wire [3:0] osd_class', 'osd_class 端口'),
        ('cnn_mmio.v', 'assign osd_class = engine_class', 'osd_class 赋值'),
        ('cnn_mmio.v', "13'd6123", '接受 6123 词'),
        ('cnn_mmio.v', 'geomdet_int8_v1', 'geomdet ABI 标注'),
        ('cnn_digits_engine.v', 'module cnn_digits_engine', '引擎模块'),
    ]
    ok = True
    for fname, needle, label in checks:
        txt = read_text(ROOT / 'myriscv' / fname)
        hit = needle in txt
        print('  %s %-22s %s' % ('✓' if hit else '✗', label, fname))
        ok = ok and hit

    # geomdet 引擎不应再有 digits10 的固定拓扑标记
    eng = read_text(ROOT / 'myriscv' / 'cnn_digits_engine.v')
    if 'digits10_int8_v1' in eng:
        print('  ⚠ 引擎里仍有 digits10_int8_v1 字样，请确认是否已换成 geomdet 版')
    else:
        print('  ✓ 引擎已不含 digits10 拓扑标记')

    print('\n  %s' % ('全部检查通过' if ok else '有检查失败'))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
