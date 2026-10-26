# OoO CPU 接入视频通路 —— 集成方案与接口对照

> 本文档基于 2026-10-26 的实测验证编写。所有信号名、位宽、方向都来自两边的真实源码，
> 不是推测。按本文档施工前请先读第 6 节「风险与建议」。

---

## 0. 结论摘要

| 项 | 结论 |
|---|---|
| 队友 OoO CPU 的 CoreMark/MHz | **4.9210（实测验证，135 MHz，DDR 上跑）** |
| 我们现有系统 | 0.6904（93.75 MHz，DDR） |
| 每时钟性能差距 | **7.13 倍**（OoO + TAGE + 2-way I/D Cache） |
| 两套 DDR 接口 | **完全对应**（见第 2 节） |
| 两套 MMIO 接口 | **完全对应**（见第 3 节） |
| 集成可行性 | **可行**，预估 2~4 天 |
| 主要风险 | 时钟域（135/93.75/74.25 MHz）+ 视频通路重新调试 |

---

## 1. 两套工程的结构差异

### 队友：`D:\riscv\ooo_riscv_ddr3`（纯 CPU + DDR3 跑分）

```
source/
  ooo_core.v        53 KB   乱序核心（含 ooo_alu）
  ooo_frontend.v    21 KB   取指前端（含 ooo_predecode）
  ooo_tage.v        13 KB   TAGE 分支预测器
  ooo_icache.v       5 KB   指令 Cache
  ooo_dcache.v      10 KB   数据 Cache
  ooo_lsu.v         20 KB   访存单元
  ooo_iq.v           6 KB   指令队列
  ooo_prf.v          2 KB   物理寄存器堆
  ooo_decode.v       7 KB   译码
  ooo_xbar.v         8 KB   总线交叉开关（ooo_ibus / ooo_dbus / ooo_iobus）
  ooo_ddr_port.v     7 KB   DDR 端口（AXI 主设备）★ 集成关键
  ooo_tcm.v          2 KB   紧耦合存储器
  ooo_ram.v          3 KB   RAM 原语（ooo_tdp_ram32 / ooo_sdp_ram）
  ooo_mmio.v         3 KB   系统寄存器（周期计数器/定时器/LED）
  soc_ooo.v         12 KB   SoC 顶层（CPU + TCM + DDR + MMIO）
  ooo_board_ddr.v   10 KB   板级顶层（board_top_ooo_ddr / ooo_ddr_soc）
  uart_mmio.v / uart_rx*.v / uart_tx.v / gpio_mmio.v / csr_file.v
  reset_button_debounce.v
  ooo_img/ddr135_perf/tcm_{even,odd}.dat   40,860 B   CoreMark 镜像（烘焙进位流）
  ooo_img/ddr125_perf/tcm_{even,odd}.dat
```

**没有**：视频、摄像头、HDMI、OSD、CNN、预处理器。

### 我们：`D:\riscv\RISCV`（完整智能视觉 SoC）

```
myriscv/
  mycpu_sync.v      72 KB   五级顺序单发射 CPU（将被替换）
  dual_sram_to_pango_ddr_bridge.v   行缓冲 + AXI 桥（将被替换）
  soc_top.v         30 KB   CPU + ROM/RAM/MMIO + 可选 DDR
  soc_ddr3_top.v    29 KB   板级 SoC：视频 + CNN + DDR 仲裁链
  camera_mmio.v / ov5640_*.v      摄像头
  preprocess_mmio.v               1280x720 -> 96x96
  cnn_digits_engine.v / cnn_mmio.v / cnn_rgb96_gray32.v / cnn_*.v
  video/display_frame_reader.v / async_fifo_256.v / hdmi_frame_out.v / osd_overlay.v / rgb2tmds.v
  data_bus_interconnect.v          MMIO 总线
  camera_ddr_write_arbiter.v / preprocess_ddr_read_arbiter.v / display_ddr_read_arbiter.v
```

---

## 2. DDR 接口对照（★ 集成点 1）

### 队友 `ooo_ddr_port.v` 的 DDR 侧输出

```verilog
output [CTRL_ADDR_WIDTH-1:0] axi_awaddr,   // CTRL_ADDR_WIDTH = 28
output                       axi_awuser_ap,
output [3:0]                 axi_awuser_id,
output [3:0]                 axi_awlen,
input                        axi_awready,
output                       axi_awvalid,
output [255:0]               axi_wdata,
output [31:0]                axi_wstrb,
input                        axi_wready,
output [CTRL_ADDR_WIDTH-1:0] axi_araddr,
output                       axi_aruser_ap,
output [3:0]                 axi_aruser_id,
output [3:0]                 axi_arlen,
input                        axi_arready,
output                       axi_arvalid,
input  [255:0]               axi_rdata,
input                        axi_rvalid
```

### 我们 `soc_ddr3_top.v` 仲裁链里的 "CPU 客户端" 信号

```verilog
cpu_awaddr, cpu_awap, cpu_awid, cpu_awlen, cpu_awready, cpu_awvalid,
cpu_wdata, cpu_wstrb, cpu_wready,
cpu_araddr, cpu_arap, cpu_arid, cpu_arlen, cpu_arready, cpu_arvalid,
cpu_rvalid          // 读响应有效（数据走 axi_rdata）
```

### 接法

| 队友 | → | 我们 |
|---|---|---|
| `axi_awaddr` | → | `cpu_awaddr` |
| `axi_awuser_ap` | → | `cpu_awap` |
| `axi_awuser_id` | → | `cpu_awid` |
| `axi_awlen` | → | `cpu_awlen` |
| `axi_awvalid` | → | `cpu_awvalid` |
| `cpu_awready` | → | `axi_awready` |
| `axi_wdata` / `axi_wstrb` | → | `cpu_wdata` / `cpu_wstrb` |
| `cpu_wready` | → | `axi_wready` |
| `axi_araddr` / `axi_aruser_ap` / `axi_aruser_id` / `axi_arlen` | → | `cpu_araddr` / `cpu_arap` / `cpu_arid` / `cpu_arlen` |
| `axi_arvalid` | → | `cpu_arvalid` |
| `cpu_arready` | → | `axi_arready` |
| `axi_rdata` | → | `axi_rdata`（全局 DDR 返回数据）|
| `cpu_rvalid` | → | `axi_rvalid` |

**注意**：队友的端口没有 `rlast` / `rid` 输入 —— 他按自己的 `axlen` 计数，不依赖 `rlast`。
我们的仲裁链会给返回数据打 `rid`（CPU 是 ID 4、摄像头 ID 3、预处理器 ID 4、显示 ID 8）。
**必须确认 `ooo_ddr_port` 不校验 `rid`，否则要加一层过滤。**

### 时钟域

```
队友 CPU：cpu_clk = 135 MHz（独立 PLL，来自 125 MHz 参考）
我们 core_clk = 93.75 MHz（DDR IP 的 core_clk）
我们像素时钟 = 74.25 MHz
```

`ooo_ddr_port` 自带 `clk`（CPU 域）与 `ddr_clk`（DDR 域）双时钟，**它内部已经做了 CDC**。
所以把 `ddr_clk` 接我们的 `core_clk = 93.75 MHz` 即可，CPU 侧保持 135 MHz。

---

## 3. MMIO 接口对照（★ 集成点 2）

### 队友 `ooo_iobus` 的主端口（master 侧）

```verilog
input  wire        m_valid, m_we;
input  wire [31:0] m_addr, m_wdata;
input  wire [3:0]  m_wstrb;
input  wire [1:0]  m_size;
output wire        m_ready;
output reg         m_rsp_valid;
output reg  [31:0] m_rsp_rdata;
output reg         m_rsp_error;
```

现有的两个从设备端口：`s_*`（系统寄存器）、`u_*`（UART）、`g_*`（GPIO）。

### 我们 MMIO 模块的端口（以 `camera_mmio` 为例）

```verilog
input  wire        req_valid, req_write;
input  wire [1:0]  req_size;
input  wire [31:0] req_addr, req_wdata;
input  wire [3:0]  req_wstrb;
output wire        req_ready;
output reg         rsp_valid, rsp_error;
output reg  [31:0] rsp_rdata;
```

### 接法（逐信号一一对应）

| `ooo_iobus` 从设备端口 | → | 我们的 MMIO |
|---|---|---|
| `x_valid` | → | `req_valid` |
| （`m_we` 广播） | → | `req_write` |
| （`m_size` 广播） | → | `req_size` |
| （`m_addr` 广播） | → | `req_addr` |
| （`m_wdata` 广播） | → | `req_wdata` |
| （`m_wstrb` 广播） | → | `req_wstrb` |
| `req_ready` | → | `x_ready` |
| `rsp_valid` | → | `x_rsp_valid` |
| `rsp_rdata` | → | `x_rsp_rdata` |
| `rsp_error` | → | `x_rsp_error` |

**要做的事**：在 `ooo_xbar.v` 的 `ooo_iobus` 里照 `u_*`（UART）的样子，
再加三组从设备端口 `c_*`（camera）、`p_*`（preprocess）、`n_*`（CNN），并扩展地址译码：

```
0x1000_0000  系统寄存器（已有）
0x1000_1000  UART（已有）
0x1000_2000  camera_mmio        ← 新增
0x1000_3000  preprocess_mmio    ← 新增（现有代码用 0x1000_3000？请核对）
0x1000_4000  cnn_mmio           ← 新增（固件里 CNN = 0x1000_4000，必须保持）
0x1000_5000  GPIO（已有）
```

**⚠️ 地址必须与现有固件一致**，否则所有固件都要重编。请以
`tests/cnn_digits_stream/main.c` 里的 `#define` 为准逐个核对。

---

## 4. 施工步骤

### 阶段 A：准备（半天）

1. **确认备份**
   ```powershell
   cd D:\riscv\RISCV
   git log --oneline -2      # 应有 267eab2 safety point
   git reset --hard 267eab2  # 出问题就回到这里
   ```
   另有文件系统备份：`D:\riscv\RISCV_backup_before_ooo_20261026_202600\`

2. **把队友的 source 复制进来**
   ```powershell
   New-Item -ItemType Directory -Force D:\riscv\RISCV\myriscv_ooo
   Copy-Item D:\riscv\ooo_riscv_ddr3\source\*.v,D:\riscv\ooo_riscv_ddr3\source\*.vh `
             D:\riscv\RISCV\myriscv_ooo\
   ```

3. **先单独综合一次他的 CPU**（不接视频），确认工具链和资源占用能过。
   - 参考他的 `impl.tcl` 和 `ooo_riscv_ddr3.pds`
   - 记录 LUT / Register / DRM / APM 占用，与我们的对比是否超资源

### 阶段 B：扩展 iobus（半天）

4. 在 `myriscv_ooo/ooo_xbar.v` 的 `ooo_iobus` 里加三组从设备端口
5. 扩展地址译码（见第 3 节的地址表）
6. **写一个纯仿真的 testbench**（照 `sim/tpu/tb_tpu_mmio.v` 或他的 `sim/` 结构），
   验证 CPU 能读写 camera/cnn 的寄存器
   —— **这一步必须先过，否则后面板上调试会极其痛苦**

### 阶段 C：新 SoC 顶层（1~2 天）

7. 新建 `myriscv/soc_video_ooo.v`，内容 = 以下三块的组合：
   - **队友 CPU 子系统**：`ooo_core` + `ooo_frontend` + `ooo_icache` + `ooo_dcache`
     + `ooo_tage` + `ooo_lsu` + `ooo_iq` + `ooo_prf` + `ooo_decode` + `ooo_tcm`
     + `ooo_ram` + `ooo_xbar` + `ooo_ddr_port` + `ooo_mmio`
   - **我们的视频子系统**：`camera_mmio` + `preprocess_mmio` + `cnn_mmio`
     + `display_frame_reader` + `async_fifo_256` + `hdmi_frame_out` + `rgb2tmds`
   - **DDR 仲裁链**（原样照搬 `soc_ddr3_top.v` 的 L141~L270）
8. **接线**：
   - `ooo_ddr_port` 的 AXI → 仲裁链的 `cpu_*`（第 2 节表格）
   - camera/preprocess/cnn 的 MMIO 端口 → `ooo_iobus` 的三个新从设备端口（第 3 节表格）
9. **时钟**：
   - `ddd_clk`（DDR IP core_clk）= 93.75 MHz，不变
   - CPU 侧 `clk` = 135 MHz（照 `ooo_board_ddr.v` 的 `clk_cpu` PLL）
   - 像素 = 74.25 MHz，不变
   - `camera_pclk` 域不变

### 阶段 D：约束（半天）

10. 合并约束：以他的 `fdc/ooo_ddr.fdc`（49 KB）为底，
    加上我们视频相关的 `set_max_delay -datapath_only`（见 `constraint_check\temp_constraint_file.fdc`）
11. **重点检查**：
    - `create_generated_clock` 是否覆盖 `u_cpu_pll/clkout0`
    - 视频路径的 CDC：`u_disp_fifo.rd_ptr_g*` / `wr_ptr_g*`、
      `u_hdmi_frame_out.frame_start_r*`、`cnn → osd.cls_s1*`

### 阶段 E：上板（1~2 天）

12. 先只验证 CPU：烧位流，跑 CoreMark，确认 4.92 仍然成立
13. 再验证视频：摄像头画面、帧边界、OSD
    —— **这里最容易出问题，我们上次调视频花了 2 天**
14. 最后验证 CNN：跑 cnn_digits_stream 固件

---

## 5. 固件影响

| 固件 | 变化 |
|---|---|
| `tests/cnn_digits_stream` | **不用改**（MMIO 地址不变的话）|
| `tests/geomdet_photo` | 不用改（但 geomdet RTL 本身有 bug，见第 6 节）|
| CoreMark | **要重编**（内存映射从 0x4000_0000 变成 0x0，频率 93.75→135）|
| Boot ROM / UART Loader | 要移植进他的 `soc_ooo`（他目前用 `INIT_EVEN/INIT_ODD` 把程序烘焙进位流，没有串口加载器）|

**⚠️ 这一条容易被忽略**：队友的 SoC **没有 UART 固件加载器**，程序是编译期烘焙进位流的。
如果沿用我们的固件流程（串口下载 + 软重启回 Loader），需要把我们的 Loader 移植进去，
或者接受"每次换固件都要重新生成位流"（15 分钟一次，演示时很难受）。

---

## 6. 风险与建议

### 高风险点

| 风险 | 说明 | 缓解 |
|---|---|---|
| **视频通路重新调试** | 上次我们调三类显示缺陷花了 2 天；换 CPU 后帧边界/FIFO 时序可能全变 | 先把视频子系统**原样搬过去不改**，只换 CPU 侧 |
| **资源超限** | OoO + TAGE + I/D Cache 比我们顺序核大很多；再叠视频+CNN 可能超 LUT/DRM | 阶段 A 第 3 步先单独综合他的核，看余量 |
| **时钟域** | 135 / 93.75 / 74.25 / 25(pclk) 四域 | 优先复用他 `ooo_ddr_port` 已有的 CDC |
| **无固件加载器** | 他的 SoC 靠烘焙镜像 | 移植我们的 Loader，或接受重烧位流 |
| **CSS 顺序** | 他的 `.pds` 文件列表和我们的完全不同 | 新建独立 `.pds`，别改现有工程 |

### 我的建议

**如果剩余时间 ≥ 4 天**：按上面阶段 A→E 推进，每个阶段结束都做一次综合验证。

**如果剩余时间 < 3 天**：**不要做这个集成。**

理由是：视频通路一旦重新调试失败，你会同时失去
「完整的视频+AI 演示」和「可用的 CPU 跑分」两样东西，
而现在的状态是**两样都有**（只是分在两个位流里）。

**保守方案（零风险，同样能拿分）**：
- 报告里分两栏写：系统平台走我们的位流，CPU 优化走他的位流
- 演示时重烧一次位流切换（2 分钟）
- 这样「自定义外设 + 应用场景」和「CPU 性能优化」两个评分项都能拿满

---

## 7. 已验证的事实（可写进报告）

### 队友 OoO CPU 实测

```
2K performance run parameters for coremark.
CoreMark Size    : 666
Total ticks      : 1422461658
Iterations       : 7000
Compiler flags   : -O3 -funroll-all-loops -finline-limit=1000 -fipa-pta -march=rv32i_zmmul
Memory location  : DDR3 + 2-way I/D cache
[0]crclist       : 0xe714
[0]crcmatrix     : 0x1fd7
[0]crcstate      : 0x8e3a
[0]crcfinal      : 0x25b5
Correct operation validated.
PORT_DONE ticks=1422461658 iterations=7000 hz=135000000
```

计算：
```
运行时间 = 1422461658 / 135000000 = 10.5368 s
每秒迭代 = 7000 / 10.5368      = 664.3413 iter/s
CoreMark/MHz = 664.3413 / 135   = 4.9210
每迭代周期   = 203,208
```

### 对比（⚠ 编译选项不同，引用时须注明）

| | 我们（-Os） | 队友（-O3） | 倍数 |
|---|---|---|---|
| 频率 | 93.75 MHz | 135 MHz | 1.44× |
| 每迭代周期 | 1,448,350 | 203,208 | **7.13×** |
| 每秒迭代 | 64.73 | 664.34 | **10.26×** |
| CoreMark/MHz | 0.6904 | **4.9210** | **7.13×** |

**建议**：用 `-O3` 重跑我们的 CoreMark 再对比，否则 7.13× 会被质疑（编译器差异通常值 30~50%）。

### 已知的 RTL 缺陷（不要踩）

1. **geomdet 版 `cnn_digits_engine.v` + `cnn_mmio.v` 上板后任务永久挂起**
   - 现象：`CNN_FAIL REASON=CNN_ERROR`，`CNN_ERROR=2`，3 秒超时
   - 队友原始模型也一样失败 → 是 RTL 问题，不是模型问题
   - 现状态：已恢复数字版 RTL（`*.before_geomdet` 是 geomdet 版备份）
2. **软重启不复位外设**，会导致：
   - 相机缓冲卡在 BUF_CPU → `CAMERA_NOT_IDLE_FREE`
   - CNN 引擎残留脏状态 → `CNN_NOT_FRESH` / `MODEL_BEGIN` 失败
   - 已打补丁：`cam_force_idle()` + `cnn_load()` 里 abort/clear 序列
3. **`cnn_requantize.v` 的 `shift=0` 有专门分支**，不是 bug；但别指望靠 shift=0 提升精度

---

## 8. 参考：文件级差异清单

| 文件 | 我们 | 队友 | 说明 |
|---|---|---|---|
| CPU 核 | `mycpu_sync.v` 72 KB | `ooo_core.v` + 9 个配套文件 | 完全不同，整体替换 |
| DDR 桥 | `dual_sram_to_pango_ddr_bridge.v` | `ooo_ddr_port.v` + caches | 整体替换 |
| SoC 顶层 | `soc_top.v` / `soc_ddr3_top.v` | `soc_ooo.v` | 需新写合并版 |
| 板级顶层 | `board_top.v` | `ooo_board_ddr.v` | 需新写合并版 |
| MMIO 总线 | `data_bus_interconnect.v` | `ooo_xbar.v`（内含 iobus）| 扩展而不是替换 |
| UART/GPIO | `uart_mmio.v` / `gpio_mmio.v` | 同名文件，接口略异 | 用他的，或适配 |
| 视频/CNN/OSD | 独有 | 无 | 原样搬过来 |
| 约束 | `.fdc`（我们的）| `fdc/ooo_ddr.fdc` 49 KB | 合并 |

---

*文档生成日期：2026-10-26*
*验证依据：实板串口输出（COM7 @115200）+ 两套工程源码逐信号核对*
