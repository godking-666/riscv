# CoreMark 移植说明（本工程专用）

面向「全国大学生嵌入式芯片与系统设计竞赛 2026 · 选题一：基于紫光同创 RISC-V 指令集 CPU 设计」，
把官方 **EEMBC CoreMark** 移植到本仓库的自研五级流水 RV32I SoC 上。

赛题的性能评分完全基于 CoreMark：

```
          CoreMark_Iterations
Score = ────────────────────────        （等价于 CoreMark/MHz）
         Total_Time × Frequency
```

另外还单独评「时钟频率」和「资源效率 = CoreMark / LUTs」。所以本目录不只是"跑个分"，
它同时是后面 Cache / BTB / M 扩展等所有优化的**统一测量基准**。

---

## 1. 目录结构

```text
coremark/
├─ README.md              本文件
├─ build.ps1              构建入口（唯一需要手动运行的脚本）
├─ official/              ★ EEMBC 官方源码，逐字节未修改
│  ├─ core_main.c  core_list_join.c  core_matrix.c  core_state.c  core_util.c
│  ├─ coremark.h          （TOTAL_DATA_SIZE 默认 2*1000，即官方 2K performance run）
│  ├─ LICENSE.md  README.md
├─ port/                  移植层（本文件主要说明的对象）
│  ├─ core_portme.h       平台配置：HAS_FLOAT=1、MEM_STATIC、SEED_VOLATILE
│  ├─ core_portme.c       计时、串口、种子、portable_init/fini、异常上报
│  └─ ee_printf.c         精简 printf（支持 %f），约 1.5 KB 而不是官方的 13 KB
├─ bsp/                   板级支持
│  ├─ soc_mmio.h          MMIO 地址定义（与 myriscv/*.v 的实际译码一致）
│  ├─ start.S             启动：关中断、设 mtvec、gp、sp、清 bss、跳 main
│  ├─ memops.c            memcpy/memset/... （-nostdlib 下 GCC 仍会调用）
│  ├─ linker_onchip.ld    ★ 片内运行版（首选）
│  └─ linker_ddr.ld       DDR 运行版（需要 loader，见第 6 节）
└─ tools/
   ├─ elf2dat.py          ELF → inst_rom.dat / data_ram.dat
   └─ install_to_ip.py    写回 MyCpu_test/coremark/ 并改写两个 IP 的 INIT_FILE
```

---

## 2. 先理解三个硬件约束（决定了所有设计取舍）

**(1) 数据总线读不到启动 ROM**

`myriscv/data_bus_interconnect.v` 只译码 RAM / MMIO / UART / DDR。
片内 ROM 单独挂在指令总线上。所以：

> **所有会被 load 读取的只读数据（`.rodata`、字符串、CRC 表、跳转表）必须放在 RAM。**

`linker_onchip.ld` 已经按这个规则划分：ROM 只放 `.text`，`.rodata` 与 `.data`/`.bss` 一起放 RAM。
如果把 `.rodata` 放进 ROM，load 会落到同地址的 RAM 上读到无关数据，
现象是 CoreMark 三个 CRC 全部校验失败 —— 这是本移植最容易踩的坑。

**(2) 片内只有 16 KiB ROM + 16 KiB RAM**

ROM 和 RAM 在不同总线上，所以可以同基址 `0x0`（取指走 ROM，访存走 RAM），
这正好和现有 DDR 自检的用法一致。但容量很紧：

| 区 | 装什么 | 容量 | 超了会怎样 |
|---|---|---|---|
| ROM `0x0000–0x3FFF` | `.text`（含 libgcc） | 16 KiB | 链接期 ASSERT 报错 |
| RAM `0x0000–0x27FF` | `.sdata/.sbss/.rodata/.data/.bss` | 10 KiB | 链接期 ASSERT 报错 |
| RAM `0x2800–0x3FFF` | 栈（`_stack_top = 0x4000`） | 6 KiB | 启动时已用 0xA5 预填，可事后看用量 |

如果 `.text` 超过 16 KiB（很可能，CoreMark + printf + 软件乘除法大约 14–20 KB），按顺序试：

1. `-Opt -Os`（构建脚本已支持：`-Opt -Os`），注意报告里必须如实披露编译参数
2. 减少 printf：`-ExtraCflags -DCM_CONSOLE=0`（静默运行，只用于确认能跑通）
3. 扩容片内 ROM/RAM IP —— 见 15 天计划 Day 7：DRM 只用了 24/155 块，扩到 64 KiB×2 完全可行
4. 走 DDR 版（第 6 节），但那需要先解决 loader

**(3) CYCLE 只有 32 位**

`simple_mmio` 的 CYCLE（`0x1000_0008`）每 `core_clk` 加一，在 93.75 MHz 下
**约 45.8 秒回绕**。CoreMark 要求单次≥10 秒，所以正常跑是安全的；
`core_portme.c` 在测量值超过 `0xF0000000` 时会打印告警，届时请调小 `ITERATIONS`。

---

## 3. 快速开始（三步）

```powershell
# 0) 需要有 RISC-V GCC。优先用赛题指定的 riscv32-unknown-elf-gcc；
#    xpack 的 riscv-none-elf-gcc 也可以（功能等价，报告里写实际版本即可）。
#    没装的话：下载 xpack-riscv-none-elf-gcc-*-win32-x64.zip，解压到 D:\riscv\tools\

cd D:\riscv\RISCV\coremark

# 1) 编译 + 生成两块片内存储的初始化文件
powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1
#    产物：build\coremark.elf / coremark.map / inst_rom.dat / data_ram.dat

# 2) 装进工程（复制镜像 + 改写两个 IP 的 INIT_FILE，会自动备份 .idf）
powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1 -Install

# 3) 在 PDS 里手动做：
#    inst_rom IP 重新 Generate → data_ram IP 重新 Generate
#    → Compile → Synthesize → Device Map → Place & Route → Report Timing
#    → Generate Bitstream → 下载 board_top.sbit → 按 KEY0
#    → 串口 115200 8N1，应看到 CoreMark 报告和最后一行
#         CoreMark 1.0 : <分数> / GCC <版本> <编译参数> / STATIC
```

想回到原来的 DDR 自检启动镜像：

```powershell
python tools\install_to_ip.py --restore
# 然后再在 PDS 里重新 Generate 那两个 IP
```

---

## 4. 迭代次数：先自动定，再冻结

赛题要求「必须设置迭代次数，确保运行时间不低于 10 秒」。本移植支持两种方式：

**第一次（默认 `-Iterations 0`）**：CoreMark 自己从 1 开始 ×10 试探，
找到 ≥1 秒后再放大到约 10 秒，最后把决定下来的次数打印在报告里：

```text
Iterations       : 600
```

**正式记录成绩时**：拿上面那个数字重新编译一次，把它固定下来，让报告里的
迭代次数是一个明确、可复现的常数：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1 -Iterations 600 -Install
```

两种方式都要在报告里写清楚。建议**至少跑 3 次**同样的固定配置，确认分数稳定后再记录。

---

## 5. 移植层做了什么（对照官方要求）

| 官方接口 | 本移植实现 | 说明 |
|---|---|---|
| `barebones_clock` | 读 `simple_mmio` CYCLE | 与 CPU 同频，ticks 就是 CPU 周期数，正好是 CoreMark/MHz 要的量 |
| `start_time` / `stop_time` / `get_time` | 两次读 CYCLE 求差 | 只有 2 次 MMIO 读，开销可忽略；差值对消了读延迟 |
| `time_in_secs` | `ticks / 93750000` | `HAS_FLOAT=1`，返回 `double` |
| `ee_printf` | `port/ee_printf.c` | 精简版；`%f` 用 32 位定点实现，避免 64 位除法 |
| `portable_init` | 置 `TEST_STATUS=RUN`、打印配置、自检 `ee_ptr_int`/`ee_u32` 尺寸 | 官方要求的常见错误检查保留 |
| `portable_fini` | 回绕告警 + 按结果置 `TEST_STATUS=PASS/FAIL` | 板上 LED 能直接看出结果 |
| `portable_malloc/free` | 默认空实现（`MEM_STATIC` 不用堆），可选 `-DCM_HEAP_SIZE=` | 以后切 `MEM_MALLOC` 时现成可用 |
| 种子 | `PERFORMANCE_RUN` → `seed1=0, seed2=0, seed3=0x66` | 官方 2K performance run 的已知种子，CoreMark 会自动比对三张已知 CRC 表 |

`HAS_FLOAT=1` 是**必须**的：`core_main.c` 里官方那行
`CoreMark 1.0 : <分数> / ...` 被 `#if HAS_FLOAT` 包住，关掉就没有官方输出行了。
代价是链接进软件浮点（libgcc 的 `__divdf3` 等，约 1–2 KB）。

`cm_result_ok` 是唯一一处"绕过官方源码"的设计：`ee_printf` 观察到
`Correct operation validated` / `Errors detected` 时置位，`portable_fini` 再写到
`TEST_STATUS`。这样**不用改 `core_main.c` 一个字节**就能拿到 LED 指示。

---

## 6. DDR 版（现在还不能上板）

`build.ps1 -Mode ddr` 会把所有段放到 `0x4000_0000`。指令总线和数据总线都能访问 DDR，
所以那里没有 ROM/RAM 的区分问题，`.rodata` 也不需要特殊处理。

**但 DDR 是易失的。** 当前工程的 loader 只能把 245 字从片内 RAM 搬到 DDR，
而 CoreMark 需要 20 KB 以上，装不下。所以 DDR 版目前只能：

- 在 ModelSim 里由 TB 预载 DDR 模型来跑（可以用于验证 Cache 的效果对比）；
- 等完成下面任一件事之后再上板：
  1. 片内 RAM 扩到 64 KiB（15 天计划 Day 7），loader 就能一次搬完；
  2. 做一个 **UART 下载 loader**（大约 40 KB 走 115200 需要 3.5 秒），
     顺便解决后面 AI 模型权重的加载问题。

---

## 7. 常见问题

| 现象 | 排查方向 |
|---|---|
| 链接报 `ERROR: .text exceeds the 16 KiB on-chip ROM` | 用 `-Opt -Os`；或 `-DCM_CONSOLE=0` 先确认逻辑；或扩容 ROM IP |
| 链接报 `ERROR: .sdata/... exceed 10 KiB` | `.rodata` 是不是被放进 ROM/或数据太大；检查 `TOTAL_DATA_SIZE` |
| 串口没有任何输出 | UART 物理引脚还没写进 `constraint_check/temp_constraint_file.fdc`（主约束文件里目前没有 uart_tx/uart_rx）；另外确认 `soc_top` 的 `ENABLE_UART=1` |
| 串口输出乱码 | 波特率：必须 115200 8N1，且 `UART_CLK_HZ` 与实际 `core_clk`（93.75 MHz）一致 |
| 三个 CRC 全部 `[0]ERROR! ... crc 0x.... - should be 0x....` | 典型是 `.rodata` 没进 RAM；或 RAM 镜像没重新生成/没重新 Generate IP |
| 打印 `*** TRAP ***` | 读到了数据总线接不到的地址。看 `mtval`；常见是误以为数据能读 ROM |
| `Iterations/Sec` 很小、`Total time` 很长 | 正常：当前 CPU 是 **RV32I，没有 M 扩展**，CoreMark 里的乘法走 libgcc 的 `__mulsi3`。这就是基线；加上 Zmmul/M 扩展后应有数量级提升，正好做对照实验 |
| `WARNING! elapsed ticks = ... close to the 32-bit wrap` | 调小 `ITERATIONS`，让单次运行落在 10–40 秒之间 |

---

## 8. 交付与合规

- CoreMark 官方要求：保留官方算法与计算逻辑、披露**编译器版本、完整编译参数、迭代次数、计时频率、内存位置**。
  `build.ps1` 已把这些写进二进制（`COMPILER_VERSION` / `FLAGS_STR`），会随报告一起打印，请原样贴进文档。
- 本目录的 `official/` 是 EEMBC CoreMark **v1.01**（官方仓库当前 tag，CoreMark 1.0 基准的维护版本），
  逐字节未修改；`LICENSE.md` 随源码一起保留。
- 采集证据时请保存**串口原始输出**（不是截图里的手抄数字），并在报告里注明：
  日期、ELF 对应的 git tag、编译参数、迭代次数、运行时间、CPU 频率、以及当时的 LUT/FF/DRAM/APM 资源占用。

---

## 9. 与 15 天计划的对应

| 计划中的日子 | 本目录提供的东西 |
|---|---|
| Day 3 计时基础设施 | CYCLE 计时已可用；等 `mcycle` CSR 加好后把 `barebones_clock()` 换一行即可（改动点已隔离在一个函数里） |
| Day 4 裸机 C 环境 + UART printf | `bsp/start.S`、`memops.c`、`port/ee_printf.c` 就是最小可用的裸机 C 运行环境，可以直接复用给 AI 程序 |
| Day 5 CoreMark 闭环 | 本目录 |
| Day 6–12 各种优化 | 每次改 RTL 后重跑 `build.ps1 -Install`，把结果记进 `RISCV竞赛_15天任务表.xlsx` 的「性能记录表」 |
| Day 15 文档 | 第 8 节的合规清单 + 串口原始日志 |

## 10. 实测结果（已在真机编译 + 逐指令验证）

下面这些数字是本次实际编译、链接、并在自写的 RV32I 指令级模拟器上跑出来的，
不是估算。工具链：`xpack riscv-none-elf-gcc 15.2.0`（`-march=rv32i_zicsr -mabi=ilp32`）。

### 10.1 容量：`-O2` 装不下，`-Os` 装得下

| 配置 | `.text` | 16 KiB ROM | 结论 |
|---|---:|---|---|
| `-O2` | **17592 B** | 16384 B | ✗ 超 1208 B |
| `-Os` | **13944 B** | 16384 B | ✓ 余 2440 B（占用 85%） |
| 数据区（`.sdata/.sbss/.rodata/.bss`） | 5784 B | 10240 B | ✓ 占用 57% |
| 栈区 | — | 6144 B | 启动时用 0xA5 预填，可事后看用量 |

`-O2` 装不下的原因很具体：`HAS_FLOAT=1` 时 `secs_ret` 是 `double`，
GCC 的软浮点 `__adddf3 / __subdf3 / __muldf3 / __divdf3` 四个例程就要占约 **10.6 KB**，
占 `.text` 的 43%。为此 `port/ee_printf.c` 里的 `%f` 改成**纯整数实现**
（直接解析 IEEE-754 位模式），省掉了 `__adddf3 + __subdf3 + __muldf3` 约 8 KB，
这才让 `-Os` 能塞进 16 KiB。剩余仍被链入的软浮点只有 `__divdf3` 与几个比较/转换例程，
因为 `time_in_secs()` 必须返回 `double`。

**想要 `-O2` 并拿到更好的分数，就得扩容片内 ROM**（Day 7 那条，现在提前成 Day 1–2 的必做项）：
DRM 只用了 24/155 块，扩到 64 KiB ROM + 64 KiB RAM 余量充足，之后 `-O2`（17592 B）、
甚至 `-O3` 都能轻松放下。

### 10.2 正确性：三个官方已知 CRC 全部命中

用 `-Iterations 1` 编译（一次迭代就足以确定三个 CRC，因为矩阵/状态 CRC 与迭代次数无关），
在 `tools/rv32i_sim.py` 上运行 948,317 条指令，**没有触发任何异常**，串口输出 1383 字节：

```text
2K performance run parameters for coremark.
CoreMark Size    : 666
Total ticks      : 822026
Total time (secs): 0.008768
Iterations/Sec   : 114.047488
Iterations       : 1
Compiler version : GCC 15.2.0
Memory location  : STATIC
seedcrc          : 0xe9f5
[0]crclist       : 0xe714      <- 官方 2K performance run 期望值
[0]crcmatrix     : 0x1fd7      <- 官方期望值
[0]crcstate      : 0x8e3a      <- 官方期望值
[0]crcfinal      : 0xe714
```

`seedcrc=0xe9f5` 说明跑的是官方 2K performance run，三个 CRC 与官方已知值逐位一致，
所以**移植层、链接脚本、`.rodata` 放 RAM 的处理、整数版 `%f`、串口路径都是对的**。

`Total time (secs): 0.008768` 正好等于 `822026 / 93750000`，说明整数版 `%f` 的
六位小数与真实浮点结果一致（这条是专门验证过的）。

`ERROR! Must execute for at least 10 secs` 是 CoreMark 自带的规则检查，
`-Iterations 1` 必然触发，**不是移植错误**。正式记录成绩时用 ≥10 秒的迭代次数：

```powershell
# 先让 CoreMark 自己定迭代次数（会打印 Iterations: N）
powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1 -Opt -Os -Iterations 0
# 再用那个 N 固定下来，跑 3 次确认稳定
powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1 -Opt -Os -Iterations <N> -Install
```

模拟器给出的 `Iterations/Sec = 114`（≈ CoreMark/MHz 1.22）**只是"每指令一拍"的理想值**，
用来验证功能，**不能当成绩**：真实硬件的 CPI 大于 1，而且当前还没有 M 扩展
（CoreMark 里的乘法全部走 libgcc 的 `__mulsi3`）。真机数字必须上板测量。

### 10.3 复现命令

```powershell
cd D:\riscv\RISCV\coremark

# 功能验证（快，约 20 秒）
powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1 -Opt -Os -Iterations 1
python tools\rv32i_sim.py build\inst_rom.dat build\data_ram.dat --log build\sim_uart.log

# 正式成绩（先自动定迭代次数，再固定，然后 -Install 装进 IP 配置）
powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1 -Opt -Os -Iterations 0
powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1 -Opt -Os -Iterations <N> -Install
```

### 10.4 两个坑（已经踩过并修好，换机器时注意）

1. **必须用 `-march=rv32i_zicsr`**：GCC 12 以后 `-march=rv32i` 不再隐含 Zicsr，
   `bsp/start.S` 里的 `csrr/csrw` 会报 `unrecognized opcode`。本 CPU 确实实现了 Zicsr，
   所以这个 ISA 串是准确的。加了 M 扩展之后请改成 `-march=rv32im_zicsr` 做 A/B 对照。
2. **`-Wl,--no-check-sections` 是必需的**：片内 ROM 与 RAM 是两块独立存储器、
   合法地共用基址 `0x0`，链接器默认会报
   `section .sdata LMA [...] overlaps section .text LMA [...]`。
   真正要防的两件事（代码超 ROM、数据撞栈）在 `linker_onchip.ld` 里都有显式 `ASSERT` 兜底。

