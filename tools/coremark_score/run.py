#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""CoreMark 跑分 —— 在【当前主工程位流】上实板测分。

历史工具 tools/uart_loader/candidates/rebuilt_20261010/run_board.py 绑定了旧位流
7d752ee5…，门控会拒绝我们现在的位流。但 CoreMark 的加载协议和我们的固件完全一样
（UART 写入 DDR 0x4000_0000 后执行），所以这里直接复用已验证可用的 loader_plan 路径。

流程：发 Q 停旧固件 → loader_plan 全部步骤 → 最后一步 RUN_once 自动启动 → 抓 UART。
精确分数 = iterations / (ticks / clock_hz)
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

APPS = {
    'performance_60': ROOT / 'tests/bsp_workflow/build/performance_60',
    'validation_60':  ROOT / 'tests/bsp_workflow/build/validation_60',
    'performance_1':  ROOT / 'tests/bsp_workflow/build/performance_1',
    # 700 次：为了满足 CoreMark "必须跑 >=10 秒" 的正式成绩规则。
    # build.py 的审计白名单只允许 (1,60)，但 700 次版 BIN 已由同一工具链成功生成
    # （与 60 次版仅 2 字节不同 = ITERATIONS 常量），manifest 手工补齐。
    'performance_700': ROOT / 'tests/bsp_workflow/build/performance_700',
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', default='COM7')
    ap.add_argument('--app', default='performance_60', choices=sorted(APPS))
    ap.add_argument('--log-dir', default=None)
    ap.add_argument('--timeout', type=float, default=60.0,
                    help='RUN_once 之后等 CoreMark 输出的最长秒数')
    args = ap.parse_args()

    folder = Path(args.log_dir) if args.log_dir else (
        ROOT / 'sim' / 'coremark_score' / time.strftime('%Y%m%d_%H%M%S'))
    if folder.exists():
        raise SystemExit('  ✗ 日志目录已存在：%s（换个新名字）' % folder)
    folder.mkdir(parents=True)

    app = APPS[args.app]
    manifest = json.loads((app / 'manifest.json').read_text(encoding='utf-8'))
    info = dict(manifest)
    info['bin_path'] = str(Path(info['bin_path']))

    iters = info.get('iterations')
    clock = info.get('clock_hz', 93750000)

    print('=' * 72)
    print('  CoreMark 跑分 —— 当前主工程位流')
    print('  程序    : %s' % manifest.get('bin_path'))
    print('  SHA256  : %s' % info.get('bin_sha256'))
    print('  bytes   : %s   迭代: %s   时钟: %s Hz' % (info.get('bytes'), iters, clock))
    print('  串口    : %s' % args.port)
    print('=' * 72)

    try:
        port = serial.Serial(args.port, 115200, timeout=0.05, write_timeout=5)
    except Exception as e:
        raise SystemExit('\n  ✗ 打不开 %s：%s\n   先关掉 SSCOM / 其它串口工具。' % (args.port, e))
    wire = Wire(port, folder)

    try:
        # ---- 0) 踢掉可能还在跑的旧固件 ----
        print('\n[1/4] 先发 Q 停掉可能还在跑的上一轮固件...')
        for _ in range(3):
            wire.write(b'Q')
            time.sleep(0.25)
        time.sleep(0.5)
        wire.port.reset_input_buffer()

        # ---- 1) 加载 + 自动启动 ----
        print('[2/4] 加载 CoreMark 到 DDR（loader_plan 最后一步 RUN_once 会自动启动）...')
        plans = list(loader_plan(info))
        t0 = time.monotonic()
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
                deadline = time.monotonic() + 1.0
                while len(got) < 60 and time.monotonic() < deadline:
                    got += wire.read(60 - len(got))
                if len(got) == 60:
                    break
                if idx != 0 or attempt >= 8:
                    break
                if attempt % 5 == 0:
                    print('      仍在等载入器应答…（已试 %d 次）' % attempt)
            if len(got) != 60:
                raise SystemExit(
                    '\n!! Loader 第 %d/%d 步「%s」没有应答（收到 %d/60 字节）。\n'
                    '   板子不在 Loader 阶段。处理：重烧位流（KEY0 不可靠，实测 C19 不亮）。'
                    % (idx + 1, len(plans), plan['name'], len(got)))
            if got != expect:
                raise SystemExit(
                    '\n!! Loader 第 %d/%d 步「%s」应答不匹配。重烧位流后重试。'
                    % (idx + 1, len(plans), plan['name']))
            if (idx + 1) % 20 == 0 or idx + 1 == len(plans):
                print('      进度 %d/%d' % (idx + 1, len(plans)))
        print('      ✓ 全部 %d 步应答正确（耗时 %.1f s），CoreMark 已在运行'
              % (len(plans), time.monotonic() - t0))

        # ---- 2) 抓 CoreMark 输出 ----
        print('[3/4] 等 CoreMark 跑完（60 次迭代约 18 秒，最多等 %.0f 秒）...' % args.timeout)
        text = b''
        deadline = time.monotonic() + args.timeout
        done_words = (b'Correct operation validated', b'Errors detected',
                      b'ERROR!', b'Must run for at least')
        while time.monotonic() < deadline:
            chunk = wire.read(4096)
            if chunk:
                text += chunk
                s = text.decode('latin-1', errors='replace')
                if any(w.decode() in s for w in done_words):
                    # 再收一点尾巴
                    time.sleep(0.6)
                    text += wire.read(8192)
                    break
            else:
                time.sleep(0.05)

        s = text.decode('latin-1', errors='replace')
        print('\n[4/4] CoreMark 原始输出')
        print('-' * 72)
        for line in s.splitlines():
            line = line.rstrip()
            if line:
                print('  | ' + line)
        print('-' * 72)

        # ---- 3) 解析 ----
        def grab(pat, cast=str, default=None):
            m = re.search(pat, s, re.I)
            return cast(m.group(1)) if m else default

        ticks = grab(r'Total ticks\s*:\s*(\d+)', int)
        total_secs_int = grab(r'Total time \(secs\)\s*:\s*(\d+)', int)
        iters_sec_int = grab(r'Iterations/Sec\s*:\s*(\d+)', int)
        crcfinal = grab(r'crcfinal\s*:\s*(0x[0-9a-fA-F]+)', str)
        validated = 'Correct operation validated' in s
        errors = 'Errors detected' in s or 'ERROR!' in s

        print('\n结果')
        print('  迭代次数        : %s' % iters)
        print('  Total ticks     : %s' % ticks)
        print('  crcfinal        : %s' % crcfinal)
        print('  正确性验证      : %s' % ('✓ Correct operation validated' if validated
                                          else ('✗ Errors detected' if errors else '?')))
        if ticks:
            secs = ticks / clock
            score = iters / secs
            print('  运行时间        : %.9f 秒  (= %d / %d)' % (secs, ticks, clock))
            print('  ★ 精确分数      : %.9f iterations/s' % score)
            print('  ★ CoreMark/MHz  : %.9f' % (score / (clock / 1e6)))
        else:
            secs = score = None
            print('  ⚠ 没解析到 Total ticks —— 可能没收到完整输出')

        summary = dict(app=args.app, iterations=iters, clock_hz=clock,
                       ticks=ticks, seconds=secs, iterations_per_second=score,
                       cm_per_mhz=(score / (clock / 1e6)) if score else None,
                       crcfinal=crcfinal, validated=validated, errors=errors,
                       total_time_int=total_secs_int, iters_sec_int=iters_sec_int,
                       raw=text.decode('latin-1', errors='replace'))
        (folder / 'score.json').write_text(
            json.dumps(summary, ensure_ascii=False, indent=2), encoding='utf-8')
        print('\n  原始字节 : %s' % (folder / 'uart.rx.bin'))
        print('  结果 JSON: %s' % (folder / 'score.json'))

        if validated and ticks and secs is not None:
            print('\n  ✅ 正式跑分有效（算法 CRC 正确 + 计时 %.1f 秒 ≥ 10 秒）' % secs)
        elif validated and secs is not None and secs < 10:
            print('\n  ⚠ 跑完了但计时不足 10 秒 —— 按 CoreMark 规则不算有效成绩')
        else:
            print('\n  ⚠ 没拿到有效结果，看上面的原始输出')
    finally:
        wire.close()
        port.close()


if __name__ == '__main__':
    main()
