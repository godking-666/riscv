"""通用 UART Loader 下载 + 串口捕获工具（跑任意 DDR 应用）。

现有 tools/coremark_score/run.py 只认写死的两个 APPS 路径；本工具支持任意
--bin，复用同一套 Loader 序列（tools/camera_uart/loader_plan）与原始字节记录。

用法：
  python -X utf8 tools/loader_run_bin.py --port COM7 \
      --bin coremark/build/coremark.bin --seconds 60 \
      --log-dir sim/coremark_o3/board/perf7000_o3

判据由使用者自己看日志；本工具只负责"可靠地下载并完整记录"。
"""
import argparse
import hashlib
import json
import sys
import time
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT / 'tools' / 'camera_uart'))
from capture import loader_plan          # noqa: E402
from protocol import Wire                # noqa: E402

BASE = 0x4000_0000


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--port', required=True)
    p.add_argument('--bin', required=True, type=Path)
    p.add_argument('--seconds', type=float, default=60.0, help='下载完成后捕获串口的秒数')
    p.add_argument('--log-dir', required=True, type=Path)
    p.add_argument('--loader-wait', type=float, default=30.0)
    args = p.parse_args()

    if args.log_dir.exists():
        raise SystemExit('目录已存在，请换一个：%s' % args.log_dir)
    raw = args.bin.read_bytes()
    info = dict(bin_path=str(args.bin.resolve()), bytes=len(raw),
                crc32=zlib.crc32(raw) & 0xffffffff,
                base=BASE, entry=BASE)
    print('BIN    : %s (%d B, crc32=%08x, sha256=%s)'
          % (args.bin, len(raw), info['crc32'],
             hashlib.sha256(raw).hexdigest()[:16]))

    import serial
    args.log_dir.mkdir(parents=True)
    port = serial.Serial(args.port, 115200, timeout=0.05, write_timeout=5)
    wire = Wire(port, args.log_dir)
    lines = []
    try:
        for _ in range(3):
            wire.write(b'Q')
            time.sleep(0.25)
        time.sleep(0.5)
        port.reset_input_buffer()

        print('[1/2] Loader 下载 ...')
        plans = list(loader_plan(info))
        deadline = time.monotonic() + args.loader_wait
        for i, plan in enumerate(plans):
            tx = bytes.fromhex(plan['tx_hex'])
            expect = bytes.fromhex(plan['expected_hex'])
            got = b''
            while True:
                if wire.in_waiting:
                    wire.read(wire.in_waiting)
                wire.write(tx)
                got = b''
                t = time.monotonic() + 1.0
                while len(got) < 60 and time.monotonic() < t:
                    got += wire.read(60 - len(got))
                if len(got) == 60:
                    break
                if i != 0 or time.monotonic() >= deadline:
                    raise SystemExit('Loader 第 %d 步无应答' % (i + 1))
            if got != expect:
                raise SystemExit('Loader 第 %d 步应答不符' % (i + 1))
        print('      %d 步全部应答正确，开始捕获 %.0f 秒' % (len(plans), args.seconds))

        print('[2/2] 捕获串口 ...')
        buf = b''
        end = time.monotonic() + args.seconds
        while time.monotonic() < end:
            chunk = wire.read(port.in_waiting or 1)
            if not chunk:
                continue
            buf += chunk
            while b'\n' in buf:
                ln, buf = buf.split(b'\n', 1)
                s = ln.decode('latin-1').rstrip('\r')
                lines.append(s)
                print('  | ' + s)
            if b'PORT_DONE' in chunk:
                print('      (看到 PORT_DONE，提前结束)')
                break
        if buf:
            lines.append(buf.decode('latin-1'))
    finally:
        try:
            wire.close()
        except Exception:
            pass
        try:
            port.close()
        except Exception:
            pass

    (args.log_dir / 'output.txt').write_text('\n'.join(lines) + '\n', encoding='utf-8')
    (args.log_dir / 'meta.json').write_text(json.dumps(
        dict(bin=str(args.bin), bytes=len(raw), crc32=info['crc32'],
             sha256=hashlib.sha256(raw).hexdigest(), lines=len(lines)),
        indent=2) + '\n', encoding='utf-8')
    print('\n共 %d 行 -> %s' % (len(lines), args.log_dir / 'output.txt'))


if __name__ == '__main__':
    main()
