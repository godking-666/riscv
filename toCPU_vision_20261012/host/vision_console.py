#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
vision_console.py -- RK3568 侧「物品识别显示终端」

职责：把 FPGA 上来的一行结果文本渲染成屏幕上给评委看的东西：
      类别 / 外接框 / 延迟 / 计数 / 帧率。

输入的这行文本格式（与 sw/main.c、rtl/vision_report.v 完全一致）：
    VISION,<帧号>,<类别>,<x0>,<y0>,<x1>,<y1>,<置信度>,<延迟us>,<计数>\n

四种数据来源（演示时按现场条件选）：
    --port COM3 --baud 115200   真机：读 FPGA 的 UART
    --stdin                     从管道/别的程序读
    --file log.txt              回放一份日志（可 --rate 倍速）
    --demo                      不需要任何硬件，自己造数据（彩排/答辩兜底）

用法：
    python vision_console.py --list                 # 列出串口
    python vision_console.py --demo                 # 无硬件彩排
    python vision_console.py --port COM3            # 真机
    python vision_console.py --port COM3 --csv run.csv   # 顺便存一份数据
    python vision_console.py --file log.txt --rate 4     # 4 倍速回放

只用标准库；--port 需要 pyserial（pip install pyserial）。
"""

import argparse
import os
import random
import sys
import time
from collections import deque

# --------------------------------------------------------------------------
# 协议
# --------------------------------------------------------------------------
MAGIC = "VISION"
CLASS_LETTERS = {"A", "B", "C"}


class Result(object):
    __slots__ = ("frame", "cls", "x0", "y0", "x1", "y1",
                 "score", "lat_us", "count", "t")

    def __init__(self, frame, cls, x0, y0, x1, y1, score, lat_us, count):
        self.frame = frame
        self.cls = cls
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1
        self.score = score
        self.lat_us = lat_us
        self.count = count
        self.t = time.time()

    @property
    def has_object(self):
        return self.cls in CLASS_LETTERS

    @property
    def w(self):
        return self.x1 - self.x0 + 1 if self.x1 >= self.x0 else 0

    @property
    def h(self):
        return self.y1 - self.y0 + 1 if self.y1 >= self.y0 else 0


def parse_line(line):
    """解析一行。不是结果行 / 解析失败返回 None。"""
    line = line.strip()
    if not line.startswith(MAGIC + ","):
        return None
    p = line.split(",")
    if len(p) < 10:
        return None
    try:
        return Result(int(p[1]), p[2], int(p[3]), int(p[4]), int(p[5]),
                      int(p[6]), int(p[7]), int(p[8]), int(p[9]))
    except ValueError:
        return None


# --------------------------------------------------------------------------
# 终端
# --------------------------------------------------------------------------
BOX = "─│┌┐└┘├┤┬┴┼"
ASCII_BOX = "-|++++++++"


def setup_console(force_ascii=False):
    """Windows 下打开 UTF-8 + ANSI；失败就退回 ASCII 画框。"""
    ascii_only = force_ascii
    if os.name == "nt":
        try:
            import ctypes
            k = ctypes.windll.kernel32
            k.SetConsoleOutputCP(65001)
            h = k.GetStdHandle(-11)
            mode = ctypes.c_uint32()
            if k.GetConsoleMode(h, ctypes.byref(mode)):
                k.SetConsoleMode(h, mode.value | 0x0004)   # ENABLE_VT_PROCESSING
        except Exception:
            pass
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    enc = (getattr(sys.stdout, "encoding", None) or "ascii").lower()
    if "utf" not in enc:
        ascii_only = True
    return ascii_only


# --------------------------------------------------------------------------
# 数据源
# --------------------------------------------------------------------------
def src_demo():
    """合成一帧结果：没有板卡时用来彩排/演示。"""
    scenes = [("A", 100, 60, 60, 60), ("B", 60, 50, 20, 80),
              ("C", 150, 150, 20, 20), ("--", 0, 0, 0, 0)]
    frame = 0
    count = 0
    prev_has = False
    while True:
        name, x, y, w, h = scenes[random.randrange(len(scenes))]
        if name == "--":
            x = y = 0
            w = h = 0
        else:
            x += random.randint(-3, 3)
            y += random.randint(-3, 3)
        has = name in CLASS_LETTERS
        if has and not prev_has:
            count += 1
        prev_has = has
        frame += 1
        area = w * h
        score = min(1000, area * 1000 // (320 * 240))
        yield Result(frame, name, x, y, x + w - 1 if w else 0,
                     y + h - 1 if h else 0, score, 6983, count)
        time.sleep(0.035)


def src_file(path, rate):
    def gen():
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                r = parse_line(line)
                if r is not None:
                    yield r
                    if rate > 0:
                        time.sleep(0.033 / rate)
    return gen()


def src_stdin():
    def gen():
        for line in sys.stdin:
            r = parse_line(line)
            if r is not None:
                yield r
    return gen()


def src_serial(port, baud):
    try:
        import serial
    except ImportError:
        sys.stderr.write("需要 pyserial：pip install pyserial\n")
        raise SystemExit(2)

    def gen():
        ser = serial.Serial(port, baud, timeout=1)
        buf = ""
        while True:
            data = ser.read(256)
            if not data:
                continue
            buf += data.decode("ascii", errors="replace")
            while "\n" in buf:
                line, buf = buf.split("\n", 1)
                r = parse_line(line)
                if r is not None:
                    yield r
                elif line.strip():
                    sys.stderr.write("  [dev] %s\n" % line.strip())
    return gen()


def list_ports():
    try:
        from serial.tools import list_ports as lp
    except ImportError:
        print("需要 pyserial：pip install pyserial")
        return
    for p in lp.comports():
        print("  %-12s %s" % (p.device, p.description))


# --------------------------------------------------------------------------
# 渲染
# --------------------------------------------------------------------------
CW, CH = 44, 12          # 画布字符尺寸
FW, FH = 320, 240        # 摄像头画面尺寸（与 ROI 对应）


def draw_canvas(r, box):
    """把外接框画到字符画布上。"""
    if box[6]:
        L, V, TL, TR, BL, BR = "-", "|", "+", "+", "+", "+"
    else:
        L, V, TL, TR, BL, BR = box[0], box[1], box[2], box[3], box[4], box[5]

    grid = [[" "] * CW for _ in range(CH)]
    # 画布外框
    for x in range(CW):
        grid[0][x] = L
        grid[CH - 1][x] = L
    for y in range(CH):
        grid[y][0] = V
        grid[y][CW - 1] = V
    grid[0][0], grid[0][CW - 1] = TL, TR
    grid[CH - 1][0], grid[CH - 1][CW - 1] = BL, BR
    # 中间十字参考线（检测区中心）
    cy, cx = CH // 2, CW // 2
    if grid[cy][cx] == " ":
        grid[cy][cx] = "+"

    if r.has_object and r.w > 0 and r.h > 0:
        px0 = int(r.x0 * (CW - 2) / FW) + 1
        px1 = int(r.x1 * (CW - 2) / FW) + 1
        py0 = int(r.y0 * (CH - 2) / FH) + 1
        py1 = int(r.y1 * (CH - 2) / FH) + 1
        px0, px1 = max(1, min(CW - 2, px0)), max(1, min(CW - 2, px1))
        py0, py1 = max(1, min(CH - 2, py0)), max(1, min(CH - 2, py1))
        for y in range(py0, py1 + 1):
            for x in range(px0, px1 + 1):
                grid[y][x] = box[7]
        # 块里写类别字母
        ty, tx = (py0 + py1) // 2, (px0 + px1) // 2
        grid[ty][tx] = r.cls
    return ["".join(row) for row in grid]


class Screen(object):
    def __init__(self, ascii_only=False):
        self.ascii_only = ascii_only
        self.hist = deque(maxlen=24)
        self.last = None
        self.count_seen = 0
        self.dropped = 0
        self.t0 = time.time()
        self.times = deque(maxlen=240)
        self.frames = deque(maxlen=240)
        self.log = deque(maxlen=3)

    def feed(self, r):
        if self.last is not None and r.frame > self.last.frame + 1:
            self.dropped += r.frame - self.last.frame - 1
        self.last = r
        self.count_seen = max(self.count_seen, r.count)
        self.hist.append(r.cls)
        self.times.append(r.t)
        self.frames.append(r.frame)

    def fps(self):
        if len(self.times) < 2:
            return 0.0
        dt = self.times[-1] - self.times[0]
        df = self.frames[-1] - self.frames[0]
        if dt <= 0 or df <= 0:
            return 0.0
        return df / dt

    def render(self):
        a = self.ascii_only
        # 边框字符集
        if a:
            H, Vv, TL, TR, BL, BR = "-", "|", "+", "+", "+", "+"
            box = (H, Vv, TL, TR, BL, BR, True, "#")
        else:
            H, Vv, TL, TR, BL, BR = "─", "│", "┌", "┐", "└", "┘"
            box = (H, Vv, TL, TR, BL, BR, False, "█")

        r = self.last
        out = []
        W = 62

        def line(s=""):
            out.append(s)

        def frame_line(s):
            s = s[:W - 4]
            out.append(" %s %s %s" % (Vv, s.ljust(W - 4), Vv))

        line(TL + H * (W - 2) + TR)
        frame_line("物品识别显示终端  ·  RK3568")
        line("├" + H * (W - 2) + "┤")

        if r is None:
            frame_line("等待 FPGA 上报结果 ...")
            for _ in range(CH):
                frame_line("")
            for _ in range(6):
                frame_line("")
        else:
            for row in draw_canvas(r, box):
                frame_line(row)
            frame_line("")
            frame_line("  类别: %-3s      置信度: %4d‰        帧号: %d"
                       % (r.cls, r.score, r.frame))
            frame_line("  外接框: (%d,%d)-(%d,%d)   尺寸: %dx%d"
                       % (r.x0, r.y0, r.x1, r.y1, r.w, r.h))
            frame_line("  延迟: %d us (%.2f ms)        计数: %d"
                       % (r.lat_us, r.lat_us / 1000.0, r.count))
            frame_line("  帧率: %.1f fps    丢帧: %d    运行: %s"
                       % (self.fps(), self.dropped, self._uptime()))
            frame_line("  最近: %s" % " ".join(self.hist))

        line(BL + H * (W - 2) + BR)
        return "\n".join(out)

    def _uptime(self):
        s = int(time.time() - self.t0)
        return "%02d:%02d:%02d" % (s // 3600, (s // 60) % 60, s % 60)


# --------------------------------------------------------------------------
# 主程序
# --------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="物品识别显示终端")
    ap.add_argument("--port", help="串口，如 COM3")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--file", help="回放日志文件")
    ap.add_argument("--stdin", action="store_true", help="从标准输入读")
    ap.add_argument("--demo", action="store_true", help="自己造数据（无硬件彩排）")
    ap.add_argument("--rate", type=float, default=1.0, help="回放倍速")
    ap.add_argument("--csv", help="把解析结果另存为 CSV")
    ap.add_argument("--plain", action="store_true", help="不做全屏刷新，逐行打印")
    ap.add_argument("--ascii", action="store_true", help="只用 ASCII 画框")
    ap.add_argument("--list", action="store_true", help="列出串口后退出")
    args = ap.parse_args()

    if args.list:
        list_ports()
        return 0

    ascii_only = setup_console(args.ascii)

    if args.port:
        gen = src_serial(args.port, args.baud)
    elif args.file:
        gen = src_file(args.file, args.rate)
    elif args.demo:
        gen = src_demo()
    elif args.stdin or not sys.stdin.isatty():
        gen = src_stdin()
    else:
        ap.print_help()
        print("\n提示：先用 --demo 看看效果：  python vision_console.py --demo")
        return 1

    csv_f = None
    if args.csv:
        csv_f = open(args.csv, "w", encoding="utf-8")
        csv_f.write("frame,class,x0,y0,x1,y1,score,lat_us,count\n")

    scr = Screen(ascii_only=ascii_only)
    tty = sys.stdout.isatty() and not args.plain

    try:
        if tty:
            sys.stdout.write("\033[2J")
        for r in gen:
            scr.feed(r)
            if csv_f:
                csv_f.write("%d,%s,%d,%d,%d,%d,%d,%d,%d\n"
                            % (r.frame, r.cls, r.x0, r.y0, r.x1, r.y1,
                               r.score, r.lat_us, r.count))
                csv_f.flush()
            if tty:
                sys.stdout.write("\033[H" + scr.render() + "\n")
                sys.stdout.flush()
            else:
                print("frame=%-6d cls=%-2s box=(%d,%d)-(%d,%d) size=%dx%d "
                      "score=%d lat=%dus count=%d"
                      % (r.frame, r.cls, r.x0, r.y0, r.x1, r.y1,
                         r.w, r.h, r.score, r.lat_us, r.count))
    except KeyboardInterrupt:
        pass
    finally:
        if csv_f:
            csv_f.close()
        print("\n[vision_console] 退出")
    return 0


if __name__ == "__main__":
    sys.exit(main())