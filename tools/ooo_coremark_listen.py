"""监听队友 OoO 位流的 CoreMark 串口输出。

不启动 PDS、不改 HDL、不发送任何字节 —— 只读 COM7 并记录原始字符。
收到 PORT_DONE 或超时即退出，日志落到 --log 指定的文件。

用法：
  python -X utf8 tools/ooo_coremark_listen.py --port COM7 --seconds 40 \
         --log sim/ooo_coremark/board/first/run.log
"""
import argparse
import sys
import time
from pathlib import Path

DONE_MARKERS = ('PORT_DONE', 'Correct operation validated')


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--port', required=True)
    p.add_argument('--seconds', type=float, default=40.0)
    p.add_argument('--log', required=True, type=Path)
    args = p.parse_args()

    try:
        import serial
    except ImportError:
        raise SystemExit('缺少 pyserial')

    args.log.parent.mkdir(parents=True, exist_ok=True)
    port = serial.Serial(args.port, 115200, timeout=0.1)
    buf = b''
    lines = []
    t0 = time.monotonic()
    print('监听 %s，最多 %.0f 秒（看到 PORT_DONE 提前结束）...' % (args.port, args.seconds))
    try:
        while time.monotonic() - t0 < args.seconds:
            chunk = port.read(port.in_waiting or 1)
            if not chunk:
                continue
            buf += chunk
            while b'\n' in buf:
                raw, buf = buf.split(b'\n', 1)
                ln = raw.decode('latin-1').rstrip('\r')
                lines.append(ln)
                print('  [%6.2fs] %s' % (time.monotonic() - t0, ln))
            if any(m in '\n'.join(lines[-3:]) for m in DONE_MARKERS):
                print('  -> 命中完成标记，提前结束')
                break
    finally:
        if buf:
            lines.append(buf.decode('latin-1'))
        port.close()

    args.log.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    print('\n共 %d 行，已写入 %s' % (len(lines), args.log))
    if not lines:
        print('⚠ 一个字节都没收到：确认已烧位流、串口没被占用、必要时按一下 KEY0 复位')
        sys.exit(1)


if __name__ == '__main__':
    main()
