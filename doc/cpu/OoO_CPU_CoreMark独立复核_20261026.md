# 队友 OoO CPU 的 CoreMark 独立复核（2026-10-26）

> 目的：把"队友说 4.9210"变成**我们自己在板子上复核过的数字**，报告可引用。
> 位流 `D:\riscv\ooo_riscv_ddr3\generate_bitstream\board_top_ooo_ddr.sbit`
> SHA256 `a8981c462345a3811d769f6550297799d574c3c517e2a6f265e4e173236143e6`（9,188,552 B）
> 板卡：盘古 MES2L676-200HP-MINI（PG2L200H-6FBB676）· 串口 COM7 @115200
> 原始日志 `sim/ooo_coremark/board/first/run.log`（16 行，未做任何裁剪）

## 1. 原始输出（COM7 实录）

```
2K performance run parameters for coremark.
CoreMark Size    : 666
Total ticks      : 1423363782
Total time (secs): 10
Iterations/Sec   : 700
Iterations       : 7000
Compiler version : GCC13.2.0
Compiler flags   : -O3 -funroll-all-loops -finline-limit=1000 -fipa-pta -fno-common -march=rv32i_zmmul
Memory location  : DDR3 + 2-way I/D cache
seedcrc          : 0xe9f5
[0]crclist       : 0xe714
[0]crcmatrix     : 0x1fd7
[0]crcstate      : 0x8e3a
[0]crcfinal      : 0x25b5
Correct operation validated. See README.md for run and reporting rules.
PORT_DONE ticks=1423363782 iterations=7000 hz=135000000
```

`Correct operation validated` + 四个 CRC 与参照值一致 → **功能正确性成立**，不是只跑了时间。

## 2. 计算（以 ticks/hz 为准，不用固件打印的 Iterations/Sec）

```
运行时间     = 1,423,363,782 / 135,000,000 = 10.5434 s
每秒迭代     = 7,000 / 10.5434            = 663.9202 iter/s
CoreMark/MHz = 663.9202 / 135             = 4.9179
每迭代周期   = 1,423,363,782 / 7,000      = 203,338
```

**⚠️ 固件打印的 `Total time (secs): 10` 与 `Iterations/Sec: 700` 是把 10.5434 s 截断成 10 s
的结果，不能引用。** 权威值必须用 `ticks` 和 `hz` 反算。

## 3. 与我们顺序核的对比

| | 我们（-Os，93.75 MHz） | 队友 OoO（-O3，135 MHz） | 倍数 |
|---|---|---|---|
| CoreMark/MHz | 0.6904 | **4.9179** | **7.12×** |
| 每秒迭代 | 64.7288 | 663.9202 | **10.26×** |
| 每迭代周期 | 1,448,350 | 203,338 | 7.12× |

> 引用时必须注明编译选项不同（-Os vs -O3）。编译器差异通常值 30~50%，
> 即使按最坏情况折算，仍有 ~5× 的微架构差距（乱序 + TAGE + 2-way I/D Cache）。

与队友 10-26 自测的 4.9210（ticks 1,422,461,658）相比，本次 4.9179 差 **0.06%**，
属于运行间正常波动，**两次独立运行互相印证**。

## 4. 顺带确认的工程事实

* 我们的 COM7/115200 接线、串口工具链对**他的位流**同样有效，无需任何适配。
* 他的位流**不含任何视频模块**：`ooo_board_ddr.v` L56-58 把相机拉死
  （`camera_resetn = 1'b0`、`camera_scl/sda = 1'bz`），源码目录里没有任何
  camera/cnn/hdmi/osd/preprocess/rgb2tmds 文件。
  → **若要"视频 + 高跑分"同一位流，必须做集成，不能只替换位流。**
* DRAM 侧接口可以直连：`ooo_ddr_port.v` 里 `rid`、`rlast` 各出现 **0 次**，
  靠自身 `arlen` 计数，不依赖 DDR 仲裁链打的 ID。

## 5. 复现命令

```powershell
cd D:\riscv\RISCV
C:\Users\Lenovo\miniconda3\python.exe -X utf8 tools\ooo_coremark_listen.py `
  --port COM7 --seconds 60 --log sim\ooo_coremark\board\first\run.log
# 前提：用户已在 PDS 中烧录上述 sbit；必要时按一次 KEY0 复位
```
