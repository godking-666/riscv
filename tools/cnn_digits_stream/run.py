"""cnn_digits_stream 连续视频流 runner。

流程：加载固件（Loader 序列）→ 等 banner 到 CNN_READY → 发 'G'
      → 持续解析 STREAM_FRAME 行 → 达到帧数或 Ctrl+C 后发 'Q' → 收尾。

复用 tools/camera_uart 的 Loader 序列生成与 Wire 原始字节记录（uart.rx.bin / uart.tx.bin），
不重写任何协议。不启动 PDS、不改 HDL。

用法：
  # 连续跑 20 帧（每帧约 1 行结果）
  python -X utf8 tools/cnn_digits_stream/run.py --port COM12 --frames 20 \
         --log-dir sim/cnn/stream_t1

  # 一直跑到 Ctrl+C
  python -X utf8 tools/cnn_digits_stream/run.py --port COM12 --frames 0 \
         --log-dir sim/cnn/stream_t2

注意：
  * --log-dir 必须是**全新**目录（Wire 用 'xb' 打开记录文件）
  * 板子串口是 CP210x（队友实测 COM12，我这边之前见过 COM7）
  * 开跑前不要同时开串口助手占用端口
  * DDR 易失：KEY0 复位后必须重新加载固件
"""
import argparse
import hashlib
import json
import re
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]

# 复用现成的 Loader 序列与串口记录层
sys.path.insert(0, str(ROOT / 'tools' / 'camera_uart'))
from capture import loader_plan          # noqa: E402
from protocol import Wire, need, line    # noqa: E402

TAG = 'stream_20261020_i'                 # 默认固件（digits 十类，已验收）
BUILD_ROOT = ROOT / 'tests/cnn_digits_stream/build'
BUILD = BUILD_ROOT / TAG
MANIFEST = BUILD / 'manifest.json'
FIRMWARE = BUILD / 'program.bin'
# g: 软重启后复用已装载的 CNN 模型（clear_cmd 清 done，跳过 6222 词上传）
# f: 收尾不再严格 cam_idle_state   e: 连续流式取帧（13.9 fps）
# d: halt() 软重启回 Loader —— 跑完能直接再跑，不用重烧位流
# c: 每轮 ledger_reset()   b: cnn_check_model 只查"模型已装载"位
BIN_SHA256 = '1478005006bc073a48660a53e617c9a188667eb6bf723e271c224b5d3fd77f9b'

# 固件每帧输出：CNN_JOB 一行 + SOURCE 一行 + STREAM_FRAME 一行
FRAME = re.compile(
    r'STREAM_FRAME NO=(\d+) CLS=(\d+) CNN_CYC=(\d+) PP_CYC=(\d+) CONF=(-?\d+)/(-?\d+)')
DONE = re.compile(r'CNN_STREAM_DONE FRAMES=(\d+) DUMPS=(\d+) CPU_CYCLES=(\d+)')
# fail() 的输出特征（固件里任何断言失败都会走这里）
ERRORISH = re.compile(r'^(ERR|FAIL|CNN_ERROR|PP_|CAMERA_|MODEL_|SOURCE_IDENTITY|UART_RX)')


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save(folder, value):
    (Path(folder) / 'result.json').write_text(
        json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def open_port(name):
    try:
        import serial
    except ImportError:
        raise SystemExit('缺少 pyserial：pip install pyserial')
    return serial.Serial(name, 115200, timeout=0.05, write_timeout=5)


def wait_ready(wire, seconds):
    """读到 CNN_READY 为止，期间把 banner 全部打印并收集。"""
    deadline = time.monotonic() + seconds
    banners = []
    while time.monotonic() < deadline:
        raw = line(wire, seconds=1.0)
        if raw is None or raw == '':
            continue
        banners.append(raw)
        print('  ' + raw)
        if ERRORISH.match(raw):
            raise SystemExit('固件报错（加载阶段）：' + raw)
        if raw.startswith('CNN_READY'):
            return banners
    raise SystemExit('等不到 CNN_READY（%.0f s 超时）。banner 已收到 %d 行：%s'
                     % (seconds, len(banners), banners[-3:]))


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--port', required=True, help='串口名，例如 COM12')
    p.add_argument('--log-dir', required=True, type=Path, help='全新目录，保存原始字节与结果')
    p.add_argument('--frames', type=int, default=20,
                   help='要采集的帧数；0 = 一直跑到 Ctrl+C（默认 20）')
    p.add_argument('--ready-timeout', type=float, default=30.0, help='等 CNN_READY 的秒数')
    p.add_argument('--frame-timeout', type=float, default=15.0, help='单帧等待秒数')
    p.add_argument('--loader-wait', type=float, default=0.0,
                   help='先等 N 秒再发 Loader 第一步：可以先启动脚本，再按 KEY0 复位（默认 0）')
    p.add_argument('--build', default=None,
                   help='改用它目录下的固件，例如 bookcup_b（默认 %s）' % TAG)
    args = p.parse_args()

    # --build 覆盖固件身份；SHA 校验改用该 build 的 manifest 里记录的 bin_sha256，
    # 保证"载入的确实是当时构建并审计过的那个 BIN"，而不是别的 tag。
    global BUILD, MANIFEST, FIRMWARE, BIN_SHA256
    if args.build:
        BUILD = BUILD_ROOT / args.build
        MANIFEST = BUILD / 'manifest.json'
        FIRMWARE = BUILD / 'program.bin'
        BIN_SHA256 = None            # 下面从 manifest 取

    need(args.log_dir is not None and not args.log_dir.exists(), '必须给一个全新 --log-dir')
    need(FIRMWARE.exists(), '固件不存在：' + str(FIRMWARE))
    need(MANIFEST.exists(), 'manifest 不存在：' + str(MANIFEST))
    if BIN_SHA256 is None:
        _man = json.loads(MANIFEST.read_text(encoding='utf-8'))
        need(_man.get('bin_sha256') and _man.get('bin_path'),
             'manifest 缺少 bin_sha256/bin_path：' + str(MANIFEST))
        need(Path(ROOT / _man['bin_path']).resolve() == FIRMWARE.resolve(),
             'manifest 的 bin_path 与 --build 不符：%s' % _man['bin_path'])
        BIN_SHA256 = _man['bin_sha256']
    need(sha(FIRMWARE) == BIN_SHA256, '固件 SHA256 不符，请重新构建')

    args.log_dir.mkdir(parents=True)
    manifest = json.loads(MANIFEST.read_text(encoding='utf-8'))

    print('=' * 72)
    print(' 固件  : %s' % FIRMWARE)
    print(' SHA256: %s' % BIN_SHA256)
    print(' 串口  : %s' % args.port)
    print(' 帧数  : %s' % ('无限（Ctrl+C 结束）' if args.frames == 0 else args.frames))
    print('=' * 72)

    port = open_port(args.port)
    wire = Wire(port, args.log_dir)
    result = dict(status='RUNNING', firmware_sha256=BIN_SHA256, port=args.port,
                  requested_frames=args.frames, frames=[], loader_records=[])
    interrupted = False
    try:
        # ---------------- 1) Loader 下载 ----------------
        need(wire.in_waiting == 0, '起始串口有残留字节：先按 KEY0 复位，不要自动清缓')
        print('\n[1/3] 加载固件...')
        # ★ 先"踢"一下：上一轮的固件可能还在跑（它静默等 Q/G 指令，不响应 PING）。
        #   发几个 Q 让它走正常收尾路径 -> reboot_to_loader() 跳回 0x0，Loader 就活了。
        #   以前这一步要手工开串口助手发 Q，很费事。
        print('      先发 Q 停掉可能还在跑的上一轮固件...')
        for _ in range(3):
            wire.write(b'Q')
            time.sleep(0.25)
        time.sleep(0.5)
        # Q 的回应不属于 loader 协议，必须清掉，否则第 1 步 PING 对不上。
        # Wire 只暴露了 .port（底层 pyserial），没有包装 reset_input_buffer。
        wire.port.reset_input_buffer()
        plans = list(loader_plan(manifest))
        wait_deadline = time.monotonic() + args.loader_wait
        if args.loader_wait > 0:
            print('      ★ 现在去按 KEY0（USER_BUTTON0 / C22）复位。')
            print('        我在这里等 %.0f 秒，随时按都行（C19 常亮后 1~2 秒内会被抓到）。'
                  % args.loader_wait)
        for idx, plan in enumerate(plans):
            row = dict(name=plan['name'], tx=wire.tx_count, rx=wire.rx_count)
            tx = bytes.fromhex(plan['tx_hex'])
            expect = bytes.fromhex(plan['expected_hex'])
            got = b''
            attempt = 0
            while True:
                attempt += 1
                if wire.in_waiting:
                    wire.read(wire.in_waiting)    # 丢掉复位前的残留
                wire.write(tx)
                got = b''
                deadline = time.monotonic() + 1.0
                while len(got) < 60 and time.monotonic() < deadline:
                    got += wire.read(60 - len(got))
                if len(got) == 60:
                    print('      PING 有应答（第 %d 次尝试）' % attempt)
                    break
                # 只有第一步无限期等；后续步失败就报错
                if idx != 0:
                    break
                if args.loader_wait > 0:
                    if time.monotonic() >= wait_deadline:
                        break
                elif attempt >= 8:
                    break
                if attempt % 5 == 0:
                    print('      仍在等载入器应答…（已试 %d 次）按 KEY0 复位即可' % attempt)
            if len(got) != 60:
                raise SystemExit(
                    '\n!! Loader 第 %d/%d 步「%s」没有应答（收到 %d/60 字节）。\n'
                    '   板子不在 Loader 阶段——多半是上一次的固件还在跑，静默等 G/C 指令。\n'
                    '\n   处理：按一下 KEY0（USER_BUTTON0 / C22）复位，\n'
                    '         等 C19（USER_LED2）常亮约 2~4 秒后重跑本脚本。\n'
                    '   更省事：加 --loader-wait 180，然后慢慢按复位。\n'
                    % (idx + 1, len(plans), plan['name'], len(got)))
            if got != expect:
                raise SystemExit(
                    '\n!! Loader 第 %d/%d 步「%s」应答不匹配（可能有残留/错位）。\n'
                    '   处理：按 KEY0 复位，等 C19 常亮后重跑。\n'
                    % (idx + 1, len(plans), plan['name']))
            row['result'] = 'PASS'
            result['loader_records'].append(row)
        print('      Loader 全部应答正确（%d 步）' % len(result['loader_records']))

        # ---------------- 2) 等固件就绪 ----------------
        print('\n[2/3] 等固件 banner...')
        result['banners'] = wait_ready(wire, args.ready_timeout)

        # ---------------- 3) 连续取帧 ----------------
        print('\n[3/3] 发 G 开始连续取帧（%s）...'
              % ('Ctrl+C 结束' if args.frames == 0 else '%d 帧' % args.frames))
        wire.write(b'G')

        count = 0
        t0 = time.monotonic()
        interrupted = False
        while True:
            if args.frames and count >= args.frames:
                break
            raw = line(wire, seconds=args.frame_timeout)
            if raw is None or raw == '':
                continue
            m = FRAME.match(raw)
            if m:
                seq, cls, cnn_cyc, pp_cyc, best, second = m.groups()
                count += 1
                rec = dict(no=int(seq), cls=int(cls), cnn_cycles=int(cnn_cyc),
                           pp_cycles=int(pp_cyc), conf_best=int(best), conf_second=int(second))
                rec['elapsed_s'] = round(time.monotonic() - t0, 3)
                result['frames'].append(rec)
                print('  帧 %-5d 类别=%-2d CNN=%7d 周期  PP=%7d 周期  置信=%s/%s  (%.2fs)'
                      % (rec['no'], rec['cls'], rec['cnn_cycles'], rec['pp_cycles'],
                         best, second, rec['elapsed_s']))
                continue
            if DONE.match(raw):
                print('  ' + raw)
                result['done_line'] = raw
                break
            if ERRORISH.match(raw):
                print('  !! ' + raw)
                result['error_line'] = raw
                raise SystemExit('固件报错（取帧阶段）：' + raw)
            # 其它行（CNN_JOB / SOURCE / STREAM_START）原样打印便于诊断
            if raw not in ('CNN_JOB', 'SOURCE'):
                print('  · ' + raw[:150])

    except KeyboardInterrupt:
        interrupted = True
        print('\n  收到 Ctrl+C，准备收尾...')
    finally:
        # 收尾：尽力发 Q 并读残留行，但**绝不能因为收尾失败而掩盖真正的错误**
        try:
            if not interrupted and result.get('banners'):
                wire.write(b'Q')
        except Exception:
            pass
        tail = []
        try:
            deadline = time.monotonic() + 5.0
            while time.monotonic() < deadline:
                raw = line(wire, seconds=0.5)
                if raw is None or raw == '':
                    continue
                tail.append(raw)
                print('  ' + raw)
                if DONE.match(raw):
                    result['done_line'] = raw
                    break
        except Exception:
            pass
        result['tail'] = tail
        try:
            wire.close()
        except Exception:
            pass
        try:
            port.close()
        except Exception:
            pass

    elapsed = (result['frames'][-1]['elapsed_s'] if result['frames'] else 0.0)
    result.update(
        status='STREAM_CAPTURED' if result['frames'] else 'NO_FRAME',
        frame_count=len(result['frames']),
        interrupted=interrupted,
        wall_seconds=elapsed,
        effective_fps=round(len(result['frames']) / elapsed, 2) if elapsed > 0 else 0.0)
    save(args.log_dir, result)

    print('\n' + '=' * 72)
    print(' 结果：采集 %d 帧' % result['frame_count'])
    if result['frames']:
        classes = [f['cls'] for f in result['frames']]
        print(' 类别序列：%s' % classes[:30])
        print(' 平均帧间隔：%.2f s  →  %.2f 帧/秒'
              % (elapsed / max(1, len(classes)), result['effective_fps']))
        print(' 平均 CNN 周期：%d  (= %.2f ms @93.75MHz)'
              % (sum(f['cnn_cycles'] for f in result['frames']) / len(classes),
                 sum(f['cnn_cycles'] for f in result['frames']) / len(classes) / 93750.0))
    print(' 原始字节：%s' % (args.log_dir / 'uart.rx.bin'))
    print(' 结果 JSON：%s' % (args.log_dir / 'result.json'))
    print('=' * 72)
    if not result['frames']:
        print('⚠ 一帧都没采到。先确认：① E18(相机写过帧) 是否亮 ② 是否有 ERR 行')


if __name__ == '__main__':
    main()
