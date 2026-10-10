# boardtest —— 上板自检小程序

一块刚拿到手、或者刚改过 RTL 的板子，最怕的是「下载下去什么都没反应」：
不知道是没下载成功、时钟没起来、DDR 没初始化、还是程序自己跑飞了。

这个小程序就是解决这个问题的：**一次运行、18 项检查、按依赖顺序排列**，
第一项失败就能直接定位到问题在最底层的哪一环；而且**没接串口也能从 LED 读出结论**。

它比 CoreMark 更适合第一次上板：

| | boardtest | CoreMark |
|---|---|---|
| 运行时间 | < 1 秒（另有 2 秒可选的串口中断等待） | 按赛题要求 ≥ 10 秒 |
| 出结果需要串口吗 | **不需要**，K17 就够 | 需要 |
| 出错时能否定位到模块 | **能**，每项单独判定 | 只能看到 CRC 不对 |
| 依赖 DDR 吗 | 不依赖（DDR 只是其中一项） | 片内版不依赖 |

---

## 1. 结果怎么读

### 1.1 只看 LED（不需要任何接线）

| LED | 板上的丝印 | 含义 | 判据 |
|---|---|---|---|
| J16 | LED3 | `led_clk_alive` 心跳约 1 Hz | 在闪 = `core_clk` 正常 |
| M17 | LED4 | `led_ddr_ready` | 常亮 = DDR 初始化完成且 PLL 锁定，SoC 复位已释放 |
| K17 | 核心板 LED | `led_selftest` = 程序写的 `TEST_STATUS` | **约 1 Hz 慢闪 = 正在跑（RUN）→ 常亮 = 全部通过（PASS）→ 4 Hz 快闪 = 有失败（FAIL）** |

所以**最短的判断链**是：

```text
上电/按 KEY0
  ├─ 三个灯全不亮            -> 位流没下载成功 / 供电 / 时钟问题
  ├─ J16 闪、M17/K17 不亮    -> clock 有了但 DDR 没起来（看 DDR IP / 参考时钟）
  ├─ J16 闪、M17 亮、K17 不亮-> 程序没跑到 main（ROM 镜像 / 复位）
  ├─ K17 一直慢闪不转常亮    -> 程序卡住（某项测试里死等），看串口或缩短 RX 等待
  ├─ K17 常亮                -> 18 项全过，板子基本正常 ✓
  └─ K17 4 Hz 快闪           -> 有失败项；接串口看是哪一项
```

> **LED 的局限**：硬件只用 4 个状态（灭/慢闪/常亮/快闪）表示结果，所以**只能告诉你有失败，不能告诉你哪一项失败**。
> 想知道是哪一项就必须看串口。如果你的板子暂时无法接串口，可以加一个"LED 故障码"（K17 闪 N 下表示第 N 项失败），
> 那需要改 `soc_ddr3_leds`（把 `simple_mmio.scratch` 引进去当故障码），大约 40 行 RTL。要的话我可以补上。

### 1.2 接串口（能看到每一项的细节）

- **115200 8N1**
- 接线：USB-TTL 的 **TX → 40pin 扩展口 J8 第 35 脚（FPGA 的 AA21）**，
  **RX → 第 36 脚（AA20）**，**GND ↔ GND**
  （依据：厂家《RK3568_MES2L50H_100H 硬件使用手册 v1.1》表 3-12）
- **先打开串口，再按 KEY0**，否则会漏掉开头

串口输出长这样（下面是**真实跑出来的**，只是运行在指令级模拟器里）：

```text
=== myriscv board bring-up test v1.0 ===
core_clk   : 93750000 Hz (board_top.CORE_CLK_HZ)
ROM/RAM    : 16 KiB / 16 KiB on-chip
UART       : present (115200 8N1)
LED map    : J16=clk alive  M17=ddr ready  K17=test status
             K17 slow blink=RUN   steady=PASS   4Hz=FAIL

[ 1] CPU 基本整数运算 -> PASS  14 项运算全部通过
[ 2] CPU 分支与循环 -> PASS  累加/负向循环/有符号与无符号比较均正确
[ 3] MMIO ID 识别 -> PASS  ID = 0x4d4d494f （'MMIO'）
[ 4] MMIO SCRATCH 字节写使能 -> PASS  SW/SB/SH 写使能与数据移位正确（含 +1/+2/+3 偏移）
[ 5] MMIO CYCLE 递增 -> PASS  2000 次空循环期间走了 4004 拍
[ 6] 片内 RAM walking-1 -> PASS  1024 个字（4096 字节）walking-1 / 全0 / 全1 通过
[ 7] 片内 RAM 地址混入数据 -> PASS  1024 个字地址混入数据全部一致
[ 8] 片内 RAM 字节访问 -> PASS  128 个字节逐个写回一致，相邻字节无串扰
[ 9] 片内 RAM 半字访问 -> PASS  高/低半字分别写入 32 个字，另一半均保持不变
[10] 异常 非法指令 -> PASS  mcause=2, mepc=0x0000160c，且已正确返回继续执行
[11] 异常 未映射地址访问 -> PASS  mcause=5, mtval=0x20000000
[12] 异常 MMIO 未实现偏移 -> PASS  未实现偏移正确报访问故障 mtval=0x10000020
[13] 异常 非对齐访存 -> PASS  mcause=4, mtval=0x00001801
[14] UART 存在性 -> PASS  STATUS=0x05, TX_READY=1, TX_BUSY=0
[15] UART 发送 -> [boardtest] UART-TX-MARKER-0123456789
PASS  已发出 UART-TX-MARKER 串；PC 端能看到即为 TX 通路正常
[16] DDR 窗口读写 -> PASS  0x40000000 起 4 KiB 地址混入数据全部一致
[17] DDR 远端地址不混叠 -> PASS  +0 / +2 MiB / +16 MiB 三处互不影响
[18] UART 接收中断 -> PASS  收到 1 次中断, ISR 读到的字节 = 0x48 ('H')

SUMMARY: 18 PASS / 0 FAIL / 0 SKIP  (total 18)
RESULT: PASS board bring-up OK. K17 should be STEADY ON.
RESULT-LINE: boardtest pass=18 fail=0 skip=0
```

最后那行 `RESULT-LINE:` 是给脚本解析用的，方便自动记录结果。

---

## 2. 18 项测试分别在查什么

顺序是按依赖关系排的：**越靠前越基础，第一项失败就说明问题在最底层**。

| # | 测试 | 具体在验什么 | 失败通常意味着 |
|---|---|---|---|
| 1 | CPU 基本整数运算 | add/sub/and/or/xor/sll/srl/**sra**/slt/sltu/ori/slli 等 14 项，含符号扩展与算术右移 | 核本身的 ALU/译码，或编译产物错误 |
| 2 | CPU 分支与循环 | bne 循环求和、负向循环、**有符号 blt 与无符号 bltu 必须给出不同结果** | 分支比较逻辑（blt/bltu 混淆是经典 bug） |
| 3 | MMIO ID 识别 | 读 `0x1000_0004` 应得 `0x4D4D494F`（"MMIO"） | 数据互连译码、simple_mmio 未接入 |
| 4 | MMIO SCRATCH 字节写使能 | 用 SW→SB(+1)→SH(+2)→SB(+3) 依次写，软件维护同一份影子值，再整体比较 | `wstrb` 或 **写数据移位** 不对（CPU 是 `rs2 << (addr[1:0]*8)`） |
| 5 | MMIO CYCLE 递增 | 两次读之间插入 2000 次空循环，确认计数器在走 | 计数器没接时钟/没复位 |
| 6 | 片内 RAM walking-1 | 对 1024 个字跑 walking-1、全 0、全 1 | BRAM 数据位粘连、写使能失效 |
| 7 | 片内 RAM 地址混入数据 | 每个地址写 `(地址 ^ 0xA5A5A5A5)`，专抓地址线粘连 | 地址译码错误（表现是"数据看着对但一多就乱"） |
| 8 | 片内 RAM 字节访问 | 128 个字节逐个写回，验证相邻字节互不干扰 | 字节写使能只作用了部分 lane |
| 9 | 片内 RAM 半字访问 | 先整字写 `0xDEADBEEF`，再单写高/低半字，验证另一半不变 | 半字写的掩码错误 |
| 10 | 异常 非法指令 | 执行 `.word 0`，期望 `mcause=2`，且处理函数返回后程序能继续 | CSR/mtvec/mepc 未生效，或 MRET 不工作 |
| 11 | 异常 未映射地址访问 | 读 `0x2000_0000`（数据总线上没有任何从机），期望 `mcause=5` 且 `mtval` 等于该地址 | 互连的错误响应没接到 CPU 的访问故障通路 |
| 12 | 异常 MMIO 未实现偏移 | 读 `0x1000_0020`（4 KiB 窗口内但没实现），期望 `mcause=5` | simple_mmio 的默认分支没报错 |
| 13 | 异常 非对齐访存 | 奇地址 `lh`，期望 `mcause=4` | 非对齐检测缺失（会导致后续 debug 很难受） |
| 14 | UART 存在性 | 读 `0x1000_1008`，确认 `TX_READY=1` 且没有访问异常 | `soc_top` 的 `ENABLE_UART` 不是 1，或 uart_mmio 没接 |
| 15 | UART 发送 | 发一串标记字符并确认 `TX_READY` 恢复 | TX 通路/波特率/接线（**需要 PC 端确认是否看到**） |
| 16 | DDR 窗口读写 | `0x4000_0000` 起 4 KiB 逐字写 `(地址 ^ 0x5A5A5A5A)` 再回读 | DDR IP 未初始化、桥有问题、`ENABLE_DDR=0` |
| 17 | DDR 远端地址不混叠 | 在 +0 / +2 MiB / +16 MiB 三处写不同值，确认互不影响 | **地址换算错误**（DDR 用户口地址单位是 16 位字，很容易错） |
| 18 | UART 接收中断 | 使能 RX 中断、开 `mstatus.MIE`，等 2 秒；PC 端发一个字符，ISR 应该被调用并读走该字节 | RX 引脚没接 / FIFO / IRQ 电平 / 中断入口。**收不到只算 SKIP，不算失败** |

第 18 项是**唯一需要你动手配合**的：程序会等你 2 秒，这段时间里从串口助手发任意一个字符（比如 `H`）即可。
不想等就 `build.ps1 -RxWait 0` 把它关掉。

---

## 3. 目录结构与设计要点

```text
boardtest/
├─ README.md              本文件
├─ build.ps1              构建入口（编译 → 生成两块 IP 的初始化文件 → 可选装进工程）
├─ src/
│  ├─ boardtest.h         共享声明、结果码、CSR 读写宏、中断位定义
│  ├─ main.c              主流程：置 RUN → 探测 UART → 逐项跑 → 汇总 → 置 PASS/FAIL
│  ├─ console.c           最小 printf（同时支持输出到串口和到内存缓冲）、CYCLE、UART 辅助
│  └─ tests.c             18 项测试 + 测试表
├─ bsp/
│  ├─ soc_mmio.h          MMIO 地址定义（与 myriscv/*.v 的真实译码一致）
│  ├─ start.S             启动 + 异常向量（**会 MRET 返回**，因为要故意制造异常）
│  ├─ trap.c              异常/中断的 C 侧处理
│  ├─ memops.c            memcpy/memset/... （-nostdlib 下 GCC 仍会调用）
│  └─ linker_onchip.ld    片内布局，专门切出一块 RAMTEST 区给自检用
└─ tools/
   ├─ elf2dat.py          ELF → inst_rom.dat / data_ram.dat（按段属性分流）
   ├─ install_to_ip.py    写回 MyCpu_test/boardtest/ 并改写两个 IP 的 INIT_FILE
   └─ rv32i_sim.py        RV32I 指令级模拟器（不上板也能先验证软件）
```

### 三个关键设计点

**(1) 片内 RAM 被切成三块，互不干扰**

```text
RAMDATA  0x0000-0x17FF  6 KiB   程序自己的 .sdata/.data/.rodata/.bss
RAMTEST  0x1800-0x27FF  4 KiB   自检专用：程序不在这里申请任何变量，整片随便写
STACK    0x2800-0x3FFF  6 KiB   栈（启动时用 0xA5 预填，事后可以看栈用了多深）
```

这样第 6~9 项能对整片 4 KiB 做破坏性测试而不会踩到程序变量或栈；
链接脚本里还有 `ASSERT(__ram_data_end <= ORIGIN(RAMTEST))` 兜底，万一以后数据区长大了会直接链接报错。

**(2) 异常向量会返回，不是"打印完停住"**

CoreMark 版的异常处理是打印后死循环（正常不该有异常）。自检版必须能继续跑，所以：

- **同步异常**：故障指令不能重试 → 处理函数返回 `mepc + 4` 跳过它
  （本工程 `-march=rv32i_zicsr` 没有 C 压缩扩展，指令定长 4 字节，所以 `+4` 就是下一条）
- **中断**：`mepc` 指向**还没执行**的那条指令 → 处理函数原样返回 `mepc`

处理函数里**一个字符都不打印**：万一 UART 本身没映射，打印会再次触发异常，变成无限递归。
所有信息记在全局变量里，交给主流程打印。

**(3) 先探测 UART，再决定要不要输出**

如果 UART 没接入而程序还拼命 `printf`，每个字符都会触发一次访问异常。所以 `main` 开头先只读一次
`UART_STATUS` 判断 UART 在不在，不在就完全静默，只靠 LED 出结果。

---

## 4. 怎么构建和上板

### 4.1 构建

```powershell
cd D:\riscv\RISCV\boardtest

# 编译 + 生成两块片内存储的初始化文件（build\inst_rom.dat / data_ram.dat）
powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1

# 顺便装进工程（复制到 MyCpu_test\boardtest\，并改写两个 IP 的 INIT_FILE，自动备份 .idf）
powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1 -Install

# 不想等 UART 接收中断那 2 秒
powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1 -RxWait 0
```

工具链会自动找：`D:\riscv\tools\*\bin\*-gcc.exe` → 再找 PATH 上的 `riscv32-unknown-elf-gcc`
等。也可以用 `-Toolchain <目录或exe>` 指定。

当前实测占用（`-Os`）：

| 区 | 用量 | 容量 | 占比 |
|---|---|---|---|
| ROM（`.text`） | 6168 B | 16 KiB | 38% |
| RAMDATA | 4372 B | 6 KiB | 71% |
| RAMTEST | — | 4 KiB | 自检用 |
| STACK | — | 6 KiB | — |

### 4.2 上板

1. PDS 打开 `D:\riscv\RISCV\RISCV.pds`
2. **把 `inst_rom` 和 `data_ram` 两个 IP 重新 Generate**（`-Install` 只改了 IDF，网表还是旧的）
3. Compile → Synthesize → Device Map → Place & Route → Report Timing → Generate Bitstream
4. `Tools → Configuration → Scan Device` → 添加 `generate_bitstream/board_top.sbit`
5. 按 **KEY0**
6. 先看 LED（J16 闪 / M17 亮 / K17 跑完常亮），再看串口

### 4.3 换回别的镜像

```powershell
# 回到 CoreMark
cd D:\riscv\RISCV\coremark
powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1 -Opt -Os -Iterations 0 -Install

# 回到原来的 DDR 自检启动镜像
cd D:\riscv\RISCV\boardtest
python tools\install_to_ip.py --restore
# 然后都要在 PDS 里重新 Generate 那两个 IP
```

---

## 5. 不上板也能先验证：指令级模拟器

`tools/rv32i_sim.py` 是一个最小 RV32I + Zicsr 模拟器，按本工程真实的存储器和 MMIO 边界工作，
可以直接把 `inst_rom.dat` / `data_ram.dat` 跑起来：

```powershell
python tools\rv32i_sim.py build\inst_rom.dat build\data_ram.dat --inject-rx 48 --log build\sim_uart.log
```

输出（**本次实测**）：

```text
instructions executed : 182,373
stop reason           : self-loop at pc=0x00000244
trapped               : True  mcause=0x8000000b mepc=0x00000fdc mtval=0x00000000
UART bytes captured   : 2025
...
  pass=18  fail=0  skip=0

RESULT: PASS (boardtest)
```

它能模拟的东西（都是按 RTL 的实际语义写的）：

- `simple_mmio` 的 SCRATCH 字节写使能合并、ID/CYCLE/STATUS、**TEST_STATUS 的单向状态机**（PASS/FAIL 必须在 RUN 之后，否则报总线错误）
- `uart_mmio` 的 TX/RX/STATUS/CONTROL（含 RX 读 pop、CONTROL 需要 lane1、bit8/bit9 使能与禁用）
- 未映射地址与未实现偏移 → load `cause 5` / store `cause 7`
- 非对齐访问 → `cause 4` / `cause 6`
- **中断**：`mstatus.MIE && |(mip & mie)`，优先级 external > software > timer，`mepc` 取被打断的那条指令
- `--inject-rx` 往 RX FIFO 塞字节，用来测第 18 项
- `--trace-trap N` 打印前 N 次异常/中断（排查异常机制非常好用）

**它不能替代上板**：这是功能模型，不是周期精确模型，不能用来判断时序、延迟或 CoreMark 分数。

> 顺带说一句：写这个自检程序的过程中，模拟器自己被抓出三个 bug —— CSR 写把**寄存器号**当成了**寄存器内容**、
> `srai` 用 bit 25 而不是 bit 30 判类型、DDR 窗口只开了 16 MiB。第 1 项（CPU 运算）和第 17 项（DDR 远端地址）
> 就是被这个程序测出来的。这也说明"有个自检程序"比"盯着波形猜"效率高得多。

---

## 6. 失败怎么排查（对照表）

| 失败项 | 先查什么 |
|---|---|
| 1 CPU 基本整数运算 | 核的 ALU/译码；如果是刚改过 RTL，先跑 `MyCpu_test/run_ddr_rv32i_fast.py` 对照 |
| 2 CPU 分支与循环 | `blt/bge` 与 `bltu/bgeu` 是否用了同一个比较器 |
| 3 MMIO ID | `soc_top` 里 `data_bus_interconnect` 的 MMIO 译码窗口；simple_mmio 是否在源文件列表里 |
| 4 SCRATCH 字节写使能 | CPU 的 `data_req_wdata` 移位（应为 `rs2 << (addr[1:0]*8)`）与 `data_req_wstrb` |
| 5 CYCLE | simple_mmio 的计数器时钟/复位 |
| 6~9 片内 RAM | `data_bram_adapter` 的字节写使能与 `data_ram` IP；确认 RAM IP 真的重新 Generate 过 |
| 10 非法指令 | `mtvec` 是否被正确写入（`csrw mtvec, t0` 之后读回来看）；`mepc`/`mcause`/`MRET` |
| 11/12 访问故障 | 互连的 `rsp_error` 是否接到了 CPU 的访问故障通路 |
| 13 非对齐 | 按规范应报 `cause 4`；若你的 CPU 有意支持非对齐访问，这一项可以改成 SKIP |
| 14/15/18 UART | `ENABLE_UART=1`；40pin 接线是否 TX/RX 交叉且共地；bank L5 的 IO 电平标准；波特率 115200 |
| 16 DDR 窗口 | DDR IP 是否初始化完成（M17 亮）、`ENABLE_DDR=1`、DDR 桥 |
| 17 DDR 远端地址 | **DDR 用户口地址单位是 16 位字**，不是字节地址 —— 这里最容易算错 |
| K17 一直慢闪不结束 | 卡在第 18 项等 2 秒（正常）；或有死等，用 `-RxWait 0` 复现，或接串口看停在哪一项 |
| K17 完全不亮 | 程序没跑到 `main`，或 simple_mmio 没映射（第 3 项都过不了） |

---

## 7. 已知边界（如实说明）

- **本程序只在指令级模拟器上验证过（18/18 PASS）**，还没有在实板上跑过 —— 这一点必须强调。
  模拟器验证的是"软件逻辑与 MMIO 语义对不对"，不能证明时序、电平、DDR 训练等硬件问题。
- 第 15 项（UART 发送）在板上是否真的通过，**需要你在 PC 端确认看到那串标记字符**；
  程序自己能确认的只是"字节写出去了且 `TX_READY` 恢复了"。
- 第 18 项在没人发字符时会报 SKIP（不是 FAIL），这是有意设计的。
- LED 只有 4 个状态，**无法从 LED 看出是哪一项失败**（见 1.1 末尾的说明和可选的 LED 故障码方案）。
- `tools/` 下的 `elf2dat.py`、`rv32i_sim.py` 与 `coremark/tools/` 下是同源的副本；
  `install_to_ip.py` 是各自独立的小脚本（不同的是目标目录名）。

---

## 8. 建议的使用顺序

```text
① 构建 + -Install → PDS 重新 Generate 两个 IP → 全流程构建 → 下载 → 按 KEY0
② 只看 LED：J16 闪 / M17 亮 / K17 常亮        -> 板子基本正常
③ 接上 USB-TTL，再跑一次，确认 18 项串口输出  -> 现在你有了一个"改动后可以随时复跑"的基准
④ 再切到 CoreMark（coremark/build.ps1 -Install）拿分数
⑤ 之后每改一次 RTL，先跑 boardtest 确认没把底层搞坏，再跑 CoreMark 看收益
```
