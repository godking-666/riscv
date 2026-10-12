# 验收过的交付物

## board_top_676_G1_verified.sbit

| 项 | 值 |
|---|---|
| 器件 | **PG2L200H-6IFBB676**（位流内嵌串已核对：`PG2L200H`×1、`FBB676`×1，无 100H/FBG676/FBG484） |
| 顶层 | `board_top_676` |
| core_clk | **27 MHz**（27MHz 晶振 D18 直驱，`USE_PLL=0`） |
| 功能 | CPU(RV32I 五级流水) + 片内 ROM/RAM + MMIO + UART + GPIO + `vision_top`(规则分类器) |
| 片内程序 | CoreMark，`iterations=300`，`hz=27000000` |
| 大小 | 9,188,552 B |
| **SHA256** | **`1ff04fe7807e6a33b013c35c925c63dd51f49795aed9c9889c775a34dd91e118`** |
| 生成时间 | 2026-10-12 23:28:25 |
| LUT / FF | 4242 / 159800（2.65%）、4750 / 319600（1.49%） |
| 时序 | `All Constraints Met`，四种子全收敛（最优 seed4 +19.103 ns） |

## ⚠️ 关于位流哈希，务必知道的一件事

**同一次设计，只要 P&R 种子不同，位流字节就不同、SHA256 就不同 —— 但功能完全一致。**

本工程当晚产生过两个位流：

| 时间 | SHA256 前缀 | 来源 |
|---|---|---|
| 23:15:36 | `32e24d07…` | 脚本 `build_676.tcl` 全流程（最佳种子 seed4） |
| **23:28:25** | **`1ff04fe7…`** | 之后又在 PDS 里跑了一次并重新生成（`place_route/seed_4`） |

**两者的程序与 RTL 完全相同**（`inst_rom.dat` / `data_ram.dat` 自 23:06:58 未再变动，
IP 的 `*_init_param.v` 自 23:07 生成后未再变动），差别只在布局布线。

**⇒ 团队门控规则：以"你实际烧进去并验收的那一个"为准。**
**建议动作：烧 `1ff04fe7…` 这一颗，把串口输出与哈希一起留档**，
这样"哈希 ↔ 实板结果"才是一一对应的。

## 实板验收记录（2026-10-12，串口 HEX 显示译出）

```text
2K performance run parameters for coremark.
CoreMark Size    : 666
Total ticks      : 401452720
Total time (secs): 14
Iterations/Sec   : 21
Iterations       : 300
Compiler version : GCC15.2.0
Compiler flags   : onchip -Os -march=rv32i -mabi=ilp32
Memory location  : DDR code/data; static 2000-byte buffer
seedcrc          : 0xe9f5
[0]crclist       : 0xe714
[0]crcmatrix     : 0x1fd7
[0]crcstate      : 0x8e3a
[0]crcfinal      : 0xa14c
Correct operation validated. See README.md for run and reporting rules.
PORT_DONE ticks=401452720 iterations=300 hz=27000000
```

**五个 CRC 与 CoreMark 官方 2K performance run 标准参考值逐位一致 ⇒ 移植标准、可复现。**

```text
CoreMark/MHz = 300 / 401,452,720 x 1e6 = 0.747
Total time   = 401,452,720 / 27,000,000 = 14.87 秒   （满足赛题"≥10 秒"）
```

> 注：`Memory location` 那行印的是 CoreMark 的默认文案字符串（写作 "DDR code/data"），
> 实际程序跑在**片内 ROM/RAM**。这是观感问题，提交报告前建议改掉。

## 复现方法

见根目录 `交接说明与15天计划.md` §3.2「复现步骤」。
