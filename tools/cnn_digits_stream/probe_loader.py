"""Loader 原始探针 —— 判断板子到底在什么状态。

不做完整固件下载，只做三件事：
  1. 被动监听 N 秒（抓任何开机 banner / 残留输出）
  2. 发 PING（RVLD 魔数）若干次，每次把收到的原始字节以 hex 打出来
  3. 给出判读：完全无响应 / 有响应但格式不对 / Loader 就绪

用法：
  python -X utf8 tools/cnn_digits_stream/probe_loader.py --port COM7
  python -X utf8 tools/cnn_digits_stream/probe_loader.py --port COM7 --listen 5 --ping 5
"""
import argparse
import json
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(ROOT / 'tools' / 'camera_uart'))
from capture import loader_plan   # noqa: E402

MANIFEST = None  # 运行时自动挑选最新构建


def find_manifest():
    """自动选 build/ 下最新的 stream_* 构建（含 manifest.json）。"""
    base = ROOT / 'tests/cnn_digits_stream/build'
    cands = sorted([p for p in base.glob('stream_*/manifest.json')],
                   key=lambda p: p.parent.name, reverse=True)
    if not cands:
        raise SystemExit('  ✗ 找不到任何构建：%s 下没有 stream_*/manifest.json' % base)
    return cands[0]


def hexdump(data, limit=200):
    h = data[:limit].hex()
    return ' '.join(h[i:i + 2] for i in range(0, len(h), 2))


def ascii_of(data, limit=120):
    return ''.join(chr(b) if 32 <= b < 127 else '.' for b in data[:limit])


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--port', required=True)
    p.add_argument('--listen', type=float, default=3.0, help='先被动监听几秒（默认 3）')
    p.add_argument('--ping', type=int, default=3, help='发几次 PING（默认 3）')
    p.add_argument('--wait', type=float, default=1.5, help='每次 PING 后等几秒（默认 1.5）')
    args = p.parse_args()

    import serial
    manifest_path = find_manifest()
    print('  使用构建 : %s' % manifest_path.parent.name)
    manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    plans = list(loader_plan(manifest))
    ping = plans[0]
    tx = bytes.fromhex(ping['tx_hex'])
    expect = bytes.fromhex(ping['expected_hex'])

    print('=' * 74)
    print(' Loader 原始探针')
    print('  端口      : %s' % args.port)
    print('  PING TX   : %d 字节  %s' % (len(tx), hexdump(tx, 40)))
    print('  PING 期望 : %d 字节  %s' % (len(expect), hexdump(expect, 40)))
    print('=' * 74)

    try:
        s = serial.Serial(args.port, 115200, timeout=0.05, write_timeout=2)
    except Exception as e:
        raise SystemExit('  ✗ 串口打不开: %s\n     （串口助手占用？）' % e)

    tag = ('CP210x=b\r\n').encode() if False else b''
    _ = tag  # 占位，保持无副作用

    try:
        # ---------- 1) 被动监听 ----------
        print('\n[1] 被动监听 %.1f 秒（不发任何东西）…' % args.listen)
        s.reset_input_buffer()
        idle = bytearray()
        t0 = time.monotonic()
        while time.monotonic() - t0 < args.listen:
            n = s.in_waiting
            if n:
                idle += s.read(n)
            else:
                time.sleep(0.02)
        print('    收到 %d 字节' % len(idle))
        if idle:
            print('    hex: %s' % hexdump(idle))
            print('    可读: %s' % ascii_of(idle))
        else:
            print('    (完全静默)')

        # ---------- 2) 发 PING ----------
        print('\n[2] 发 PING %d 次，每次等 %.1f 秒…' % (args.ping, args.wait))
        results = []
        for i in range(1, args.ping + 1):
            s.reset_input_buffer()
            s.write(tx)
            s.flush()
            got = bytearray()
            t0 = time.monotonic()
            while time.monotonic() - t0 < args.wait:
                n = s.in_waiting
                if n:
                    got += s.read(n)
                    if len(got) >= 60:
                        break
                else:
                    time.sleep(0.01)
            results.append(bytes(got))
            print('    第 %d 次: 收到 %d 字节' % (i, len(got)))
            if got:
                print('      hex: %s' % hexdump(got))
                print('      可读: %s' % ascii_of(got))
            time.sleep(0.2)

        # ---------- 3) 判读 ----------
        print('\n' + '=' * 74)
        print(' 判读')
        print('=' * 74)
        best = max(results, key=len) if results else b''
        if len(best) == 0:
            print('  ✗ 完全无响应（一次都没回字节）')
            print()
            print('  这意味着板子上的 FPGA 里**没有在跑 Loader**。可能：')
            print('    a) 位流没烧成功 / 没烧（FPGA 未配置）')
            print('    b) 烧的是**不含 Loader 的位流**（比如厂商 demo 的 Top.sbit）')
            print('    c) CPU 卡在别处，没走到 Loader 的等待状态')
            print('    d) FPGA 的 UART 引脚(C24 TXD / B24 RXD) 没接到这颗 CP210x')
            print()
            print('  → 建议：重新烧 D:\\riscv\\RISCV\\generate_bitstream\\board_top.sbit')
            print('           （SHA256 d315d015…），烧完按 KEY0 再看 C18/C19。')
        elif len(best) < 60:
            print('  ⚠ 有响应但字节数不足（%d/60）' % len(best))
            print('    可能是波特率不对、或响应被截断、或 RX 方向有问题。')
        elif best[:4] == expect[:4]:
            print('  ✓ Loader 就绪！响应头 %s 匹配' % best[:4].hex())
            print('    → 可以直接跑 run.py 下载固件了')
        else:
            print('  ⚠ 收到 %d 字节，但魔数不对（收到 %s，期望 %s）'
                  % (len(best), best[:4].hex(), expect[:4].hex()))
            print('    可能是别的固件在跑（回的是它自己的输出），或波特率/位序有问题。')

        print()
        print(' 参考：期望响应头 4 字节 = %s（ASCII "RVLD"）' % expect[:4].hex())
    finally:
        try:
            s.close()
        except Exception:
            pass


if __name__ == '__main__':
    main()
