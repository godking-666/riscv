"""一键跑完集成 SoC 的三项实板验收。

按顺序做四步，每步都有明确判据，最后给汇总表：

  0. Loader 探活        —— PING 得到 60 字节 RVLD 应答
  1. 跑分（同口径）     —— 队友完整编译选项的 CoreMark，算 CoreMark/MHz @135 MHz
  2. 停摆验收           —— 长时打印固件必须打到 "STALLTEST end"
  3. CNN 流式识别       —— bookcup 固件跑若干帧，统计各类计数

用法：
  python tools/board_acceptance.py --port COM7
  python tools/board_acceptance.py --port COM7 --skip-cnn     # 只跑前 3 项
  python tools/board_acceptance.py --port COM7 --session t1   # 自定义会话目录名

产物：sim/acceptance/<session>/ 下每个子步骤的原始日志 + summary.json
"""
import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PY = sys.executable

COREMARK_BIN = ROOT / 'coremark/build_his_7000/program.bin'
STALL_BIN = ROOT / 'tests/stall_test/build/stall.bin'
CNN_BUILD = 'bookcup_b'

CLOCK_HZ = 135_000_000          # CPU 时钟（CoreMark/MHz 用这个）
TICK_HZ = 93_750_000            # CYCLE 计数器所在域


def run(cmd, timeout):
    """跑子进程，返回 (ok, stdout+stderr)。"""
    try:
        p = subprocess.run(cmd, cwd=str(ROOT), capture_output=True, text=True,
                           timeout=timeout, encoding='utf-8', errors='replace')
        return p.returncode == 0, (p.stdout or '') + (p.stderr or '')
    except subprocess.TimeoutExpired as e:
        return False, 'TIMEOUT after %ss' % timeout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', default='COM7')
    ap.add_argument('--skip-cnn', action='store_true')
    ap.add_argument('--cnn-frames', type=int, default=40)
    ap.add_argument('--session', default=time.strftime('%Y%m%d_%H%M%S'))
    args = ap.parse_args()

    session = ROOT / 'sim/acceptance' / args.session
    session.mkdir(parents=True, exist_ok=True)
    results = []

    def record(name, ok, detail):
        results.append({'check': name, 'ok': ok, 'detail': detail})
        print('  [%s] %s — %s' % ('PASS' if ok else 'FAIL', name, detail))

    # ---------------- 0) Loader 探活 ----------------
    print('\n[0/3] Loader 探活 ...')
    ok, out = run([PY, '-X', 'utf8', 'tools/cnn_digits_stream/probe_loader.py',
                   '--port', args.port], timeout=90)
    alive = ('收到 60' in out) or ('Loader 就绪' in out)
    (session / '0_probe.log').write_text(out, encoding='utf-8')
    record('Loader 探活', alive, 'PING 有应答' if alive else '无应答（板子需要重烧位流）')
    if not alive:
        print('\nLoader 不在，后续步骤无法进行。')
        _summary(session, results)
        return 1

    # ---------------- 1) CoreMark（同口径） ----------------
    print('\n[1/3] CoreMark（队友完整编译选项，7000 迭代）...')
    d = session / '1_coremark'
    ok, out = run([PY, '-u', '-X', 'utf8', 'tools/loader_run_bin.py',
                   '--port', args.port, '--bin', str(COREMARK_BIN.relative_to(ROOT)),
                   '--seconds', '120', '--log-dir', str(d.relative_to(ROOT))], timeout=600)
    txt = ''
    if (d / 'output.txt').exists():
        txt = (d / 'output.txt').read_text(encoding='utf-8', errors='replace')
    m = re.search(r'PORT_DONE\s+ticks=(\d+)\s+iterations=(\d+)', txt)
    if not m:
        record('CoreMark', False, '没拿到 PORT_DONE（可能停摆或固件没跑起来）')
    else:
        ticks, iters = int(m.group(1)), int(m.group(2))
        secs = ticks / TICK_HZ
        iter_s = iters / secs
        cm_mhz = iter_s / (CLOCK_HZ / 1e6)
        cyc_per_iter = int(secs * CLOCK_HZ / iters)
        detail = ('ticks=%d iterations=%d → %.3f iter/s，%d 周期/迭代，'
                  '**%.4f CoreMark/MHz**' % (ticks, iters, iter_s, cyc_per_iter, cm_mhz))
        # 判据：同口径下应落在 3.5~4.9（见 doc/ooo_integration/跑分归因）
        record('CoreMark', 3.5 <= cm_mhz <= 5.5, detail)
        (session / '1_coremark').mkdir(exist_ok=True)

    # ---------------- 2) 停摆验收 ----------------
    print('\n[2/3] 停摆验收（长时打印 + 跨 cache line 写）...')
    d = session / '2_stall'
    ok, out = run([PY, '-u', '-X', 'utf8', 'tools/loader_run_bin.py',
                   '--port', args.port, '--bin', str(STALL_BIN.relative_to(ROOT)),
                   '--seconds', '120', '--log-dir', str(d.relative_to(ROOT))], timeout=600)
    txt = ''
    if (d / 'output.txt').exists():
        txt = (d / 'output.txt').read_text(encoding='utf-8', errors='replace')
    done = 'STALLTEST end' in txt
    lines = len(re.findall(r'^line \d+', txt, re.M))
    record('停摆验收', done, '跑到 end，打印 %d 行' % lines if done
           else '未跑到 end（打印了 %d 行就停了）' % lines)

    # ---------------- 3) CNN 流式识别 ----------------
    if args.skip_cnn:
        print('\n[3/3] CNN 跳过（--skip-cnn）')
    else:
        print('\n[3/3] CNN 流式识别（%s，%d 帧）...' % (CNN_BUILD, args.cnn_frames))
        ok, out = run([PY, '-u', '-X', 'utf8', 'tools/cnn_digits_stream/run.py',
                       '--port', args.port, '--build', CNN_BUILD,
                       '--frames', str(args.cnn_frames)], timeout=900)
        (session / '3_cnn.log').write_text(out, encoding='utf-8')
        # 统计各类计数
        counts = {}
        for name in ('book', 'cup', 'other'):
            mm = re.findall(r'%s[^\d]{0,8}(\d+)' % name, out, re.I)
            if mm:
                counts[name] = int(mm[-1])
        frames = re.search(r'(\d+)\s*帧', out)
        record('CNN 流式识别', bool(counts) and any(v > 0 for v in counts.values()),
               '帧数=%s 分类计数=%s' % (frames.group(1) if frames else '?', counts or '解析失败'))

    _summary(session, results)
    return 0 if all(r['ok'] for r in results) else 1


def _summary(session, results):
    print('\n' + '=' * 70)
    print(' 验收汇总  (会话目录 %s)' % session)
    print('=' * 70)
    for r in results:
        print(' %-4s %-16s %s' % ('✓' if r['ok'] else '✗', r['check'], r['detail']))
    (session / 'summary.json').write_text(
        json.dumps(results, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
    n_ok = sum(1 for r in results if r['ok'])
    print('\n %d/%d 项通过' % (n_ok, len(results)))


if __name__ == '__main__':
    sys.exit(main())
