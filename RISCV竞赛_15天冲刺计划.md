# 紫光同创 RISC-V CPU 赛题 —— 15 天冲刺计划

编制依据：赛题指南截图（选题一：基于紫光同创 RISC-V 指令集 CPU 设计）、你已有的工程文档
（`README.md`、`AGENTS.md`、`doc/SoC结构说明_2026-10-04.md`、`doc/CPU中断验收与UART_RX_IRQ_2026-10-05.md`、
`doc/UART顶层接入与DebugCore准备_2026-10-05.md`、`doc/AI加速多方案比较与推荐实施方案.md`、`zongxian.md`、
`MyCpu_test/ddr_stage/fast_summary.csv`、`multiseed_summary.csv`、`constraint_check/temp_constraint_file.fdc`）
以及对本仓库 RTL / 脚本 / IP 的直接核对。

> 本计划默认：一支 2～3 人小队、能拿到板卡或能用远程 FPGA 平台、当天开始 15 个自然日后交付。
> 文末第 7 节给出「单人 / 无板卡」的裁剪规则，以及必须由你确认的 3 件事。

---

## 1. 赛题文字整理（截图内容转写）

### 选题一：基于紫光同创 RISC-V 指令集 CPU 设计

**一、赛题背景与应用前景**
RISC-V 作为基于精简指令集（RISC）原则的开源指令集架构（ISA），凭借其模块化、可扩展和开源免费等特性，
正迅速重塑全球半导体产业格局。设计高效、稳定且具备高性能的 RISC-V 处理器，不仅是嵌入式开发和集成电路
设计的核心技能，更是推动国产芯片在各类前沿场景中深度落地的重要基石。本赛题旨在引导参赛者在推荐的
紫光同创 FPGA 平台上实现一个支持 RV32I 指令集的 CPU 核心，通过真实的软硬件协同设计与性能测评，
探索开源架构的无限潜能。

**二、核心设计任务**（使用 Verilog/SystemVerilog，基于推荐的紫光同创 FPGA 自制开发板）

*基础任务*
1. **处理器内核构建**：实现一个支持 RV32I 基础整数指令集的通用处理单元。
2. **流水线架构设计**：设计不少于 3 级的流水线结构，并妥善处理数据冲突与分支跳转等底层逻辑。
3. **外设系统集成**：集成基础外设（如 UART 控制器、GPIO 等）用于系统控制与结果输出。

*高阶任务*
1. **存储系统优化**：设计并实现支持 2 路组相联的指令与数据 Cache 系统，优化总线突发传输效率。
2. **高级控制逻辑**：实现动态分支预测器（如 BTB）以及完整的 RISC-V 异常/中断处理机制。
3. **AI 加速**：基于设计的 RISC-V 处理器，构建一整套的边缘 AI 加速单元，移植 YOLO 或轻量版大模型，
   融合一种或者多种传感器或者显示设备，完成图形的加速或语义识别或者机械控制等功能。

**三、测评工具与开发环境**
1. 硬件开发平台：基于赛题推荐的 FPGA 开发板（如上）或基于紫光同创 FPGA 为核心的开发板。
2. 软件编译工具链：`riscv32-unknown-elf-gcc`。
3. 性能基准测试：采用 **CoreMark v1.0**。

**四、性能测评标准**

1. **性能指标**

   性能评分基于 CoreMark 的跑分结果，公式如下：

   ```
              CoreMark_Iterations
   Score = ─────────────────────────
            Total_Time × Frequency
   ```

   - (1) **执行效率**：比较 CoreMark/MHz。分值越高，代表流水线设计越优化。
   - (2) **时钟频率**：在满足时序约束的前提下，处理器能达到的最高工作频率。
   - (3) **资源效率**：计算 CoreMark / LUTs。即在消耗单位逻辑资源的情况下，换取的性能提升。

2. **应用场景构建**

   作品应用场景的构建，基于实际的应用场景，如基于 RISCV 的游戏机、工控机、适配采集卡、逻辑分析仪、
   图像加速卡、网络加速卡等特定应用场景。
   - (1) **模型的性能和资源**：模型的整体资源，时序，主频。
   - (2) **基于特定模型 AI 处理效率**：综合评估延迟和识别率。

3. **技术实现与文档**
   - (1) **代码规范**：模块化程度、时序约束的合理性以及注释的完整性。
   - (2) **分析报告**：需提交详细的性能分析文档。利用 ILA 抓取的波形图，分析 CPU 在执行 CoreMark
     关键算法时的流水线效率。

**五、参赛注意事项**
1. CoreMark 测试时必须设置迭代次数，确保运行时间不低于 **10 秒**，以获得准确的平均数据。
2. 该赛题初赛不提供板卡借用（进入决赛由企业提供板卡借用），初赛阶段参赛选手自备板卡或者直接调用
   远程 FPGA 实验平台：`http://www.logicmatrixsemiconline.com:5174/`

### 1.1 从评分口径倒推出的 5 条硬结论

| # | 结论 | 对计划的直接影响 |
|---|---|---|
| 1 | 公式 `Score = Iterations/(Time×Frequency)` 等价于 **CoreMark/MHz**，分母含频率 | 提升 **IPC**（每周期指令数）与提升频率同等有效，而且 IPC 改动风险更低。**不要**为了频率牺牲 IPC 后不在三个指标上分别测量 |
| 2 | **仓库里完全没有 CoreMark**（已全库检索确认，无源码、无构建入口、无移植记录） | CoreMark 移植是唯一「不做就是 0 分」的任务 → 第 4 节列为关键路径 P0 |
| 3 | CoreMark 必须跑 **≥10 秒**且迭代次数可配置 | 需要一个 64 位、不撕裂、开销极低的周期计数器。当前只有 `simple_mmio` 的 0x10000008 CYCLE（32 位、每次读要走总线、约几十周期开销）→ 必须先补 `mcycle/minstret` CSR 或硬件定时器 |
| 4 | 三个指标互相牵制：Cache 提升 CoreMark/MHz 但吃 LUT，拉频率可能拉长流水线 | 每做一项改动都要同时记录 **CoreMark/MHz、可达频率、LUT** 三个数，做成对照实验表（这正是评分要的） |
| 5 | 明确要求 ILA 波形 + 逐模块资源/时序表 | 文档与波形不是「最后补」，而是评分项 → 从 Day 13 起倒排，且 Day 1 就要固定记录模板 |

---

## 2. 工程现状盘点（对照赛题逐条）

### 2.1 已完成、且有 RTL + 仿真证据的部分

| 赛题条目 | 现状 | 证据 |
|---|---|---|
| 基础①RV32I 通用处理单元 | ✅ 已实现 `mycpu_sync.v` 五级流水（IF/ID/EX/MEM/WB），子模块 regfile/alu/br_alu/l_alu/csr_file；`misa=0x40000100`（RV32I） | DDR RV32I fast 回归 `supported 40/40`、`MyCpu_test/ddr_stage/fast_summary.csv` |
| 基础②≥3 级流水、冲突与分支处理 | ✅ 已实现 EX>MEM>WB>寄存器堆前递、load-use 暂停、冲刷、分支在 ID 判定并重定向；类 SRAM 请求/响应总线已支持等待与背压 | `source/tb_cpu_ddr_overlap_fast.v`、`tb_cpu_ddr_backpressure_fast.v`，5/5 PASS |
| 基础③基础外设（UART/GPIO） | 🟡 **UART 已完成**（115200 8N1 @93.75 MHz、16 B RX FIFO、轮询 + RX 电平 IRQ、TX/RX 已引到 `board_top` 逻辑端口）；**GPIO 完全缺失** | `myriscv/uart_mmio.v` 等 4 个模块；`sim/uart_tx|uart_rx|uart_mmio` 全 PASS |
| 高阶②异常/中断处理机制 | ✅ M 模式 CSR 基本完整（mstatus/mie/mip/mtvec/mepc/mcause/mtval、Direct mtvec、MRET），三路 IRQ（external/software/timer）+ UART RX IRQ；**16 用例 × ROM/DDR 两种取指 = 32/32 PASS**，真实引脚 ISR 闭环 2/2 PASS | `doc/CPU中断验收与UART_RX_IRQ_2026-10-05.md` |
| （外围支撑）DDR 存储系统 | ✅ Pango DDR3 IP 已集成，x16 DDR（约束 `mem_dq[15:0]`）、128 位用户口、CPU 窗口 `0x40000000` 512 MiB、`core_clk = 93.75 MHz`；两条完整 DDR 定向联仿 PASS | `ipcore/ddr3/sim/modelsim/soc_ddr3_sim.log`、`soc_ddr3_regress_sim.log` |
| （外围支撑）板级启动链 | ✅ `board_top → soc_ddr3_top → soc_top → mycpu_sync`；KEY0 消抖 20 ms，DDR 初始化+锁定后释放复位；ROM loader 复制 245 字到 DDR 0x40000000 后跳转；112 项 DDR 自检 + MMIO TEST_STATUS + 3 个 LED | `MyCpu_test/board_selftest/manifest.tsv`、`README.md` §4 |
| （外围支撑）文档习惯 | ✅ `doc/` 下每阶段都有「目的/改动/复现命令/实测效果/未覆盖范围」记录，质量远高于一般参赛队 | `doc/*.md` 共 7 篇 |

### 2.2 未完成 / 缺失（按对分数的影响排序）

| 优先 | 缺口 | 核对依据 | 影响 |
|---|---|---|---|
| **P0** | **CoreMark v1.0 未移植**，无构建入口、无 `core_portme`、无 CRC 校验 | 全库检索无任何 CoreMark 文件 | 主评分项直接为 0 |
| **P0** | **无 `mcycle/minstret/mhpmcounter`**（`csr_defs.vh` 只到 `mconfigptr`），只有走总线的 32 位 MMIO CYCLE | `myriscv/csr_defs.vh`、`myriscv/simple_mmio.v` | 无法可信计时；无法统计 CPI/停顿/miss 来解释优化收益 |
| **P0** | **无板上硬件定时器**（无 mtime/mtimecmp、无 CLINT） | 全库无 CLINT/定时器模块 | CoreMark 计时、超时保护、延迟测量都缺基础 |
| **P0** | **工程路径与脚本不符**：工程实际在 `D:\riscv\RISCV\riscv-master\riscv-master\`，而脚本/IDF/TCL 硬编码 `D:/riscv/RISCV` | `README.md` §3、`AGENTS.md`、各 `*.tcl/*.py` | 现在直接跑回归会找不到文件，第一天必须先解决 |
| **P0** | **无版本管理**（该目录无 `.git`） | `Test-Path .git` = False | 15 天里做 Cache/BTB/AI 大改，无回退点＝极高风险 |
| **P1** | 无乘法（APM/DSP 使用量 = **0/240**）、无 `fence.i`、无 `M` 扩展 | `multiseed_summary.csv`、`mycpu_sync.v`（`FENCE.I` 落入非法指令） | CoreMark 中用软件乘法，CPI 极差；这是最便宜的一次性提分 |
| **P1** | 无动态分支预测（分支在 ID 判定，无 BTB/无 2 位计数器） | `doc/SoC结构说明_2026-10-04.md` §3 | CoreMark 分支密集，误预测冲刷直接吃掉 IPC |
| **P1** | 无 Cache；DDR 桥「一次仅一笔单拍事务、无 burst」 | 同上 §4 | CoreMark 若必须跑 DDR，取指延迟会主导 CPI |
| **P1** | **主约束文件里没有 UART 物理引脚**（`constraint_check/temp_constraint_file.fdc` 只有 DDR/LED/resetn）。厂家 DDR 例程的 `ddr_test.fdc` 给的是 `uart_txd=K14 / uart_rxd=H14`（LVCMOS33、3.3 V、RX 带 PULLUP），但**必须核对官方 Pin Map** | 两个 fdc 文件对比 | 没有引脚＝没有串口输出＝CoreMark 结果无法打印＝演示与证据链断裂 |
| **P2** | 无 GPIO、无传感器、无显示接口 | `myriscv/` 无 gpio 模块；fdc 无相关引脚 | 基础任务③不完整；高阶任务③「融合传感器或显示设备」无法闭环 |
| **P2** | 无 AI 加速器（AI 文档是方案设计，非实现） | `doc/AI加速多方案比较与推荐实施方案.md` 开头自述 | 高阶任务③未完成 |
| **P2** | `fence_i`、`ma_data` 两个已知缺口（`tohost=0x539`），全量 40/42 | `MyCpu_test/ddr_stage/fast_summary.csv` | 诚实披露即可；高阶任务②要的是异常/中断完整，不是这两条 |
| **P2** | 无性能分析报告、无 ILA 波形记录 | `doc/` 无对应文件 | 评分项「分析报告」为 0 |
| **P3** | 无 AI/加速器验证记录、无逐模块资源表 | — | 「模型性能和资源」「资源效率」两项缺数据 |

### 2.3 已经拿到的基线数字（写报告时要用，且必须用本轮 P&R 报告刷新）

来源 `multiseed_summary.csv`（既有实现记录，**不能当作本轮实测结论**）：

| 指标 | 数值 |
|---|---|
| 器件 | PG2L100H-6IFBG484（PDS 2022.2-SP6.4） |
| LUT | 5914 / 66600（9%） |
| FF | 6333 / 133200（5%） |
| DRM（块 RAM） | 24 / 155（16%） |
| APM（乘加/DSP 资源） | **0 / 240（0%）** ← 尚未使用任何硬件乘法器 |
| 分布式 RAM | 39 / 19900（1%） |
| 综合 Setup WNS / TNS | −0.021 / −0.021（轻微未收敛，需重跑确认） |
| 顶层 | `board_top` |

> 关键判断：**器件几乎是空的**（LUT 9%、DRM 16%、APM 0%）。这意味着 Cache、BTB、MAC 阵列都有充足资源空间；
> 但「资源效率 = CoreMark / LUTs」这一项要求你**不要**无节制地堆资源，每次加功能都要复测这一个比值。

---

## 3. 15 天总体技术路线

```
Day 1-2   冻结基线        路径修正 + git + 全回归 + PDS 全流程 + 上板自检 + 记录模板
Day 2-3   测量基础设施    mcycle/minstret CSR + 硬件定时器 + 裸机 C 环境 + UART printf
Day 4-5   CoreMark 闭环   官方 v1.0 移植 + CRC + 迭代次数≥10s + 基线分数    ← P0 闸门
Day 6-8   IPC 优化一      Zmmul/M 扩展（用 APM）→ 动态分支预测 BTB+2bit
Day 9-11  IPC 优化二      2 路组相联 I-Cache → D-Cache + FENCE.I + burst
Day 12    频率与资源收敛  时序收敛、频率扫描、分模块资源表、对照实验表
Day 13-14 AI 加速与应用    MMIO INT8 加速器 + 逐元素对齐 + 传感器/显示/GPIO 闭环
Day 14-15 冻结与交付       ILA 波形分析、性能分析报告、干净环境复现、打包提交
```

三线并行、互不阻塞：

- **A 线（关键路径）**：CoreMark 分数 —— Day 2→5 必须闭环，之后每次改动都以它做 A/B 对照。
- **B 线（硬件高阶）**：GPIO → M 扩展 → BTB → Cache → burst。
- **C 线（文档/证据）**：每天写 `doc/` 记录；Day 12 起集中产出资源表、时序表、ILA 波形、性能分析报告。

### 3.1 一条重要的策略判断（决定 Day 6 的岔路）

CoreMark 的代码+数据规模很可能**放不进当前的 16 KiB ROM + 16 KiB 数据 RAM**，
那样它就只能跑在 DDR `0x40000000`，而当前 DDR 桥是「一次一笔单拍、无 burst、无 Cache」——
CPI 会被取指等待彻底拖垮，CoreMark/MHz 会非常难看。

两条路，**建议两条都做，但顺序明确**：

| 方案 | 做法 | 工作量 | 对分数 | 备注 |
|---|---|---|---|---|
| **① 扩大片内存储（推荐先做）** | ROM/RAM 从 16 KiB 扩到 64 KiB（DRM 只用了 24/155，资源充裕）；改互连译码窗口 + 重新生成两块 IP + 改链接脚本 | 低（1～2 天） | CoreMark/MHz 大幅提升，且**LUT 几乎不涨 → 资源效率也提升** | 风险最低、收益最直接。CPU 与 DDR 解耦，主频也不再被 DDR 桥拖累 |
| **② 2 路组相联 Cache（赛题高阶任务，必须交付）** | I-Cache 4 KiB / D-Cache 4 KiB、32 B line、2 路、每组 1 位 LRU；I-Cache 阻塞式 refill；D-Cache 先 write-through / no-write-allocate / MMIO 旁路 | 中～高（3～4 天） | 让 **DDR 上运行**的程序提速；是「存储系统优化」这一条高阶任务的直接证据 | 会吃 LUT，略微拉低「资源效率」；所以最终提交版要同时给出「带 Cache / 不带 Cache」两行数据 |

**最终报告里给出这张对照表，就同时拿满了「执行效率」「资源效率」「高阶任务①」三处分数：**

| 配置 | CoreMark/MHz | 可达频率 | LUT | CoreMark/LUT | 说明 |
|---|---|---|---|---|---|
| A. 纯 DDR 取指、无 Cache（基线） | 低 | 93.75 MHz | 最低 | 低 | 现状 |
| B. 片内 64 KiB ROM/RAM、无 Cache | 高 | — | 略高 | **高** | 主推的提交配置 |
| C. 片内 + 2 路组相联 I/D Cache | 高 | — | 明显高 | 中 | 高阶任务证据 |
| D. DDR 取指 + 2 路组相联 I/D Cache | 中高 | — | 明显高 | 中 | 证明 Cache 在真实外存场景的价值 |

---

## 4. 15 天任务表（逐日）

标记说明：**【闸门】** = 当天必须通过才能继续；**【止损】** = 触发后立即降级；
P0/P1/P2 = 优先级。

### Day 1 —— 环境与路径冻结（不做任何功能改动）

| 项 | 内容 |
|---|---|
| 动作 | ① 全量备份：把 `D:\riscv\RISCV\riscv-master\riscv-master\` 整个复制一份到 `D:\riscv\RISCV\backup_D1\`（保留 `riscv-master.zip`）。② **路径归位**：把工程内容上移到 `D:\riscv\RISCV\`（使 `D:\riscv\RISCV\RISCV.pds` 存在），与 `README.md`/`AGENTS.md`/所有 TCL/IDF 的硬编码路径一致；上移后逐一核对 `ipcore/*/*.idf` 的 `INIT_FILE`、`sim/**/*.tcl` 的 `repo_dir`、`MyCpu_test/*.py` 的相对路径。③ `git init` + 首次提交 + `git tag baseline-D1`。④ 检查 `riscv32-unknown-elf-gcc` 是否已安装（赛题指定工具链），没有就当天装好（xPack `riscv-none-elf-gcc` 亦可，但报告里要写实际版本）。 |
| 交付物 | 归位后的工程目录；git 仓库 + `baseline-D1` tag；`doc/环境与路径冻结_<date>.md`（记录工具版本：PDS/ModelSim/Icarus/Python/gcc） |
| 验收 | `D:\riscv\RISCV\RISCV.pds` 存在；`git log` 有一次提交；`riscv32-unknown-elf-gcc --version` 有输出 |
| 风险 | 上移可能打断 PDS 工程的源文件记录 → 若 PDS 打开报找不到源文件，改用备选方案：保留原位、批量替换脚本里的 `D:/riscv/RISCV` 为新路径（记录改动清单） |

### Day 2 —— 全回归 + PDS 全流程 + 上板自检

| 项 | 内容 |
|---|---|
| 动作 | ① 复跑全部回归，确认归位没破坏任何东西：`soc_ddr3_sim.tcl`、`soc_ddr3_regress_sim.tcl`、`python MyCpu_test/run_ddr_rv32i_fast.py`、`run_led_status.py`、`run_key_reset_debounce.py`、`run_ddr_selftest_fast.py --base 0x40000000`、UART 四个 ModelSim 入口、`python sim/uart_irq/run_irq.py --stage cpu/uart`（各带/不带 `--ddr-code`）。② PDS 从头跑 **Compile → Synthesize → Device Map → Place & Route → Report Timing → Generate Bitstream**。③ 下载 `generate_bitstream/board_top.sbit`，按 KEY0 观察 J16 心跳 / M17 / K17 常亮。④ 建立 `doc/性能记录模板.md`（列：日期、版本 tag、CoreMark/MHz、迭代次数、耗时、频率、LUT/FF/DRAM/APM、WNS/TNS、回归结论）。 |
| 交付物 | 全回归日志；**本轮自己的**资源/时序报告导出（截图 + 数字）；上位机截图或视频；性能记录模板 |
| 验收 | 全部 `RESULT: PASS`、无 `RESULT: FAIL`、ModelSim `Errors: 0`；`40/42`（`fence_i`/`ma_data` 仍为已知缺口，如实记录）；bitstream 生成成功；板上三灯状态符合 `README.md` §4 描述 |
| 备注 | 板级 DDR 自检约 5 秒超时保护；如果 M17 不亮先查参考时钟/复位/PLL 锁定。远程平台则把「下载+sbit」换成平台的上板流程并记录实际平台名 |

### Day 3 —— 测量基础设施（mcycle / minstret / 硬件定时器）

| 项 | 内容 |
|---|---|
| 动作 | ① 给 `csr_file.v` 增加只读 CSR：`mcycle`(0xB00)/`mcycleh`(0xB80)、`minstret`(0xB02)/`minstreth`(0xB82)，64 位自由计数、复位清零、不参与异常。② 增加可选 `mhpmcounter3~5`（建议：分支总数、误预测数、访存等待周期 / Cache miss）——这三组数正是「流水线效率分析」章节的核心证据。③ 增加一个片上硬件定时器模块（`mtime`/`mtimecmp`，MMIO 基址建议 `0x10002000`，或直接接 `irq_timer`），提供毫秒级超时与延迟测量。④ 确认 `simple_mmio` 的 CYCLE 仍可用作交叉校验。 |
| 交付物 | 修改后的 RTL；定向 TB（读 mcycle 两次差值等于已知循环周期数；mtimecmp 到期触发 timer IRQ）；`doc/计时与计数器_<date>.md` |
| 验收 | C/汇编程序读出的 `mcycle` 差值与预期误差 ≤ 数个周期；timer IRQ 进入 ISR 并 MRET 返回；IRQ 32 项验收不退化 |
| 风险 | 新增 CSR 不要破坏现有 `csr_defs.vh` 的 WARL 掩码和非法指令判定；改完必须重跑 `sim/uart_irq` 全套 |

### Day 4 —— 裸机 C 运行环境 + UART printf

| 项 | 内容 |
|---|---|
| 动作 | ① 写链接脚本：ROM `0x00000000`（loader）、程序段按 Day 6 决策放片内或 DDR `0x40000000`、栈/堆划分、`tohost` 诊断区。② 写 startup：设置 `mtvec`、`gp`、`sp`、清 bss、跳 `main`；实现 `_write`/`putchar` 走 UART TX（轮询 `STATUS` bit0 TX_READY）。③ 实现 `ee_printf` 所需的最小 `printf`（CoreMark 官方 barebones port 只需 `%d/%u/%x/%s/%c` 与 `%08x`）。④ 顺手加 **GPIO 模块**（`gpio_mmio.v`：方向寄存器 + 输出寄存器 + 输入寄存器，基址建议 `0x10002000` 段），补齐基础任务③，并为 AI 应用闭环预留执行机构输出。⑤ 落实 UART 物理引脚：核对官方 Pin Map 后写入 `constraint_check/temp_constraint_file.fdc`（厂家 DDR 例程给的 K14/H14 只作线索，**不能直接当结论**）。 |
| 交付物 | 链接脚本 + startup + 最小 libc；`gpio_mmio.v` + 约束；UART 引脚约束；能打印 `Hello <mcycle>` 的镜像 |
| 验收 | 串口（或远程平台串口）收到正确字符串；打印的 mcycle 单调递增；GPIO 输出可被 LED/万用表/示波器观察到；全回归不退化 |
| 【闸门】 | **UART 必须在本日打通拿到输出**。若引脚无法确认 → 立即改用远程 FPGA 平台，或退化为「把结果写 `tohost` 区 + 用 ILA/仿真读回」的证据链，并在报告中如实标注 |

### Day 5 —— CoreMark v1.0 移植闭环  ⭐ 全项目最关键的一天

| 项 | 内容 |
|---|---|
| 动作 | ① 取 **官方 CoreMark v1.0**（EEMBC 仓库），保留官方算法与计算逻辑不做任何修改。② 移植 `core_portme.c/h`（barebones port）：`start_time()/stop_time()` 用 `mcycle` 或 timer，`ee_printf` 接自己的 UART，`ITERATIONS` 通过 `-DITERATIONS=` 或宏可配置，`MAIN_HAS_NOARGC=1`，`PERFORMANCE_RUN=1`，`TOTAL_DATA_SIZE=2000`。③ 编译选项：**RV32I 阶段用 `-march=rv32i -mabi=ilp32 -O2`**（软件乘法走 libgcc `__mulsi3`）；把编译器版本、完整命令行、迭代次数、内存位置、Cache 配置全部记入报告。④ 先跑小迭代确认 **CRC 自检通过**（不对就说明移植或计时有问题，不许往下走）。⑤ 调 `ITERATIONS` 使单次运行 **≥10 秒**，记录 `CoreMark 1.0 : <分> : <MHz> MHz, ... iterations, ... secs`。 |
| 交付物 | `coremark/` 目录（官方源码 + port + 构建脚本）；串口输出原始日志；`doc/CoreMark移植与基线_<date>.md`；性能记录表第一行基线数据 |
| 验收 | **CRC 自检 PASS**；单次运行 ≥10 s；能给出 CoreMark/MHz 与 CoreMark/LUT 两个数字；`git tag coremark-baseline` |
| 【闸门 G0】 | **本日结束 CoreMark 必须跑通。**若未通过：Day 6～7 全员只做 CoreMark，暂停一切 Cache/BTB/AI 工作。没有 CoreMark 分数，后面所有优化都无法证明 |

### Day 6 —— 基线瓶颈分析 + Day 6 岔路决策

| 项 | 内容 |
|---|---|
| 动作 | ① 用 `minstret`/`mcycle` 算出基线 **CPI**；用 `mhpmcounter` 统计分支数、访存次数、取指等待周期。② 判断 CoreMark 是否只能跑 DDR（看链接后 text+data+stack 是否超 16 KiB×2）。③ ILA 首次试抓：Fabric Inserter 挂 `debug_wb_pc`、`debug_inst`、各级 valid/stall/flush、访存握手，触发点设在矩阵乘/链表循环，8192 深度单窗口 All Data，采样时钟用真实 `core_clk`。④ **决策**：若 DDR 取指占比大 → 先做片内扩容（Day 7）再 BTB；若分支冲刷占比大 → 先做 BTB 再扩容。 |
| 交付物 | CPI 分解表；分支/访存/等待统计；第一张 ILA 波形截图 + 触发条件记录；决策记录 |
| 验收 | CPI、分支数、取指等待周期三个数都有实测值；ILA 抓到至少一个 CoreMark 关键循环的波形 |
| 备注 | DebugCore 只加在「调试版」位流上，资源与对时序的影响要单独记录，提交版说明是否保留 |

### Day 7 —— 片内存储扩容（64 KiB ROM / 64 KiB RAM）

| 项 | 内容 |
|---|---|
| 动作 | ① 修改 `inst_bus_interconnect.v` / `data_bus_interconnect.v` 的译码窗口：ROM/RAM 从 16 KiB 扩到 64 KiB（`0x00000000–0x0000FFFF`），保持与原 MMIO `0x10000000` 不重叠。② 重新生成 `inst_rom` / `data_ram` IP（`4096×32` → `16384×32`），更新 IDF 的 `INIT_FILE` 与深度参数。③ 改链接脚本与 loader（boot ROM 的复制源/长度清单、`RAM 0x3FF0` manifest 位置会随之变化，必须同步）。④ 复跑两条 DDR 定向 + RV32I fast + IRQ 全套。 |
| 交付物 | 扩容后的互连/IP/链接脚本；可跑在片内 ROM+RAM 的 CoreMark 镜像；`doc/片内存储扩容_<date>.md` |
| 验收 | CoreMark 在**不访问 DDR** 的情况下跑通且 CRC 正确；CoreMark/MHz 相对基线明显提升（记录数值）；全回归不退化 |
| 风险 | loader manifest 位置是硬约定 → 改错会导致启动失败。改完先用 `run_ddr_selftest_fast.py --base 0x40000000` 验证启动链，再换 CoreMark 镜像 |

### Day 8 —— M 扩展（用 FPGA 的 APM 硬件乘法器）

| 项 | 内容 |
|---|---|
| 动作 | ① 译码/EX/写回加 `M` 扩展：`MUL/MULH/MULHU/MULHSU`（Zmmul 子集）优先；有余力再补 `DIV/DIVU/REM/REMU`。② 乘法用器件 APM/DSP 原语（当前占用 **0/240**，资源充足），避免拉长 EX 关键路径；多周期乘法要有 `stall`/`flush`/中断排空的正确行为。③ `misa` 相应置位；编译改用 `-march=rv32im`。④ 定向测试必须覆盖：有符号/无符号边界、溢出、`rs2=0`、除零商=-1 余数=被除数、依赖前递、与中断/异常交叠。 |
| 交付物 | M 扩展 RTL + 定向测试；CoreMark A/B 对照（rv32i vs rv32im）；资源增量（APM/LUT/FF） |
| 验收 | M 扩展定向测试全 PASS；CoreMark CRC 仍正确；CoreMark/MHz 提升幅度有数字；IRQ 32 项不退化 |
| 备注 | 这是**投入产出比最高的一项**：CoreMark 里大量 32 位乘法，软件 `__mulsi3` 每次几十周期，换成硬件乘法是数量级差异 |

### Day 9 —— 动态分支预测（BTB + 2 位饱和计数器）

| 项 | 内容 |
|---|---|
| 动作 | ① 在 IF 增加 BTB 查表：{PC tag, 预测目标, 2 位饱和计数器}，容量先做 64～128 项（小步起步，便于收敛时序）。② 预测命中且计数器 ≥2 → 直接重定向取指；ID 判定后若预测错误 → 冲刷并更新计数器与目标。③ 统计 `mhpmcounter`：分支总数、预测正确/错误数、冲刷拍数。④ 回归：分支密集微基准 + 全套 IRQ（**中断排空/冲刷逻辑最容易被分支预测改坏**）+ CoreMark。 |
| 交付物 | BTB RTL + TB；误预测率统计；CoreMark A/B 对照；资源增量 |
| 验收 | 误预测率实测下降；CoreMark CRC 正确；IRQ 32 项全 PASS；`git tag btb-ok` |
| 风险 | 冲刷与「已接受但迟到」的投机取指响应必须仍按原机制丢弃；若 BTB 引入一致性 bug 且 1 天内定位不了 → 【止损】回退到 `coremark-baseline` 或 `m-ok` tag，只保留分支统计 |

### Day 10-11 —— 2 路组相联 Cache（I-Cache → D-Cache）+ FENCE.I

| 项 | 内容 |
|---|---|
| 动作 | ① **I-Cache**：4 KiB、32 B line、2 路、每组 1 位 LRU、64 组、阻塞式 refill；取指命中 1 拍返回，miss 时向 DDR 桥发起 line fill。② 实现 **FENCE.I（Zifencei）**：清 I-Cache 有效位 + 清预取缓冲（当前 `funct3=001` 会落非法指令，必须改译码）。③ **D-Cache**：4 KiB、同上参数，**write-through / no-write-allocate / 无 posted 写缓冲**（降低脏块与错误追溯复杂度）；MMIO 必须旁路且非投机（`simple_mmio`/`uart_mmio`/GPIO 地址范围不可缓存）。④ 给 DDR 桥加 **burst/line fill** 通路（赛题明确要求「优化总线突发传输效率」）：一次 line 取 32 B 而不是 8 次单拍。⑤ 边界测试：refill 与中断交叠、MMIO 旁路、store 不重复写、`rsp_error` 追溯、FENCE.I 后取新代码、随机插入等待。 |
| 交付物 | `icache.v` / `dcache.v` / 修改后的桥 + TB；CoreMark 四种配置对照表（见 §3.1）；`doc/Cache与突发_<date>.md` |
| 验收 | CoreMark 在 DDR 取指下 CRC 正确且性能提升；A/B/C/D 四行对照数据齐全；IRQ 32 项 + 两条 DDR 定向全 PASS；资源表更新（Cache 带来多少 LUT/DRM）；`git tag cache-ok` |
| 【闸门 G1】 | Day 11 结束 Cache 未稳定 → 【止损】回退到 `btb-ok` tag 交付，Cache 作为「已设计、未收敛」如实写入报告，绝不带着不确定的 Cache 去跑最终评测 |

### Day 12 —— 频率、时序与资源收敛

| 项 | 内容 |
|---|---|
| 动作 | ① 完整跑一遍 P&R + Report Timing，记录各时钟域 setup/hold 的 WNS/TNS/违例数，确认 WNS ≥ 0。② 记录关键路径起止点与逻辑原因（ID 分支/前递、加法树、地址译码、RAM 输出、跨模块高扇出）。③ **频率提升二选一**（只改一个变量）：(a) 提高 DDR IP 速率（750 → 1066 Mbps）使 `core_clk` 提升（当前 93.75 MHz → 约 133 MHz），需重新生成 DDR IP 并重跑全部 DDR 回归；(b) 保持现状只做时序收紧。**(c) 给 CPU 单开时钟域 + 异步桥——15 天内不推荐**。④ 产出分模块资源表：CPU 核（标 ISA 与乘法实现）、I/D Cache 与预测器、互连+桥+DDR、外设、调试核、整机，各自 LUT/FF/DRAM/DSP/频率。 |
| 交付物 | 时序报告 + 时钟拓扑图；频率扫描结果（设计目标频率 / 实际运行频率 / P&R 通过频率 / 板级压力验证频率**分列**）；分模块资源表 |
| 验收 | WNS ≥ 0、违例数 0；资源表每一行都有工具数字；给出「最高可达工作频率」的实测依据（未做频率扫描就不许写「最高」） |
| 风险 | 提 DDR 速率会让「DDR 训练完成 / 联仿 PASS / 顶层已切换 / 实板验证」四个事实全部需要重做 → 若 Day 12 中午前没跑通，立即放弃 (a)，按 93.75 MHz 定稿 |

### Day 13-14 —— AI 加速单元与应用闭环（高阶任务③）

| 项 | 内容 |
|---|---|
| 动作 | **A 档（保底，必须完成）**：① `ai_regs`（CTRL/STATUS/地址/尺寸/量化参数，busy 时拒绝 start）。② `mac_array` 8～16 路 INT8×INT8→INT32 累加 + `tensor_buffer` 分块缓存（片上 RAM）。③ `requant`（bias + 定点缩放 + 舍入 + 饱和，按输出通道配参）。④ 实现 1×1 与 3×3、stride 1/2 的直接卷积，**逐元素等于整数参考模型**（含负数、padding 用零点不为 0、通道尾部）。⑤ 应用闭环：一个真实可展示的小模型（如 28×28/32×32 输入的 2～3 层 INT8 CNN 分类），输入经 UART/传感器，输出经 GPIO/LED/串口显示；给出**延迟（P50/P95）与识别率**两组实测数字。⑥ 保留正确的软件回退路径并统计回退占比。<br>**B 档（冲刺，视 A 档进度）**：把 YOLOv5n 160×160 的前若干卷积层 + CPU 定点后处理做成单图推理演示，**明确标注「已实现层 / 未实现层 / 回退占比」**。 |
| 交付物 | AI 加速器 RTL + 逐元素对齐测试；整数参考模型脚本；应用 demo（视频/串口日志/波形）；`doc/AI加速实现_<date>.md`；模型资源与延迟表 |
| 验收 | 每个算子逐元素等于参考；加速器占用 LUT/DRAM/DSP/频率有数字；应用闭环能连续运行并给出帧号/结果/耗时；**「模型性能与资源」和「AI 处理效率（延迟+识别率）」两组数字都有** |
| 【止损】 | Day 14 中午若加速器仍未逐元素对齐 → 缩到最小可验证单元（1×1 卷积或矩阵向量乘）并如实说明未完成项。**绝不能声称「已移植 YOLO」而实际只跑了卷积微基准**——赛题文档明确反对这种口径，且一旦被追问会失分更多 |
| 备注 | 完整 YOLOv5n 整网 + 摄像头 + 显示在 15 天内对 2～3 人小队不现实。宁可交一个**真实跑通、数据完整**的小模型闭环，也不要交一个跑不通的大模型 |

### Day 14-15 —— ILA 波形分析、性能报告、冻结与提交

| 项 | 内容 |
|---|---|
| 动作 | ① **ILA 波形分析**（评分明确要求）：抓 CPU 执行 CoreMark 关键算法（`core_list_join` / `core_matrix_mul` / `core_state_transition`）时的波形，标注 PC、各级 valid/stall/flush、退休、访存握手、Cache miss、trap/irq，算出典型片段的 CPI 与停顿来源占比并配图。② **性能分析报告**：应用需求与实测效果 → 整体框架 → 五级流水与异常中断 → 存储/互连/加速器 → 模型与量化 → 完整资源表 → 时钟/CDC/时序 → CoreMark 与应用对照实验 → 局限与复现方法。③ **对照实验表**（评分要的）：CPU 软件 INT8 vs 硬件 INT8；无 Cache vs 2 路 Cache；无预测 vs BTB；8/16/32 MAC 参数比较；rv32i vs rv32im。④ **代码规范收尾**：删除调试残留、补模块注释与约束注释、统一命名；约束文件补 I/O 与时钟注释。⑤ **干净环境复现**：新目录重新 clone/解压 → 按 README 步骤构建 → 跑出与提交一致的 CoreMark 分数。⑥ `git tag submit-final`，打包 RTL/约束/软件/模型/脚本/日志/报告/演示录像。 |
| 交付物 | ILA 波形图 + 分析；性能分析报告；对照实验表；资源/时序汇总表；可复现构建说明；打包文件 |
| 验收 | 干净环境能复现 CoreMark 分数（证明不是偶然）；报告里每个数字都能对应到日志或工具报告；所有「未完成/未覆盖」项都如实列出 |
| 【最终闸门】 | **Day 15 只允许修影响正确性/交付的 bug，不新增任何架构功能。**功能冻结后不再动 RTL |

---

## 5. 里程碑与闸门汇总

| 里程碑 | 日期 | 通过条件 | 失败处置 |
|---|---|---|---|
| M0 基线冻结 | Day 2 末 | 全回归 PASS + bitstream + 板上自检 PASS + 基线资源/时序记录 | 若路径归位失败 → 用批量替换脚本的备选方案 |
| M1 UART 打通 | Day 4 末 | 串口能打印自己的字符串 | 切远程 FPGA 平台；或改用 tohost/ILA 证据链 |
| **M2 CoreMark 闭环** | **Day 5 末** | **CRC PASS + 单次 ≥10 s + 有分数** | **Day 6～7 全员只做 CoreMark，冻结其他一切** |
| M3 IPC 优化一 | Day 9 末 | rv32im + BTB 后 CoreMark 提升，回归不退化 | 回退到上一个 tag（`coremark-baseline`/`m-ok`） |
| M4 存储系统 | Day 11 末 | Cache 稳定，A/B/C/D 四行对照数据齐全 | 回退 `btb-ok`，Cache 如实记为未收敛 |
| M5 频率/资源 | Day 12 末 | WNS ≥ 0，资源表完整，频率有实测 | 放弃提 DDR 速率，按 93.75 MHz 定稿 |
| M6 AI 闭环 | Day 14 午 | 逐元素对齐 + 应用 demo + 延迟/识别率数字 | 缩到最小算子，如实披露 |
| **M7 冻结提交** | **Day 15** | 干净环境复现 + 全套材料打包 | 只修正确性 bug |

---

## 6. 风险登记册

| 风险 | 概率 | 影响 | 应对 |
|---|---|---|---|
| CoreMark 10 秒运行在你的 CPU 上要跑很久（软件乘法 + 无 Cache），一次迭代验证就要等数分钟 | 高 | 拖慢迭代速度 | 加 `-DITERATIONS=1` 的「快跑模式」用于功能验证，只在记录成绩时跑满 10 s；用 `tohost` 写 CRC 结果供脚本自动判定 |
| 路径归位打断 PDS 工程 / IP 初始化路径 | 中 | 高 | Day 1 先备份 `riscv-master.zip`；归位后立刻用 `run_ddr_selftest_fast.py` 验证启动链 |
| Cache/BTB 改坏中断排空逻辑 | 中 | 高 | 每完成一项立即跑 `sim/uart_irq/run_irq.py` 全套（32 项）+ 两条 DDR 定向；不通过不合并 |
| 无版本管理导致改坏无法回退 | 高（当前无 git） | 极高 | Day 1 必须 `git init`；每个里程碑打 tag；每天结束提交 |
| UART 物理引脚与官方 Pin Map 不符 | 中 | 高 | 核对官方原理图/Pin Map 后再写约束；不确定时优先远程平台 |
| DDR IP 速率/容量与实际板卡不符（AI 文档曾指出几何参数存疑） | 中 | 高 | Day 2 的 P&R 与实板自检就是验证；若容量异常，DDR 只当「够用即可」，CoreMark 走片内 |
| AI 整网做不完 | 高 | 中 | 按 A/B 档分层，A 档保底；绝不虚报 |
| 单人开发 | — | 高 | 见 §7 裁剪规则：砍掉 D-Cache、burst、M 扩展的除法、AI 的 B 档 |

---

## 7. 裁剪规则（人力/条件不足时怎么砍）

**只有 1 个人**：保留 A 线全部 + B 线的 GPIO / M 扩展 / I-Cache / BTB；**砍掉** D-Cache、burst、DDR 提速、AI 的 B 档；
AI 只做「一个逐元素对齐的 INT8 卷积单元 + 串口/GPIO 小模型闭环」。资源效率那项反而因为 LUT 少而好看。

**没有任何板卡**（只能用远程 FPGA 平台，或在决赛前一直纯仿真）：把「上板」相关动作替换为
① 远程平台完整构建 + 下载 + 串口抓结果（这是赛题官方认可的路径，务必记录平台名与操作步骤）；
② 每个里程碑都在该平台复跑一次，保证「仿真 PASS ≠ 板级可用」这一点被真实覆盖；
③ 传感器/显示类要求用平台可用的开关/LED/串口替代并如实标注。

**完全没有任何外设**：「融合一种或者多种传感器或者显示设备」这一条用
UART 输入帧 + GPIO/LED/串口文本输出 组成最小闭环，并在报告中明确写「以串口文本/GPIO 指示替代显示设备」，
不要写成「已实现图形显示」。

---

## 8. 必须立即交付的 8 份材料（提交清单）

1. 固定版本 RTL、约束（`temp_constraint_file.fdc` 含 UART/GPIO 引脚与时序注释）、软件、模型与导出脚本。
2. 构建与运行说明（干净环境可复现：工具版本、命令、迭代次数、编译参数）。
3. CoreMark v1.0 原始输出日志（**≥10 秒、CRC 正确、迭代次数明确**）。
4. CPU 内部框图、SoC 框图、AI 数据流图、内存布局图、时钟域图。
5. 分模块资源表（CPU 核 / Cache+预测器 / 互连+桥+DDR / 外设 / AI / 调试核 / 整机）。
6. 时序报告：各时钟域 WNS/TNS、关键路径说明、CDC 说明、频率分列。
7. **ILA 波形图 + 流水线效率分析**（CoreMark 关键算法片段的 CPI 与停顿来源）。
8. 对照实验表（软件 vs 硬件 INT8、无 Cache vs Cache、无预测 vs BTB、MAC 并行度、rv32i vs rv32im）+ 应用实测延迟/识别率。

---

## 9. 需要你确认的 3 件事（影响计划的关键变量）

1. **交付截止日**：AI 文档里写的是 2026-11-04 提交，但你说「15 天内完成」。请确认这 15 天的最后一天是哪一天，
   以及 11-04 是否是同一个截止点（若是，实际可用天数会更多，可以加上 D-Cache + AI 的 B 档）。
2. **队伍人数**：1 人 / 2 人 / 3 人？直接决定要不要启用 §7 的裁剪规则。
3. **板卡与外设**：手上有没有实体板卡（RK3568_MES2L100H / PG2L100H）？是否打算用远程 FPGA 实验平台？
   有没有可用的摄像头、显示屏、传感器、执行机构（电机/舵机/继电器）？
   —— 这一条决定高阶任务③能做到什么程度，也决定 UART 引脚约束这一步是「实板必须」还是「可后置」。

确认后我可以把这份计划细化到「每人每天的具体文件级改动」。
