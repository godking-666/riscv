"""RV32I(+Zmmul) 指令级模拟器 —— 只用来统计动态指令数。

目的：CoreMark 的跑分差异到底是"每拍效率"还是"每迭代要执行多少条指令"。
把 ITERATIONS=1 的固件跑一遍，直接数出指令条数（含各类指令占比）。

支持：RV32I 全部整数指令 + Zmmul（mul/mulh/mulhsu/mulhu）+ 基本 CSR
（mstatus/mtvec/mepc/mcause/mtval/mscratch）+ 我们 SoC 的 MMIO 语义：
  0x1000_1000  UART TX（写）      0x1000_1004  UART RX（读，恒空）
  0x1000_1008  UART STATUS（读）  bit0=tx_ready 恒 1
  0x1000_0008  simple_mmio CYCLE（每执行 1 条指令 +1）

用法：
  python tools/rv32_count.py --bin <program.bin> [--entry 0x40000000]
                             [--max-inst 30000000] [--stop-sym 0x40000040]
"""
import argparse
import struct
import sys

# ---------- 内存 ----------
MEM_BASE = 0x4000_0000
MEM_SIZE = 0x1_0000          # 64 KiB（链接脚本 DDR 区域）
cyc = [0]
uart_out = []


def load(bin_path):
    mem = bytearray(MEM_SIZE)
    data = open(bin_path, 'rb').read()
    if len(data) > MEM_SIZE:
        raise SystemExit('BIN 太大：%d > %d' % (len(data), MEM_SIZE))
    mem[:len(data)] = data
    return mem


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--bin', required=True)
    ap.add_argument('--entry', default='0x40000000')
    ap.add_argument('--max-inst', type=int, default=30_000_000)
    ap.add_argument('--stop-pc', default='', help='跑到该 PC 就停（例如 program_return）')
    ap.add_argument('--quiet', action='store_true')
    args = ap.parse_args()

    entry = int(args.entry, 16)
    stop_pc = int(args.stop_pc, 16) if args.stop_pc else None
    mem = load(args.bin)

    x = [0] * 32
    csr = {'mstatus': 0, 'mtvec': 0, 'mepc': 0, 'mcause': 0, 'mtval': 0, 'mscratch': 0}
    pc = entry
    n = 0
    counts = {'load': 0, 'store': 0, 'branch': 0, 'jal': 0, 'mul': 0, 'csr': 0, 'alu': 0}

    def load_word(a):
        if a & 3:
            raise RuntimeError('misaligned lw 0x%08x' % a)
        if 0x1000_0000 <= a < 0x1001_0000:
            off = a - 0x1000_0000
            if off == 0x008:
                return cyc[0] & 0xFFFF_FFFF
            if off == 0x1008:
                return 1                      # tx_ready 恒 1
            if off == 0x1004:
                return 0
            return 0
        r = a - MEM_BASE
        if r < 0 or r + 4 > MEM_SIZE:
            raise RuntimeError('load 越界 0x%08x' % a)
        return struct.unpack_from('<I', mem, r)[0]

    def load_sized(a, size):
        if 0x1000_0000 <= a < 0x1001_0000:
            return load_word(a & ~3) >> (8 * (a & 3)) & 0xFF
        r = a - MEM_BASE
        if r < 0 or r >= MEM_SIZE:
            raise RuntimeError('load 越界 0x%08x' % a)
        return mem[r]

    def store_sized(a, val, size):
        if 0x1000_0000 <= a < 0x1001_0000:
            off = a - 0x1000_0000
            if off == 0x1000:
                uart_out.append(val & 0xFF)
            return
        r = a - MEM_BASE
        if r < 0 or r >= MEM_SIZE:
            raise RuntimeError('store 越界 0x%08x' % a)
        if size == 1:
            mem[r] = val & 0xFF
        elif size == 2:
            struct.pack_into('<H', mem, r & ~1, val & 0xFFFF)
        else:
            struct.pack_into('<I', mem, r & ~3, val & 0xFFFF_FFFF)

    def se(v, bits):
        m = 1 << (bits - 1)
        return (v & (m - 1)) - (v & m)

    try:
        while n < args.max_inst:
            if stop_pc is not None and pc == stop_pc:
                break
            ins = struct.unpack_from('<I', mem, pc - MEM_BASE)[0]
            n += 1
            cyc[0] += 1
            opcode = ins & 0x7F
            rd = (ins >> 7) & 0x1F
            f3 = (ins >> 12) & 0x7
            rs1 = (ins >> 15) & 0x1F
            rs2 = (ins >> 20) & 0x1F
            f7 = (ins >> 25) & 0x7F
            npc = pc + 4

            if opcode == 0x37:                                    # LUI
                x[rd] = ins & 0xFFFF_F000
                counts['alu'] += 1
            elif opcode == 0x17:                                  # AUIPC
                hi = ins & 0xFFFF_F000
                if hi & 0x8000_0000:
                    hi -= 1 << 32
                x[rd] = (pc + hi) & 0xFFFF_FFFF
                counts['alu'] += 1
            elif opcode == 0x6F:                                  # JAL
                jimm = ((ins >> 31) << 20 | ((ins >> 12) & 0xFF) << 12 |
                        ((ins >> 20) & 1) << 11 | ((ins >> 21) & 0x3FF) << 1)
                if jimm & (1 << 20):
                    jimm -= 1 << 21
                npc = (pc + jimm) & 0xFFFF_FFFF
                x[rd] = (pc + 4) & 0xFFFF_FFFF
                counts['jal'] += 1
            elif opcode == 0x67:                                  # JALR
                t = (x[rs1] + se(ins >> 20, 12)) & 0xFFFF_FFFE
                x[rd] = (pc + 4) & 0xFFFF_FFFF
                npc = t
                counts['jal'] += 1
            elif opcode == 0x63:                                  # BRANCH
                imm = (((ins >> 31) & 1) << 12 | ((ins >> 7) & 1) << 11 |
                       ((ins >> 25) & 0x3F) << 5 | ((ins >> 8) & 0xF) << 1)
                imm = se(imm, 13)
                a1, a2 = x[rs1], x[rs2]
                take = {0: a1 == a2, 1: a1 != a2,
                        4: se(a1, 32) < se(a2, 32), 5: se(a1, 32) >= se(a2, 32),
                        6: a1 < a2, 7: a1 >= a2}.get(f3, False)
                if take:
                    npc = (pc + imm) & 0xFFFF_FFFF
                counts['branch'] += 1
            elif opcode == 0x03:                                  # LOAD
                imm = se(ins >> 20, 12)
                a = (x[rs1] + imm) & 0xFFFF_FFFF
                if f3 == 0:
                    x[rd] = se(load_sized(a, 1), 8) & 0xFFFF_FFFF
                elif f3 == 1:
                    x[rd] = se(load_sized(a, 2) | (load_sized(a + 1, 1) << 8), 16) & 0xFFFF_FFFF
                elif f3 == 2:
                    x[rd] = load_word(a)
                elif f3 == 4:
                    x[rd] = load_sized(a, 1)
                elif f3 == 5:
                    x[rd] = load_sized(a, 2) | (load_sized(a + 1, 1) << 8)
                else:
                    raise RuntimeError('bad load f3=%d' % f3)
                counts['load'] += 1
            elif opcode == 0x23:                                  # STORE
                imm = se(((ins >> 25) << 5) | ((ins >> 7) & 0x1F), 12)
                a = (x[rs1] + imm) & 0xFFFF_FFFF
                if f3 == 0:
                    store_sized(a, x[rs2] & 0xFF, 1)
                elif f3 == 1:
                    v = x[rs2] & 0xFFFF
                    store_sized(a, v & 0xFF, 1)
                    store_sized(a + 1, (v >> 8) & 0xFF, 1)
                elif f3 == 2:
                    for i in range(4):
                        store_sized(a + i, (x[rs2] >> (8 * i)) & 0xFF, 1)
                else:
                    raise RuntimeError('bad store f3=%d' % f3)
                counts['store'] += 1
            elif opcode == 0x13:                                  # OP-IMM
                imm = se(ins >> 20, 12)
                if f3 == 0:
                    x[rd] = (x[rs1] + imm) & 0xFFFF_FFFF
                elif f3 == 2:
                    x[rd] = int(se(x[rs1], 32) < imm)
                elif f3 == 3:
                    x[rd] = int(x[rs1] < (imm & 0xFFFF_FFFF))
                elif f3 == 4:
                    x[rd] = x[rs1] ^ (imm & 0xFFFF_FFFF)
                elif f3 == 6:
                    x[rd] = x[rs1] | (imm & 0xFFFF_FFFF)
                elif f3 == 7:
                    x[rd] = x[rs1] & (imm & 0xFFFF_FFFF)
                elif f3 == 1:
                    x[rd] = (x[rs1] << ((ins >> 20) & 0x1F)) & 0xFFFF_FFFF
                elif f3 == 5:
                    sh = (ins >> 20) & 0x1F
                    if f7 & 0x20:
                        x[rd] = (se(x[rs1], 32) >> sh) & 0xFFFF_FFFF
                    else:
                        x[rd] = x[rs1] >> sh
                counts['alu'] += 1
            elif opcode == 0x33:                                  # OP
                a1, a2 = x[rs1], x[rs2]
                if f7 == 0x01:
                    m = f3
                    if m == 0:
                        x[rd] = (a1 * a2) & 0xFFFF_FFFF
                    elif m == 1:
                        x[rd] = ((se(a1, 32) * se(a2, 32)) >> 32) & 0xFFFF_FFFF
                    elif m == 2:
                        x[rd] = ((se(a1, 32) * a2) >> 32) & 0xFFFF_FFFF
                    elif m == 3:
                        x[rd] = ((a1 * a2) >> 32) & 0xFFFF_FFFF
                    else:
                        raise RuntimeError('bad M f3=%d' % m)
                    counts['mul'] += 1
                else:
                    if f3 == 0:
                        x[rd] = (a1 - a2) & 0xFFFF_FFFF if f7 & 0x20 else (a1 + a2) & 0xFFFF_FFFF
                    elif f3 == 1:
                        x[rd] = (a1 << (a2 & 0x1F)) & 0xFFFF_FFFF
                    elif f3 == 2:
                        x[rd] = int(se(a1, 32) < se(a2, 32))
                    elif f3 == 3:
                        x[rd] = int(a1 < a2)
                    elif f3 == 4:
                        x[rd] = a1 ^ a2
                    elif f3 == 5:
                        sh = a2 & 0x1F
                        x[rd] = (se(a1, 32) >> sh) & 0xFFFF_FFFF if f7 & 0x20 else (a1 >> sh)
                    elif f3 == 6:
                        x[rd] = a1 | a2
                    elif f3 == 7:
                        x[rd] = a1 & a2
                    counts['alu'] += 1
            elif opcode == 0x0F:                                  # FENCE / FENCE.I
                counts['alu'] += 1
            elif opcode == 0x73:                                  # SYSTEM
                counts['csr'] += 1
                if f3 == 0:
                    imm12 = ins >> 20
                    if imm12 == 0:                       # ECALL -> 陷阱
                        csr['mepc'] = pc
                        csr['mcause'] = 11
                        npc = csr['mtvec'] & 0xFFFF_FFFC
                    elif imm12 == 0x302:                 # MRET
                        npc = csr['mepc'] & 0xFFFF_FFFC
                    elif imm12 == 1:
                        raise RuntimeError('EBREAK at 0x%08x' % pc)
                    else:
                        raise RuntimeError('bad system %x' % imm12)
                else:
                    name = {0x300: 'mstatus', 0x305: 'mtvec', 0x341: 'mepc',
                            0x342: 'mcause', 0x343: 'mtval', 0x340: 'mscratch'}.get(ins >> 20)
                    if name:
                        if f3 in (1, 2, 3):
                            v = x[rs1]
                        else:
                            v = rs1
                        if f3 in (1, 5):
                            csr[name] = v
                        elif f3 in (2, 6):
                            csr[name] |= v
                        elif f3 in (3, 7):
                            csr[name] &= ~v
                        x[rd] = csr[name] & 0xFFFF_FFFF
            else:
                raise RuntimeError('未实现 opcode=0x%02x @0x%08x (ins=0x%08x)'
                                   % (opcode, pc, ins))

            x[0] = 0
            pc = npc
    except RuntimeError as e:
        print('STOP: %s' % e)
        print('  已执行 %d 条指令，PC=0x%08x' % (n, pc))

    print('=' * 60)
    print(' 文件      : %s' % args.bin)
    print(' 指令总数  : %d' % n)
    print(' 明细      : ' + '  '.join('%s=%d' % (k, v) for k, v in counts.items()))
    tot = max(n, 1)
    print(' 占比      : load %.1f%%  store %.1f%%  branch %.1f%%  jal %.1f%%  mul %.1f%%'
          % (100.0 * counts['load'] / tot, 100.0 * counts['store'] / tot,
             100.0 * counts['branch'] / tot, 100.0 * counts['jal'] / tot,
             100.0 * counts['mul'] / tot))
    if not args.quiet and uart_out:
        txt = ''.join(chr(c) for c in uart_out[-200:])
        print(' UART 尾部 : %r' % txt[-120:])


if __name__ == '__main__':
    main()
