# GitHub 可参考实例清单 —— RISC-V CPU + Cache/BTB + CoreMark（紫光同创 PG2L100H 平台）

检索日期：今天。检索目标：你赛题主线需要的四块能力 ——
**① 五级流水 RV32I 核 ② 2 路组相联 I/D Cache ③ BTB/动态分支预测 ④ CoreMark 跑分与移植**，
外加**⑤ 紫光同创平台上的真实竞赛作品**。

> ⚠️ **许可证提醒（比赛提交必须注意）**：下面每个仓库我都标了协议。
> **MIT / Apache-2.0** 可以参考甚至借鉴代码（保留版权声明）；
> **GPL-3.0** 只建议"读思路、不拷代码"（有传染性，可能影响你的作品授权）；
> **无协议**默认保留所有权利，**只能看结构、不能抄代码**。

---

## 0. 结论速览（按对你的价值排序）

| 优先级 | 仓库 / 资料 | 一句话 | 语言 | ★ | 协议 |
|---|---|---|---|---|---|
| **S** | [kerimturak/level-v](https://github.com/kerimturak/level-v) | **5 级流水 + Cache + gshare 分支预测 + CoreMark/Dhrystone/Embench**，和你的目标几乎重合 | SystemVerilog | 33 | GPL-3.0 ⚠️ |
| **S** | [紫光同创官方论文（中大 ICTA 2022）](https://www.pangomicro.com/about/news/company/1921.html) | **在 PG2L100H 上做 VexRiscv + CNN 加速**的公开论文，含主频/资源实测 | — | — | 论文 |
| **S** | [peiceliu/PicoRV32_ProtableLab](https://github.com/peiceliu/PicoRV32_ProtableLab) | **2024 嵌赛紫光同创赛题一 · 国家二等奖**，完整作品（RTL+硬件+上位机+文档） | Verilog | 42 | 无 ⚠️ |
| **A** | [MongooseOrion/wujian100_open_PANGO](https://github.com/MongooseOrion/wujian100_open_PANGO) | 无剑100 SoC **适配到紫光同创 FPGA** | Verilog | 1 | MIT |
| **A** | [windy07/PDS_YOLO](https://github.com/windy07/PDS_YOLO) | **2024 嵌赛紫光同创赛题三**（PixelFuze），Pango 平台 YOLO | Verilog | 14 | 无 ⚠️ |
| **A** | [RISCV-Tools/riscv-coremark](https://github.com/RISCV-Tools/riscv-coremark) | RISC-V 官方 **CoreMark 移植**仓库 | C | — | 见仓库 |
| **A** | [abmfy/cod23-grp04](https://github.com/abmfy/cod23-grp04) | 清华 COD 课程：5 级流水 + trap + **Cache + 分支预测** + TLB | SpinalHDL | — | 见仓库 |
| **A** | [Haibin 博客系列](https://www.haibinlaiblog.top/) | 中文教程：从零造 RISC-V CPU · **(三) TAGE 分支预测** · **(四) Cache 组相联** | — | — | 博客 |
| **B** | [xiaowuzxc/SparrowRV](https://github.com/xiaowuzxc/SparrowRV) | RV32IMZicsr 两级流水，**中文文档/BSP/仿真环境最完整** | Verilog | 80 | MIT |
| **B** | [GauravDhak/2-bit-Branch-Predictor-in-Verilog](https://github.com/GauravDhak/2-bit-Branch-Predictor-in-Verilog) | 独立可读的 **2-bit 饱和计数器**预测器 | Verilog | — | 见仓库 |
| **B** | [Senthil7271/CNN_Accelarator](https://github.com/Senthil7271/CNN_Accelarator) | CNN 加速器（高阶任务③参考） | Verilog | — | 见仓库 |
| **B** | tinyriscv（[gitee](https://gitee.com/liangkangnan/tinyriscv)） | 3 级流水，**中文注释最全**的入门经典 | Verilog | — | Apache-2.0 |
| **C** | [VexiiRiscv 文档](https://spinalhdl.github.io/VexiiRiscv-RTD/master/artefacts/VexiiRiscv_docs-master.pdf) | 高性能对标：**2.96 CoreMark/MHz**（看上限在哪） | SpinalHDL | — | MIT 系 |

---

## 1. S 级：必须先看的三个

### 1.1 ⭐ kerimturak/level-v —— 和你目标重合度最高

<https://github.com/kerimturak/level-v>

**它是什么**：开源 RV32IMC 处理器核，**五级流水 + Cache + gshare 分支预测 + SoC 外设 + 验证框架**。
GitHub topics 直接写着：`5-stage-pipelined-processor`、`cache`、`coremark`、`gshare`、`dhrystone`、`embench-iot`、`wishbone-bus`、`verilator`、`yosys`。

**为什么对你最有用**：

| 你的赛题要求 | 它里面有 |
|---|---|
| ≥3 级流水线 | 5 级，结构可直接对照 |
| **2 路组相联 I/D Cache** | 有 Cache 实现，可以看它的 refill / 替换 / 一致性处理 |
| **动态分支预测（如 BTB）** | **gshare** 预测器（比 2-bit BTB 更高级，可以只取它的 2-bit 部分） |
| **CoreMark 跑分** | 官方文档就有 CoreMark 构建流程 <https://kerimturak.github.io/level-v/coremark-build/> |
| 资源/时序关注 | 它同时跑 Dhrystone 和 Embench-IoT，说明作者在意"可对比的性能指标" |

**具体看什么**：
- `rtl/` 里找 cache 相关模块，重点看 **miss 处理与 refill 状态机**（这正是你最容易被卡住的地方）
- 分支预测器模块：看它怎么在 IF 阶段做预测、误预测时怎么冲刷 —— 和你现在"分支在 ID 判定"的结构对比
- `docs/sim/overview.md`：验证环境怎么搭的（它用 Verilator，你有 ModelSim/Icarus，思路可移植）
- CoreMark 文档：**移植清单和踩坑点**，可以直接对照你自己的 CoreMark port

**⚠️ 注意**：**GPL-3.0**。读思路、学架构、对比数据没问题；**不要整段拷贝代码**到你的作品里（GPL 有传染性，会影响你作品的授权与商用自己的权利）。把它当"教科书"而不是"代码库"。

---

### 1.2 ⭐ 紫光同创官方论文：PG2L100H 上的 RISC-V + CNN —— 这是你最该读的一篇

<https://www.pangomicro.com/about/news/company/1921.html>
（原标题《Implementation of CNN Heterogeneous Scheme Based on Domestic FPGA with RISC-V Soft Core CPU》，中山大学，ICTA 2022）

**它做了什么**：在**紫光同创 PG2L100H**（就是你的 FPGA）上，用 **VexRiscv 软核**做主控，
配 **DMA + 一维卷积加速器**，构成 CNN 异构系统。

**为什么是"必读"**：这是**公开资料里唯一一个和你赛题几乎完全对得上的完整实现**，而且给了真实工程数据：

| 论文里的数据 | 对你的意义 |
|---|---|
| 加速器 **153.6 GOP/s**，占 **14K LUT / 32 DRM / 208 APM** | 你的器件 66600 LUT / 155 DRM / 240 APM —— **它有明确的资源预算参考** |
| **VexRiscv 软核在 PG2L100H 上只能收敛到 100 MHz；加速器能到 200 MHz** | ★**极重要**：你现在 CPU 跑 93.75 MHz（受 DDR core_clk 限制）**并不算差**。想在 PG2L100H 上把五级核推过 ~125 MHz 会很难，这直接影响你"时钟频率"那一项的预期 |
| 用 **APB3** 接 I2C/SPI，用 **PMB** 接 DMA/加速器 | 总线分层思路可以直接借鉴 |
| "紫光同创 FPGA 的 DDR3 IP 提供的是**简化 AXI4** 接口，与标准 AXI 有差异，所以需要自研 DMA" | ★ **和你工程里"Pango 用户口是 AXI-like、没有 WVALID/B/RREADY"完全一致** —— 你的桥设计方向是对的 |
| 用**指令队列**降低 CPU→DMA→加速器的响应延迟 | 你的 AI 加速器可以照抄这个思路（CPU 连续发指令不等反馈） |
| INT8 量化：24 位累加 → 比例变换+移位 → 8 位；激活用 **分布式 RAM 查表** | 量化与激活单元的实现方式，直接可用 |

**怎么用**：把它当**你高阶任务③的架构蓝本 + 报告里的引用文献**。特别是"VexRiscv 100 MHz"这个数据，
可以正当地说明"本作品 CPU 工作频率的选择是有依据的"，而不是被评委问"为什么只有 93.75 MHz"。

---

### 1.3 ⭐ peiceliu/PicoRV32_ProtableLab —— 同一个比赛、同一个平台的获奖作品

<https://github.com/peiceliu/PicoRV32_ProtableLab>

**它是什么**：**2024 年全国大学生嵌入式芯片与系统设计竞赛 · FPGA 创新设计赛道 · 紫光同创赛题一「便携多功能仪」· 国家二等奖（研究生组）**。
基于 PicoRV32 软核，实现了信号发生器 + 示波器 + 频谱仪 + 逻辑分析仪四合一，HDMI 显示。

**为什么对你最有用 —— 不是技术，是"作品形态"**：

```text
pg50_proj
├─ 1_Hardware      // 自制转接板 PCB
├─ 2_RTL_code      // PicoRV32_SoC / 信号发生器 / 示波器 / 频谱仪 / 逻辑分析仪 / HDMI
├─ 3_Software      // 软核 C 程序 + 上位机 Python
└─ 4_Doc           // 比赛初期简易设计文档
reference_doc      // 参考文献与厂商例程说明
```

这就是**一个国奖作品的提交结构**：软核 SoC 只是"主控"，真正撑起作品的是**应用功能模块** +
**上位机软件** + **自制硬件**。你可以直接对照它检查自己的提交清单缺什么。

**另外它验证了一条重要经验**：**PicoRV32 这种"小软核 + 大量并行外设模块"的分工**，
在紫光同创赛题里是能拿国奖的路线 —— 和你"自研 RISC-V 核 + 外设 + AI 加速器"的思路一致。

**⚠️ 注意**：仓库**没有 LICENSE**，默认保留所有权利。**只看结构与分工，不要拷代码**。

---

## 2. A 级：模块级参考

### 2.1 MongooseOrion/wujian100_open_PANGO —— "怎么把 RISC-V SoC 搬上 Pango"

<https://github.com/MongooseOrion/wujian100_open_PANGO>（上游 [XUANTIE-RV/wujian100_open](https://github.com/XUANTIE-RV/wujian100_open)，2025★）

无剑100（平头哥开源 RISC-V SoC）**专门为适配紫光同创 FPGA 环境改过**的版本。
**价值**：你要处理的"Pango 平台特有的坑"（IP 生成、约束、时钟、DDR 接口差异、综合脚本）它踩过一遍。
规模小（3.1 MB），适合快速浏览它改了哪些文件来适配 Pango。

**协议**：MIT（上游也是 MIT）→ 可以参考。

### 2.2 windy07/PDS_YOLO —— 紫光同创上的 YOLO 实现

<https://github.com/windy07/PDS_YOLO>（描述：**2024 嵌赛 FPGA 紫光同创赛题三 —— PixelFuze**）

**价值**：你高阶任务③要"移植 YOLO 或轻量版大模型"。这是**同一个比赛、同一块平台**上别人怎么做的，
而且它 2026-05 还在更新（144 MB，含大量 RTL 和可能的模型文件）。
**看什么**：模型怎么切分成算子、权重怎么存、DDR 带宽怎么分配、后处理放哪边。
**注意**：无 LICENSE → 只看思路。

### 2.3 RISCV-Tools/riscv-coremark —— 官方 CoreMark 移植

<https://github.com/RISCV-Tools/riscv-coremark>

RISC-V 官方维护的 CoreMark 移植仓库。**价值**：对照你刚做好的 `coremark/` port，
看官方推荐的 `core_portme` 该怎么写、编译参数怎么给、bare-metal 场景有什么约定。
你的 port 已经用官方三个 CRC 验证通过（`0xe714 / 0x1fd7 / 0x8e3a`），可以拿这个仓库再交叉核对一遍配置项。

### 2.4 abmfy/cod23-grp04 —— 清华课程里的"完整 5 级流水 + Cache + 预测"

<https://github.com/abmfy/cod23-grp04>

32 位 **5 级流水 RISC-V**，带 traps、S 特权模式、虚拟内存、**Cache、分支预测、TLB**，SpinalHDL + Verilator，能跑 uCore。
**价值**：**Cache 与分支预测如何在乱序/精确异常框架里正确工作**，它的设计文档和验证思路值得读。
（比你的需求重，但**边界条件**处理得比大多数玩具核严谨 —— 你的 Cache 最怕的就是中断/异常与 refill 交叠。）

### 2.5 Haibin 博客系列（中文，边看边做）

- [(三) TAGE 分支预测微架构](https://www.haibinlaiblog.top/index.php/%e4%bb%8e%e9%9b%b6%e5%bc%80%e5%a7%8b%e9%80%a0%e4%b8%80%e9%a2%97-risc-v-cpu%ef%bc%88%e4%b8%89%ef%bc%89%ef%bc%9atage%e5%88%86%e6%94%af%e9%a2%84%e6%b5%8b%e5%be%ae%e6%9e%b6%e6%9e%84/)
- [(四) Cache 微架构演进与组相联设计](https://www.haibinlaiblog.top/index.php/%e4%bb%8e%e9%9b%b6%e5%bc%80%e5%a7%8b%e9%80%a0%e4%b8%80%e9%a2%97-risc-v-cpu%ef%bc%88%e5%9b%9b%ef%bc%89%ef%bc%9acache-%e5%be%ae%e6%9e%b6%e6%9e%84%e6%bc%94%e8%bf%9b%e4%b8%8e%e7%bb%84%e7%9b%b8%e8%81%94/)

**价值**：中文、成体系、专门讲**组相联 Cache 的演进**和**动态分支预测**。
比读英文论文快得多，适合你们 3 个人分头读然后互相讲。**先读 (四)**（对齐你的 2 路组相联 Cache），**(三) 当进阶**。

---

## 3. B/C 级：零件与对标

| 仓库 / 资料 | 用途 |
|---|---|
| [xiaowuzxc/SparrowRV](https://github.com/xiaowuzxc/SparrowRV)（MIT，80★） | **中文文档 + BSP + 仿真环境**组织得最好。它有 `Makefile + Python3 + Modelsim/iverilog` 的完整仿真流程和人机交互启动器，还有 MRS 图形化开发——**你的 `boardtest/`、`coremark/` 那套脚本可以对照它再规整一遍**。技术上是 2 级流水，性能不是重点 |
| [GauravDhak/2-bit-Branch-Predictor-in-Verilog](https://github.com/GauravDhak/2-bit-Branch-Predictor-in-Verilog) | 单独的 **2-bit 饱和计数器**实现，小而完整，作为 BTB 的计数器部分直接读 |
| [Senthil7271/CNN_Accelarator](https://github.com/Senthil7271/CNN_Accelarator) | CNN 加速器，配合 1.2 那篇论文一起看 |
| tinyriscv（[gitee](https://gitee.com/liangkangnan/tinyriscv)） | 3 级流水，**中文注释密度最高**。你已经在用它的 `difftest` 思路了（`rvtool.py`），可以再对照它的 SoC 与外设组织 |
| [VexiiRiscv 文档](https://spinalhdl.github.io/VexiiRiscv-RTD/master/artefacts/VexiiRiscv_docs-master.pdf) | 对标"上限"：**2.96 CoreMark/MHz**。用来在报告里说明"我们的分数处于什么水平" |
| [SEU 论文：Tinyriscv/蜂鸟E203/SparrowRV 对比表](https://chinaelectrondevices.seu.edu.cn/ch/reader/create_pdf.aspx?file_no=dz220740&flag=1&year_id=2024&quarter_id=6) | 中文期刊里现成的**三款开源核横向对比表**，做"相关工作"章节可直接引用 |
| [2025 集创赛紫光同创赛道](https://mp.weixin.qq.com/s?__biz=MzkwMjM0MjgzOA==&idx=1&mid=2247580621&sn=598bcdba80454464dd7c17cd5ff67c8e) / [2025 EDA 精英挑战赛紫光同创赛题](https://m.elecfans.com/article/6975487.html) | Pango 的其他赛事，往届获奖作品可能开源，可留意是否与你的赛题相邻 |

---

## 4. 建议的阅读顺序（别一次全看，会很乱）

```text
第 1 步（今天，1 小时）   读紫光同创那篇论文  → 建立"PG2L100H 上能做到什么"的现实预期
                          重点记住：VexRiscv 只能到 100 MHz；简化 AXI4 需要自研 DMA；153.6 GOP/s 的资源账

第 2 步（1 天）           读 PicoRV32_ProtableLab 的目录结构 + 它的 4_Doc
                          → 建立"一个国奖作品该长什么样"的认知，检查自己的提交清单

第 3 步（2-3 天，分工）    level-v 的 cache 模块 + gshare 预测器（GPL：只读思路）
                          + Haibin 博客 (四) Cache 组相联
                          → 直接支撑你的 Day 9-11（2 路组相联 Cache + BTB）

第 4 步（按需）            RISCV-Tools/riscv-coremark  → 交叉核对你的 CoreMark port
                          SparrowRV 的仿真/BSP 脚本组织 → 规整你自己的脚本
                          PDS_YOLO → 高阶任务③的实现路线
```

---

## 5. 从这些项目里能直接落到你计划上的 6 条

1. **时钟频率预期要调整**：论文实测 VexRiscv 在 PG2L100H 上只收敛到 **100 MHz**。你现在 93.75 MHz 是合理水平；**不要为了"频率"这一项去冒破坏时序的风险**，把力气放在 CoreMark/MHz（IPC）和 CoreMark/LUT 上。
2. **DDR 桥的自研 DMA 方向是对的**：论文明确说 Pango DDR IP 是"简化 AXI4"，标准 AXI DMA 不能用 —— 和你工程里的实际约束一致。你可以在报告里引用这篇论文来证明这个判断。
3. **Cache 抄"结构"不抄"代码"**：level-v 是 GPL-3.0，重点看 **miss/refill 状态机与中断交叠**的处理方式，代码自己写。
4. **分支预测从 2-bit 起步**：比 gshare 简单得多、收益已经很大。参考那个独立的 2-bit 预测器 + Haibin 博客。
5. **作品形态照 PicoRV32_ProtableLab**：软核 + 多个并行应用模块 + 上位机 + 自制硬件 + 设计文档。你的短板可能不是 CPU 而是"作品完整度"。
6. **高阶任务③可以引论文的架构**：VexRiscv + 指令队列 + 乒乓缓存 + 1D 卷积 + 查表激活 + 24→8 bit 量化，这套在 PG2L100H 上被验证过 153.6 GOP/s。

---

## 6. 一句话

**最该先读的是紫光同创那篇论文**（它把"这块 FPGA 上 RISC-V + CNN 能做到什么"讲透了，还给了主频这个你现在最需要的数据），
**最该对照结构的是 PicoRV32_ProtableLab**（同一比赛同一平台的国奖作品长什么样），
**最该对照实现的是 level-v**（5 级流水 + Cache + 分支预测 + CoreMark，和你的目标最接近，但 GPL 只能读不能抄）。
