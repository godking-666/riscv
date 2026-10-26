"""从板子的实时流里抓取 96x96 RGB 中间图（模型真正的输入），用于数据集采集与取证。

复用 tools/cnn_digits_stream 的固件身份约定与 tools/camera_uart 的 Loader 序列，
不改任何已验收文件。流程：Loader 下载固件 → 等 CNN_READY → 发 G → 等首帧
→ 发 'd' → 收 CN03 包（kind=1 分块 / kind=2 结束，每包回一个 'K'）→ 存 PNG。

注意：
  * 每包校验 CRC 后必须回 1 字节 'K'，否则固件 EXPORT_ACK_TIMEOUT（main.c send_packet）
  * 一次 dump 约 2.4 s（27648 B @115200），比帧率慢，所以是抽样
  * 输出目录必须**全新**；本工具只取 96x96，整幅 1280x720 请用单帧拍照版固件

用法：
  python -X utf8 tools/cnn_digits_stream/dump.py --port COM7 --build bookcup_dump \
      --out sim/bookcup_real/book --label book --count 25
"""
import argparse
import hashlib
import json
import struct
import sys
import time
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(ROOT / 'tools' / 'camera_uart'))
from capture import loader_plan          # noqa: E402
from protocol import Wire                # noqa: E402

W_HDR = 32
MAGIC = b'CN03'
OUT_BYTES = 27648                        # 96*96*3
ACK = b'K'


def png96(rgb, path):
    w = h = 96
    rows = b''.join(b'\x00' + rgb[y * w * 3:(y + 1) * w * 3] for y in range(h))

    def chunk(tag, data):
        return (struct.pack('>I', len(data)) + tag + data +
                struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff))

    path.write_bytes(b'\x89PNG\r\n\x1a\n' +
                     chunk(b'IHDR', struct.pack('>2I5B', w, h, 8, 2, 0, 0, 0)) +
                     chunk(b'IDAT', zlib.compress(rows, 6)) +
                     chunk(b'IEND', b''))


def read_exact(wire, n, timeout=8.0):
    buf = b''
    end = time.monotonic() + timeout
    while len(buf) < n:
        if time.monotonic() > end:
            return None
        c = wire.read(n - len(buf))
        if c:
            buf += c
    return buf


def read_until(wire, marker, timeout=30.0):
    buf = bytearray()
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        c = wire.read(1)
        if c:
            buf += c
            if buf.endswith(marker):
                return bytes(buf)
    return bytes(buf)


def read_line(wire, timeout=30.0):
    return read_until(wire, b'\n', timeout).decode('latin-1').strip()


def recv_rgb(wire):
    """收一次 96x96 导出，返回 (rgb_bytes, err)。"""
    got = read_until(wire, b'CNN_EXPORT_BEGIN\n', 10.0)
    if b'CNN_EXPORT_BEGIN' not in got:
        return None, 'no CNN_EXPORT_BEGIN: ' + got.decode('latin-1')[-160:]
    data = bytearray(OUT_BYTES)
    while True:
        hdr = read_exact(wire, W_HDR)
        if hdr is None:
            return None, 'header timeout'
        if hdr[0:4] != MAGIC:
            return None, 'bad magic %r' % hdr[0:4]
        kind, seq, offset, length, total, dcrc = struct.unpack('<6I', hdr[4:28])
        want = struct.unpack('<I', hdr[28:32])[0]
        if zlib.crc32(hdr[:28]) & 0xffffffff != want:
            return None, 'bad header crc'
        if total != OUT_BYTES:
            return None, 'unexpected total %d' % total
        if kind == 2:
            crc = zlib.crc32(bytes(data)) & 0xffffffff
            wire.write(ACK)
            if crc != dcrc:
                return None, 'payload crc mismatch %08x != %08x' % (crc, dcrc)
            return bytes(data), None
        if kind != 1:
            return None, 'unexpected kind %d' % kind
        if offset + length > OUT_BYTES:
            return None, 'offset overflow'
        payload = read_exact(wire, length)
        if payload is None:
            return None, 'payload timeout at %d' % offset
        if zlib.crc32(payload) & 0xffffffff != dcrc:
            wire.write(ACK)
            return None, 'chunk crc mismatch at %d' % offset
        data[offset:offset + length] = payload
        wire.write(ACK)


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--port', required=True)
    p.add_argument('--build', required=True)
    p.add_argument('--out', required=True, type=Path)
    p.add_argument('--count', type=int, default=1)
    p.add_argument('--label', default='')
    p.add_argument('--loader-wait', type=float, default=60.0)
    args = p.parse_args()

    if args.out.exists():
        raise SystemExit('目录已存在，请换一个：%s' % args.out)
    build = ROOT / 'tests/cnn_digits_stream/build' / args.build
    man = json.loads((build / 'manifest.json').read_text(encoding='utf-8'))
    fw = build / 'program.bin'
    if hashlib.sha256(fw.read_bytes()).hexdigest() != man['bin_sha256']:
        raise SystemExit('固件 SHA256 与 manifest 不符')

    import serial
    args.out.mkdir(parents=True)
    port = serial.Serial(args.port, 115200, timeout=0.05, write_timeout=5)
    wire = Wire(port, args.out)
    index = []
    try:
        for _ in range(3):
            wire.write(b'Q')
            time.sleep(0.25)
        time.sleep(0.5)
        port.reset_input_buffer()

        print('[1/3] Loader 下载固件 %s ...' % args.build)
        plans = list(loader_plan(man))
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
                    raise SystemExit('Loader 第 %d 步无应答，按 KEY0 复位后重试' % (i + 1))
            if got != expect:
                raise SystemExit('Loader 第 %d 步应答不符' % (i + 1))
        print('      %d 步全部应答正确' % len(plans))

        print('[2/3] 等 CNN_READY ...')
        while True:
            ln = read_line(wire, 60)
            if not ln:
                raise SystemExit('等不到 banner（超时）')
            print('      ' + ln[:160])
            if ln.startswith('CNN_READY'):
                break
            if ln.startswith(('CNN_FAIL', 'ERR')):
                raise SystemExit('固件报错：' + ln[:200])
        wire.write(b'G')

        print('[3/3] 开始抓 %d 张 96x96 ...' % args.count)
        for n in range(args.count):
            ln = read_line(wire, 30)
            while ln and 'STREAM_FRAME' not in ln:
                if ln.startswith(('CNN_FAIL', 'ERR')):
                    raise SystemExit('固件报错：' + ln[:200])
                ln = read_line(wire, 30)
            if not ln:
                raise SystemExit('等不到 STREAM_FRAME')
            wire.write(b'd')
            rgb, err = recv_rgb(wire)
            if err:
                raise SystemExit('第 %d 张导出失败：%s' % (n + 1, err))
            name = '%s_%03d.png' % (args.label or 'frame', n + 1)
            png96(rgb, args.out / name)
            index.append(dict(file=name, label=args.label,
                              sha256=hashlib.sha256(rgb).hexdigest()))
            print('      %s  (%d)' % (name, n + 1))
            (args.out / 'index.json').write_text(
                json.dumps(index, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        wire.write(b'Q')
        time.sleep(0.3)
    finally:
        try:
            wire.close()
        except Exception:
            pass
        try:
            port.close()
        except Exception:
            pass
    print('\n完成：%d 张 -> %s' % (len(index), args.out))


if __name__ == '__main__':
    main()
