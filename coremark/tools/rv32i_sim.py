#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rv32i_sim.py --- 最小 RV32I + Zicsr 指令级模拟器（本工程专用）

用途：在没有 ModelSim / Icarus 的机器上，把片内镜像跑起来验证软件是否正确。
它按本工程真实的存储器与 MMIO 边界工作：

    取指 : 0x0000_0000-0x0000_3FFF -> 片内 ROM
    访存 : 0x0000_0000-0x0000_3FFF -> 片内 RAM
           0x1000_0000-0x1000_0FFF -> simple_mmio（SCRATCH/ID/CYCLE/STATUS/TEST_STATUS）
           0x1000_1000-0x1000_100F -> uart_mmio（TX/RX/STATUS/CONTROL）
           0x4000_0000-0x5FFF_FFFF -> DDR（512 MiB，字典模拟）
    其它地址                       -> 访问故障（load cause 5 / store cause 7）
    非对齐访问                     -> cause 4 / 6（与 csr_defs.vh 的定义一致）
    中断                           -> mstatus.MIE && (mip & mie)，优先级 external>software>timer

两个程序都支持：
  * CoreMark  : 判定标准是官方三个已知 CRC（0xe714 / 0x1fd7 / 0x8e3a）
  * boardtest : 程序自己打印 RESULT-LINE，按它判定

用法:
    python rv32i_sim.py build/inst_rom.dat build/data_ram.dat
    python rv32i_sim.py ... --inject-rx 48          # 往 RX FIFO 塞 'H'（测 UART 接收中断）
    python rv32i_sim.py ... --trace-trap 10         # 打印前 10 次异常/中断
    python rv32i_sim.py ... --log build/sim_uart.log --no-output

注意：这是**功能模型**，不是周期精确模型。它用来验证"结果对不对"，
不能用来判断时序、延迟或 CoreMark 分数。
"""
from __future__ import annotations

import argparse
import sys

MASK = 0xFFFFFFFF


def sext(value: int, bits: int) -> int:
    sign = 1 << (bits - 1)
    return (value ^ sign) - sign


class Trap(Exception):
    def __init__(self, cause: int, tval: int = 0):
        super().__init__(f"trap cause={cause}")
        self.cause = cause
        self.tval = tval


class Machine:
    # 存储器 / 外设边界（与 soc_top.v、simple_mmio.v、uart_mmio.v 一致）
    ROM_BASE, ROM_SIZE = 0x00000000, 0x4000
    RAM_BASE, RAM_SIZE = 0x00000000, 0x4000
    MMIO_BASE = 0x10000000
    UART_BASE = 0x10001000
    DDR_BASE = 0x40000000
    DDR_SIZE = 0x20000000

    def __init__(self, rom, ram, max_instr=40_000_000):
        self.rom = rom
        self.ram = ram
        self.ddr: dict[int, int] = {}
        self.reg = [0] * 32
        self.pc = 0

        # CSR
        self.csr: dict[int, int] = {}
        self.mstatus = 0x1800          # MPP=11，MIE=0
        self.mie = 0
        self.mtvec = 0x100
        self.mepc = 0
        self.mcause = 0
        self.mtval = 0

        self.icount = 0
        self.max_instr = max_instr
        self.uart: list[int] = []
        self.trapped = False
        self.reason = ""
        self.self_loop = 0

        # MMIO 状态
        self.scratch = 0
        self.test_status = 0
        self.rx_fifo: list[int] = []
        self.rx_irq_enable = 0
        self.frame_err = 0
        self.overflow = 0
        # 板级把三个外部 IRQ 输入接地；UART IRQ 在 soc_top 里或进 external
        self.irq_pin_sw = 0
        self.irq_pin_timer = 0
        self.irq_pin_ext = 0

        self.loads = 0
        self.stores = 0
        self.trap_log: list[tuple] = []
        self.trace_n = 0

    # ================= 存储器 =================
    def fetch(self, addr: int) -> int:
        if self.ROM_BASE <= addr < self.ROM_BASE + self.ROM_SIZE:
            return self.rom[(addr - self.ROM_BASE) >> 2]
        if self.DDR_BASE <= addr < self.DDR_BASE + self.DDR_SIZE:
            return self.ddr.get(addr & ~3, 0)
        raise Trap(1, addr)                      # instruction access fault

    @staticmethod
    def _wstrb(addr: int, size: int) -> int:
        off = addr & 3
        if size == 1:
            return (1 << off) & 0xF
        if size == 2:
            return (3 << off) & 0xF
        return 0xF

    def _check_align(self, addr: int, size: int, is_store: bool) -> None:
        """CPU 在发请求前就判定非对齐：load 用 cause 4，store 用 cause 6。"""
        if size and (addr % size):
            raise Trap(6 if is_store else 4, addr)

    def _is_mmio(self, addr: int) -> bool:
        return self.MMIO_BASE <= addr < self.MMIO_BASE + 0x1000

    def _is_uart(self, addr: int) -> bool:
        return self.UART_BASE <= addr < self.UART_BASE + 0x10

    # ================= simple_mmio =================
    def _simple_mmio(self, addr, is_store, value, wstrb):
        idx = ((addr - self.MMIO_BASE) & 0xFFF) >> 2
        if idx == 0:                                   # SCRATCH，支持字节写使能
            old = self.scratch
            if is_store:
                for b in range(4):
                    if (wstrb >> b) & 1:
                        m = 0xFF << (8 * b)
                        self.scratch = ((self.scratch & ~m) | (value & m)) & MASK
            return old
        if idx == 1:                                   # ID
            if is_store:
                raise Trap(7, addr)
            return 0x4D4D494F
        if idx == 2:                                   # CYCLE
            if is_store:
                raise Trap(7, addr)
            return self.icount & MASK
        if idx == 3:                                   # STATUS
            if is_store:
                raise Trap(7, addr)
            return 1
        if idx == 4:                                   # TEST_STATUS，单向锁存
            old = self.test_status
            if is_store and (wstrb & 1):
                v = value & 0xFF
                if v == 1:
                    if self.test_status == 0:
                        self.test_status = 1
                elif v in (2, 3):
                    if self.test_status == 1:
                        self.test_status = v
                    elif self.test_status == 0:
                        raise Trap(7, addr)            # PASS/FAIL 必须在 RUN 之后
                else:
                    raise Trap(7, addr)
            return old
        raise Trap(7 if is_store else 5, addr)         # 未实现的偏移 -> 总线错误

    # ================= uart_mmio =================
    def _uart_mmio(self, addr, is_store, value, wstrb):
        off = (addr - self.UART_BASE) & 0xF
        if off == 0x0:                                 # TX_DATA
            if not is_store:
                raise Trap(5, addr)
            if wstrb & 0x1:
                self.uart.append(value & 0xFF)
            return 0
        if off == 0x4:                                 # RX_DATA
            if is_store:
                raise Trap(7, addr)
            if (addr & 3) == 0 and self.rx_fifo:       # 低字节地址读才 pop 一次
                return self.rx_fifo.pop(0)
            return 0
        if off == 0x8:                                 # STATUS
            if is_store:
                raise Trap(7, addr)
            irq = 1 if (self.rx_irq_enable and self.rx_fifo) else 0
            return ((1 << 0) |                                  # TX_READY
                    ((1 if self.rx_fifo else 0) << 2) |         # RX_NOT_EMPTY
                    ((1 if len(self.rx_fifo) >= 16 else 0) << 3) |
                    ((self.frame_err & 1) << 4) |
                    ((self.overflow & 1) << 5) |
                    ((self.rx_irq_enable & 1) << 6) |
                    (irq << 7))
        if off == 0xC:                                 # CONTROL，命令需要在 lane1
            if not is_store:
                return 0
            if wstrb & 0x2:
                if wstrb & 0x1:
                    if value & (1 << 0):
                        self.frame_err = 0
                    if value & (1 << 1):
                        self.overflow = 0
                if value & (1 << 8):
                    self.rx_irq_enable = 1
                if value & (1 << 9):
                    self.rx_irq_enable = 0             # 同时写 1 时禁用优先
            return 0
        raise Trap(7 if is_store else 5, addr)

    def uart_irq(self) -> int:
        return 1 if (self.rx_irq_enable and self.rx_fifo) else 0

    def inject_rx(self, byte: int) -> None:
        """外部把 1 个字节塞进 RX FIFO（模拟 PC 通过串口发数据）。"""
        self.rx_fifo.append(byte & 0xFF)

    # ================= load / store =================
    def load(self, addr: int, size: int, signed: bool) -> int:
        self._check_align(addr, size, False)
        self.loads += 1

        if self.RAM_BASE <= addr < self.RAM_BASE + self.RAM_SIZE:
            base = addr - self.RAM_BASE
            word = self.ram[base >> 2]
            off = base & 3
        elif self.DDR_BASE <= addr < self.DDR_BASE + self.DDR_SIZE:
            base = addr - self.DDR_BASE
            word = self.ddr.get(base & ~3, 0)
            off = base & 3
        elif self._is_mmio(addr):
            return self._simple_mmio(addr, False, 0, 0) & MASK
        elif self._is_uart(addr):
            return self._uart_mmio(addr, False, 0, 0) & MASK
        else:
            raise Trap(5, addr)

        if size == 4:
            val = word
        elif size == 2:
            val = (word >> (off * 8)) & 0xFFFF
        else:
            val = (word >> (off * 8)) & 0xFF
        if signed and size == 1:
            val = sext(val, 8)
        elif signed and size == 2:
            val = sext(val, 16)
        return val & MASK

    def store(self, addr: int, size: int, value: int) -> None:
        self._check_align(addr, size, True)
        self.stores += 1
        wstrb = self._wstrb(addr, size)
        # CPU 就是这么移位的：data_req_wdata = rs2 << (addr[1:0]*8)
        shifted = (value << ((addr & 3) * 8)) & MASK

        if self.RAM_BASE <= addr < self.RAM_BASE + self.RAM_SIZE:
            base = addr - self.RAM_BASE
            idx, off = base >> 2, base & 3
            word = self.ram[idx]
        elif self.DDR_BASE <= addr < self.DDR_BASE + self.DDR_SIZE:
            base = addr - self.DDR_BASE
            idx, off = base & ~3, base & 3
            word = self.ddr.get(idx, 0)
        elif self._is_mmio(addr):
            self._simple_mmio(addr, True, shifted, wstrb)
            return
        elif self._is_uart(addr):
            self._uart_mmio(addr, True, shifted, wstrb)
            return
        else:
            raise Trap(7, addr)

        if size == 4:
            word = value & MASK
        else:
            bits = size * 8
            m = ((1 << bits) - 1) << (off * 8)
            word = (word & ~m) | ((value << (off * 8)) & m)
        if self.RAM_BASE <= addr < self.RAM_BASE + self.RAM_SIZE:
            self.ram[(addr - self.RAM_BASE) >> 2] = word & MASK
        else:
            self.ddr[(addr - self.DDR_BASE) & ~3] = word & MASK

    # ================= CSR =================
    def csr_read(self, csr: int) -> int:
        if csr == 0x300: return self.mstatus
        if csr == 0x304: return self.mie
        if csr == 0x305: return self.mtvec
        if csr == 0x341: return self.mepc
        if csr == 0x342: return self.mcause
        if csr == 0x343: return self.mtval
        if csr == 0x301: return 0x40000104          # misa: RV32I + Zicsr
        if csr in (0xF11, 0xF12, 0xF13, 0xF14, 0xF15): return 0
        return self.csr.get(csr, 0)

    def csr_write(self, csr: int, value: int) -> None:
        value &= MASK
        if csr == 0x300:
            self.mstatus = value & 0x1888           # WARL，与 RTL 掩码一致
        elif csr == 0x304:
            self.mie = value & 0x888
        elif csr == 0x305:
            self.mtvec = value & ~0x3               # Direct 模式
        elif csr == 0x341:
            self.mepc = value & ~0x3
        elif csr == 0x342:
            self.mcause = value
        elif csr == 0x343:
            self.mtval = value
        else:
            self.csr[csr] = value

    # ================= 异常 / 中断 =================
    def take_trap(self, cause: int, tval: int, epc: int) -> None:
        self.mepc = epc & ~0x3
        self.mcause = cause
        self.mtval = tval
        mpie = (self.mstatus >> 3) & 1
        self.mstatus = (self.mstatus & ~0x8) | (mpie << 7)   # MIE -> MPIE
        self.mstatus &= ~0x8                                 # MIE = 0
        self.pc = self.mtvec & ~0x3
        self.trapped = True
        if len(self.trap_log) < self.trace_n:
            self.trap_log.append(("exc", cause, epc, tval, self.icount))

    def take_interrupt(self, cause: int) -> None:
        """中断在指令边界提交：mepc = 还没执行的那条指令（= 当前 pc）。"""
        epc = self.pc & ~0x3
        self.mepc = epc
        self.mcause = 0x80000000 | cause
        self.mtval = 0
        mpie = (self.mstatus >> 3) & 1
        self.mstatus = (self.mstatus & ~0x8) | (mpie << 7)
        self.mstatus &= ~0x8
        self.pc = self.mtvec & ~0x3
        self.trapped = True
        if len(self.trap_log) < self.trace_n:
            self.trap_log.append(("irq", cause, epc, 0, self.icount))

    # ================= 执行 =================
    def step(self) -> bool:
        if self.icount >= self.max_instr:
            self.reason = f"instruction limit {self.max_instr} reached"
            return False

        # 中断资格：mstatus.MIE && |(mip & mie)，优先级 external>software>timer
        mip = 0
        if self.irq_pin_ext or self.uart_irq():
            mip |= 1 << 11
        if self.irq_pin_sw:
            mip |= 1 << 3
        if self.irq_pin_timer:
            mip |= 1 << 7
        if (self.mstatus & 0x8) and (mip & self.mie):
            cause = 11 if (mip & (1 << 11)) else (3 if (mip & (1 << 3)) else 7)
            self.take_interrupt(cause)
            return True

        pc = self.pc
        inst = self.fetch(pc)
        self.icount += 1
        nxt = (pc + 4) & MASK

        op = inst & 0x7F
        rd = (inst >> 7) & 0x1F
        f3 = (inst >> 12) & 0x7
        rs1 = (inst >> 15) & 0x1F
        rs2 = (inst >> 20) & 0x1F
        f7 = (inst >> 25) & 0x7F
        a, b = self.reg[rs1], self.reg[rs2]
        imm_i = sext((inst >> 20) & 0xFFF, 12)
        imm_s = sext(((inst >> 25) << 5) | ((inst >> 7) & 0x1F), 12)
        imm_u = inst & 0xFFFFF000
        imm_b = sext(((inst >> 31) & 1) << 12 | ((inst >> 7) & 1) << 11 |
                     ((inst >> 25) & 0x3F) << 5 | ((inst >> 8) & 0xF) << 1, 13)
        imm_j = sext(((inst >> 31) & 1) << 20 | ((inst >> 12) & 0xFF) << 12 |
                     ((inst >> 20) & 1) << 11 | ((inst >> 21) & 0x3FF) << 1, 21)
        res = None

        try:
            if op == 0x37:                                   # LUI
                res = imm_u
            elif op == 0x17:                                 # AUIPC
                res = (pc + imm_u) & MASK
            elif op == 0x6F:                                 # JAL
                res = nxt
                nxt = (pc + imm_j) & MASK
            elif op == 0x67:                                 # JALR
                res = nxt
                nxt = (a + imm_i) & ~1 & MASK
            elif op == 0x63:                                 # 分支
                take = {0: a == b, 1: a != b, 4: sext(a, 32) < sext(b, 32),
                        5: sext(a, 32) >= sext(b, 32), 6: a < b, 7: a >= b}.get(f3)
                if take is None:
                    raise Trap(2, inst)
                if take:
                    nxt = (pc + imm_b) & MASK
            elif op == 0x03:                                 # 载入
                res = self.load((a + imm_i) & MASK,
                                {0: 1, 1: 2, 2: 4, 4: 1, 5: 2}.get(f3, 0),
                                f3 in (0, 1, 2))
            elif op == 0x23:                                 # 存储
                self.store((a + imm_s) & MASK, {0: 1, 1: 2, 2: 4}.get(f3, 0), b)
            elif op == 0x13:                                 # OP-IMM
                if f3 == 0:
                    res = (a + imm_i) & MASK
                elif f3 == 2:
                    res = 1 if sext(a, 32) < imm_i else 0
                elif f3 == 3:
                    res = 1 if a < (imm_i & MASK) else 0
                elif f3 == 4:
                    res = a ^ (imm_i & MASK)
                elif f3 == 6:
                    res = a | (imm_i & MASK)
                elif f3 == 7:
                    res = a & (imm_i & MASK)
                elif f3 == 1:
                    res = (a << ((inst >> 20) & 0x1F)) & MASK
                elif f3 == 5:
                    sh = (inst >> 20) & 0x1F
                    # 区分 SRLI / SRAI 的是 imm[10]，即 bit 30（不是 bit 25！）
                    res = (sext(a, 32) >> sh) & MASK if (inst >> 30) & 1 else (a >> sh)
                else:
                    raise Trap(2, inst)
            elif op == 0x33:                                 # OP
                if f7 == 0x01:
                    raise Trap(2, inst)                      # 本 CPU 没有 M 扩展
                if f3 == 0:
                    res = (a - b) & MASK if f7 else (a + b) & MASK
                elif f3 == 1:
                    res = (a << (b & 0x1F)) & MASK
                elif f3 == 2:
                    res = 1 if sext(a, 32) < sext(b, 32) else 0
                elif f3 == 3:
                    res = 1 if a < b else 0
                elif f3 == 4:
                    res = a ^ b
                elif f3 == 5:
                    sh = b & 0x1F
                    res = (sext(a, 32) >> sh) & MASK if f7 else (a >> sh)
                elif f3 == 6:
                    res = a | b
                elif f3 == 7:
                    res = a & b
                else:
                    raise Trap(2, inst)
            elif op == 0x0F:                                 # FENCE / FENCE.I：当 nop
                pass
            elif op == 0x73:                                 # SYSTEM
                if f3 == 0:
                    if imm_i == 0x000:
                        raise Trap(11, 0)                    # ECALL
                    if imm_i == 0x001:
                        raise Trap(3, 0)                     # EBREAK
                    if imm_i == 0x302:                       # MRET
                        nxt = self.mepc
                        mpie = (self.mstatus >> 7) & 1
                        self.mstatus = (self.mstatus & ~0x8) | (mpie << 3)
                        self.mstatus |= 0x80
                else:
                    csr = (inst >> 20) & 0xFFF
                    # CSRRW/CSRRS/CSRRC(f3=1/2/3) 的源是寄存器**内容**；
                    # CSRRWI/CSRRSI/CSRRCI(f3=5/6/7) 的源是 rs1 字段里的 5 位立即数。
                    src = self.reg[rs1] if f3 in (1, 2, 3) else rs1
                    old = self.csr_read(csr)
                    if f3 in (1, 5):
                        self.csr_write(csr, src)
                    elif f3 in (2, 6):
                        if rs1 != 0:
                            self.csr_write(csr, old | src)
                    elif f3 in (3, 7):
                        if rs1 != 0:
                            self.csr_write(csr, old & ~src)
                    else:
                        raise Trap(2, inst)
                    res = old
            else:
                raise Trap(2, inst)
        except Trap as t:
            self.take_trap(t.cause, t.tval, pc)
            return True

        if res is not None and rd != 0:
            self.reg[rd] = res & MASK
        self.reg[0] = 0                                # x0 恒为 0

        if nxt == pc:                                  # 原地跳转 = 程序停住了
            self.self_loop += 1
            if self.self_loop > 3:
                self.reason = f"self-loop at pc=0x{pc:08x}"
                return False
        else:
            self.self_loop = 0
        self.pc = nxt
        return True

    def run(self) -> None:
        while self.step():
            pass
        if not self.reason:
            self.reason = "halted"

    def output(self) -> str:
        """串口字节流按 UTF-8 解码：程序里打印的中文就是 UTF-8。
        （若按 latin-1 解码，写日志时会变成双重编码的乱码。）"""
        return bytes(self.uart).decode("utf-8", errors="replace")


# ================= CLI =================
def read_dat(path: str) -> list[int]:
    with open(path, "r", encoding="utf-8") as f:
        words = [int(tok, 16) for tok in f.read().split()]
    if len(words) != 4096:
        raise ValueError(f"{path}: expected 4096 words, got {len(words)}")
    return words


def boardtest_verdict(text: str) -> int:
    """boardtest 程序自己打印 RESULT-LINE，直接按它判定。"""
    import re as _re
    m = _re.search(r"RESULT-LINE:\s*boardtest\s+pass=(\d+)\s+fail=(\d+)\s+skip=(\d+)", text)
    if not m:
        print("  [BAD] 没有找到 RESULT-LINE（程序可能没跑完）")
        print("\nRESULT: FAIL")
        return 1
    p, f, s = (int(x) for x in m.groups())
    print(f"  pass={p}  fail={f}  skip={s}")
    for line in text.splitlines():
        if " -> FAIL" in line:
            print(f"  [FAIL] {line.strip()}")
    for line in text.splitlines():
        if " -> SKIP" in line:
            print(f"  [SKIP] {line.strip()}")
    ok = (f == 0)
    print(f"\nRESULT: {'PASS' if ok else 'FAIL'} (boardtest)")
    return 0 if ok else 1


def coremark_verdict(text: str) -> int:
    expected = {"crclist": 0xE714, "crcmatrix": 0x1FD7, "crcstate": 0x8E3A}
    crc_ok = True
    for name, want in expected.items():
        line = [l for l in text.splitlines() if name in l]
        got = None
        if line:
            try:
                got = int(line[-1].split(":")[-1].strip(), 16)
            except ValueError:
                got = None
        status = "OK " if got == want else "BAD"
        if got != want:
            crc_ok = False
        print(f"  [{status}] {name:<10} got={got if got is None else hex(got)} want={hex(want)}")

    seed_ok = "seedcrc          : 0xe9f5" in text
    print(f"  [{'OK ' if seed_ok else 'BAD'}] seedcrc    0xe9f5 (2K performance run 标识)")

    ten_ok = "at least 10 secs" not in text
    if not ten_ok:
        print("  [--] 运行时间 < 10 秒：CoreMark 按规则报错，属预期。")
        print("       功能验证用 -Iterations 1 即可；记录成绩必须用 >= 10 秒的迭代次数。")

    if "Correct operation validated" in text:
        print("  [OK ] Correct operation validated")
    else:
        print("  [--] 未出现 'Correct operation validated'（因为 <10 秒被判无效）")

    if crc_ok and seed_ok:
        verdict = ("PASS (功能已验证；还需用 >=10 秒的迭代次数跑正式成绩)"
                   if not ten_ok else "PASS")
        ok = True
    else:
        verdict = "FAIL"
        ok = False
    print(f"\nRESULT: {verdict}")
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("rom")
    ap.add_argument("ram")
    ap.add_argument("--max-instr", type=int, default=40_000_000)
    ap.add_argument("--no-output", action="store_true")
    ap.add_argument("--log", default=None, help="把串口输出原样写入该文件（UTF-8）")
    ap.add_argument("--inject-rx", default=None,
                    help="启动前往 UART RX FIFO 塞一个字节（十六进制，如 48 代表 'H'）")
    ap.add_argument("--trace-trap", type=int, default=0,
                    help="记录并打印前 N 次异常/中断（排查异常机制很好用）")
    args = ap.parse_args()

    try:                                     # Windows 控制台默认 GBK，直接 print 会炸
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

    m = Machine(read_dat(args.rom), read_dat(args.ram), args.max_instr)
    m.trace_n = args.trace_trap
    if args.inject_rx:
        m.inject_rx(int(args.inject_rx, 16))
    m.run()

    text = m.output()
    if args.log:
        with open(args.log, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        print(f"serial log written    : {args.log}")

    print(f"instructions executed : {m.icount:,}")
    print(f"stop reason           : {m.reason}")
    print(f"final pc              : 0x{m.pc:08x}")
    print(f"trapped               : {m.trapped}  mcause=0x{m.mcause:08x} "
          f"mepc=0x{m.mepc:08x} mtval=0x{m.mtval:08x}")
    print(f"UART bytes captured   : {len(m.uart)}")

    if m.trap_log:
        print("trap trace (kind, cause, epc/mepc, mtval, instr#):")
        for kind, cause, epc, tval, n in m.trap_log:
            print(f"   {kind:<4} cause={cause:<3} epc=0x{epc:08x} "
                  f"mtval=0x{tval:08x}  @instr {n}")

    print("-" * 68)
    print(text if not args.no_output else "(suppressed)")
    print("-" * 68)

    if "RESULT-LINE: boardtest" in text:
        return boardtest_verdict(text)
    return coremark_verdict(text)


if __name__ == "__main__":
    raise SystemExit(main())
