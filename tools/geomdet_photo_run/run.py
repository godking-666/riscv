#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""跑队友的 geomdet 单次检测固件（3 类物体 + 边界框）。

协议（见 tests/geomdet_photo/main.c）：
    G  -> go
    C  -> capture（抓一帧，跑 PP + CNN）
    d  -> 导出 RGB96（27 KB），本脚本读掉丢弃（不需要图也能看检测结果）
    Q  -> 结束

输出：
    CNN_JOB ... CLASS=<0/1/2>
    SCORES <7 个值>          (3 类 logits + cx,cy,w,h)
    DET CLASS=<0/1/2> CX=.. CY=.. W=.. H=..
"""
import argparse
import json
import re
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/camera_uart'))

import serial                      # noqa: E402
from capture import loader_plan    # noqa: E402
from protocol import Wire          # noqa: E402

BUILD = ROOT / 'tests/geomdet_photo/build/geomdet_20261020_b'
CLASSES = ['ball', 'cube', 'cylinder']


def pump(wire, seconds, stop_when=None):
    """收串口 N 秒，返回累计文本；stop_when(text) 返回 True 时提前结束。"""
    text = b''
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        chunk = wire.read(4096)
        if chunk:
            text += chunk
            if stop_when and stop_when(text.decode('latin-1', errors='replace')):
                break
        else:
            time.sleep(0.03)
    return text.decode('latin-1', errors='replace')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', default='COM7')
    ap.add_argument('--log-dir', default=None)
    ap.add_argument('--build', default=str(BUILD),
                    help='固件构建目录（含 manifest.json / program.bin）')
    ap.add_argument('--no-export', action='store_true',
                    help='不导出图像（仍然要发 d，只是更快丢弃）')
    args = ap.parse_args()
    build = Path(args.build)
    if not (build / 'manifest.json').exists():
        raise SystemExit('  ✗ %s 下没有 manifest.json' % build)

    folder = Path(args.log_dir) if args.log_dir else (
        ROOT / 'sim' / 'geomdet' / time.strftime('%Y%m%d_%H%M%S'))
    if folder.exists():
        raise SystemExit('  ✗ 日志目录已存在：%s' % folder)
    folder.mkdir(parents=True)

    manifest = json.loads((build / 'manifest.json').read_text(encoding='utf-8'))
    info = dict(manifest)
    info['bin_path'] = str(Path(info['bin_path']))

    print('=' * 74)
    print('  geomdet 物体检测（ball / cube / cylinder + 边界框）')
    print('  固件    : %s' % manifest['bin_path'])
    print('  SHA256  : %s' % info.get('bin_sha256'))
    print('  bytes   : %s   model_id: %s' % (info.get('bytes'), info.get('trained_model', {}).get('model_id_hex')))
    print('  串口    : %s' % args.port)
    print('=' * 74)

    try:
        port = serial.Serial(args.port, 115200, timeout=0.05, write_timeout=5)
    except Exception as e:
        raise SystemExit('\n  ✗ 打不开 %s：%s' % (args.port, e))
    wire = Wire(port, folder)

    try:
        # ---------- 1) 踢掉旧固件 ----------
        print('\n[1/6] 停掉可能还在跑的旧固件...')
        for _ in range(3):
            wire.write(b'Q')
            time.sleep(0.2)
        time.sleep(0.4)
        wire.port.reset_input_buffer()

        # ---------- 2) 加载 ----------
        print('[2/6] 加载固件到 DDR...')
        plans = list(loader_plan(info))
        for idx, plan in enumerate(plans):
            tx = bytes.fromhex(plan['tx_hex'])
            expect = bytes.fromhex(plan['expected_hex'])
            got = b''
            attempt = 0
            while True:
                attempt += 1
                if wire.in_waiting:
                    wire.read(wire.in_waiting)
                wire.write(tx)
                got = b''
                dl = time.monotonic() + 1.0
                while len(got) < 60 and time.monotonic() < dl:
                    got += wire.read(60 - len(got))
                if len(got) == 60 or idx != 0 or attempt >= 8:
                    break
            if len(got) != 60:
                raise SystemExit('\n!! Loader 第 %d/%d 步「%s」无应答。重烧位流后重试。'
                                 % (idx + 1, len(plans), plan['name']))
            if got != expect:
                raise SystemExit('\n!! Loader 第 %d/%d 步「%s」应答不匹配。'
                                 % (idx + 1, len(plans), plan['name']))
            if (idx + 1) % 40 == 0 or idx + 1 == len(plans):
                print('      进度 %d/%d' % (idx + 1, len(plans)))
        print('      ✓ 全部 %d 步应答正确' % len(plans))

        # ---------- 3) 等 banner ----------
        print('[3/6] 等固件就绪...')
        text = pump(wire, 8.0, lambda s: 'CNN_READY' in s or 'CNN_FAIL' in s)
        for line in text.splitlines():
            if line.strip():
                print('    | ' + line.strip()[:130])
        if 'CNN_FAIL' in text:
            raise SystemExit('\n!! 固件在启动阶段失败')

        # ---------- 4) G -> C ----------
        print('\n[4/6] 发 G 再发 C（抓一帧跑 CNN）...')
        wire.write(b'G'); time.sleep(0.15)
        wire.write(b'C')

        print('[5/6] 等检测结果...')
        res = pump(wire, 30.0,
                   lambda s: ('DET CLASS=' in s and ('CX=' in s)) or 'CNN_FAIL' in s)

        # ---------- 解析 ----------
        def one(pat, cast=str, default=None):
            m = re.search(pat, res, re.M)
            return cast(m.group(1)) if m else default

        cls = one(r'DET CLASS=(\d+)', int)
        cx = one(r'CX=(\d+)', int)
        cy = one(r'CY=(\d+)', int)
        w  = one(r'W=(\d+)',  int)
        h  = one(r'H=(\d+)',  int)
        scores_txt = one(r'^SCORES((?:\s+-?\d+)+)', str, '')
        scores = [int(v) for v in scores_txt.split()] if scores_txt else []
        cyc = one(r'CYCLES=(\d+)', int)
        ppcyc = one(r'PP_CYCLES=(\d+)', int)
        mode = one(r'^2K (\w+) run', str)
        cnn_ok = one(r'STATUS=([0-9a-f]+)', str)

        print('\n' + '-' * 74)
        for line in res.splitlines():
            if line.strip() and any(k in line for k in
                                    ('CNN_JOB', 'SCORES', 'DET ', 'SOURCE', 'CNN_FAIL', 'REASON')):
                print('  | ' + line.strip()[:130])
        print('-' * 74)

        print('\n检测结果')
        if cls is not None and 0 <= cls < len(CLASSES):
            print('  ★ 类别    : %d = %s' % (cls, CLASSES[cls].upper()))
            print('  ★ 边界框  : 中心 (%d, %d)  宽高 (%d, %d)   [96x96 灰度域]' % (cx, cy, w, h))
            print('             换算到 1280x720：中心 (%d, %d)  宽高 (%d, %d)'
                  % (cx * 1280 // 96, cy * 720 // 96, w * 1280 // 96, h * 720 // 96))
        else:
            print('  ⚠ 没解析到 DET CLASS')
        if scores:
            print('  ★ 7 个输出: %s' % ' '.join('%d' % v for v in scores))
            print('              [%s] + [cx cy w h]' % ' '.join(CLASSES[:len(scores) - 4]))
        if cyc:
            print('  CNN 周期  : %d = %.2f ms' % (cyc, cyc / 93750.0))
        if ppcyc:
            print('  PP 周期   : %d = %.2f ms' % (ppcyc, ppcyc / 93750.0))

        summary = dict(mode=mode, class_id=cls,
                       class_name=CLASSES[cls] if cls is not None and 0 <= cls < len(CLASSES) else None,
                       box_96=dict(cx=cx, cy=cy, w=w, h=h),
                       scores=scores, cnn_cycles=cyc, pp_cycles=ppcyc,
                       raw=res)
        (folder / 'detect.json').write_text(
            json.dumps(summary, ensure_ascii=False, indent=2), encoding='utf-8')

        # ---------- 6) 导出 + 收尾 ----------
        print('\n[6/6] 发 d 导出图像（读掉丢弃）再发 Q 收尾...')
        wire.write(b'd')
        if not args.no_export:
            pump(wire, 12.0, lambda s: 'CNN_RELEASED' in s or 'CNN_FAIL' in s)
        wire.write(b'Q')
        tail = pump(wire, 8.0, lambda s: 'CNN_GEOMDET_DONE' in s or 'CNN_FAIL' in s)
        for line in tail.splitlines():
            if line.strip() and ('DONE' in line or 'FAIL' in line or 'RELEASED' in line):
                print('  | ' + line.strip()[:130])

        print('\n  原始字节: %s' % (folder / 'uart.rx.bin'))
        print('  结果 JSON: %s' % (folder / 'detect.json'))
        if 'CNN_GEOMDET_DONE' in (res + tail):
            print('\n  ✅ 整条链路跑通（相机 -> PP -> CNN 检测 -> UART）')
        elif 'CNN_FAIL' in (res + tail):
            print('\n  ❌ 固件报错，看上面的 REASON')
    finally:
        wire.close()
        port.close()


if __name__ == '__main__':
    main()
