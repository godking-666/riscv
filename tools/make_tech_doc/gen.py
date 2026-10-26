#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""生成本项目的参赛技术文档（DOCX），章节结构对齐参考文档《FPGA竞赛技术文档5.0》。

用法：
    <bundled python> tools/make_tech_doc/gen.py
输出：
    D:\\riscv\\RISCV\\技术文档_基于紫光同创RISC-V指令集CPU的智能视觉平台.docx
"""
import pathlib
import sys

from docx import Document
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml.ns import qn
from docx.shared import Pt, RGBColor, Cm

OUT = pathlib.Path(r'D:\riscv\RISCV\技术文档_基于紫光同创RISC-V指令集CPU的智能视觉平台.docx')

CN_FONT = '微软雅黑'
EN_FONT = 'Times New Roman'
MONO_FONT = 'Consolas'


# ---------------------------------------------------------------- 基础排版
def set_run_font(run, size=10.5, bold=False, cn=CN_FONT, en=EN_FONT, color=None):
    run.font.size = Pt(size)
    run.font.bold = bold
    run.font.name = en
    rpr = run._element.get_or_add_rPr()
    rf = rpr.find(qn('w:rFonts'))
    if rf is None:
        rf = rpr.makeelement(qn('w:rFonts'), {})
        rpr.append(rf)
    rf.set(qn('w:eastAsia'), cn)
    rf.set(qn('w:ascii'), en)
    rf.set(qn('w:hAnsi'), en)
    if color:
        run.font.color.rgb = RGBColor(*color)


def init_styles(doc):
    st = doc.styles['Normal']
    st.font.name = EN_FONT
    st.font.size = Pt(10.5)
    st.element.rPr.rFonts.set(qn('w:eastAsia'), CN_FONT)
    pf = st.paragraph_format
    pf.space_before = Pt(0)
    pf.space_after = Pt(3)
    pf.line_spacing = 1.25


def title(doc, text, size=20):
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    set_run_font(p.add_run(text), size=size, bold=True)
    p.paragraph_format.space_after = Pt(10)
    return p


def subtitle(doc, text, size=11):
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    set_run_font(p.add_run(text), size=size)
    p.paragraph_format.space_after = Pt(6)
    return p


def h1(doc, text):
    p = doc.add_paragraph()
    set_run_font(p.add_run(text), size=15, bold=True, color=(0x1F, 0x3B, 0x73))
    p.paragraph_format.space_before = Pt(16)
    p.paragraph_format.space_after = Pt(6)
    return p


def h2(doc, text):
    p = doc.add_paragraph()
    set_run_font(p.add_run(text), size=12.5, bold=True, color=(0x2E, 0x54, 0x94))
    p.paragraph_format.space_before = Pt(11)
    p.paragraph_format.space_after = Pt(4)
    return p


def h3(doc, text):
    p = doc.add_paragraph()
    set_run_font(p.add_run(text), size=11, bold=True)
    p.paragraph_format.space_before = Pt(8)
    p.paragraph_format.space_after = Pt(3)
    return p


def para(doc, text, indent=True, size=10.5):
    p = doc.add_paragraph()
    set_run_font(p.add_run(text), size=size)
    if indent:
        p.paragraph_format.first_line_indent = Pt(21)
    p.alignment = WD_ALIGN_PARAGRAPH.JUSTIFY
    return p


def bullet(doc, text, size=10.5):
    p = doc.add_paragraph(style='List Bullet')
    set_run_font(p.add_run(text), size=size)
    p.paragraph_format.space_after = Pt(2)
    return p


def code(doc, text):
    p = doc.add_paragraph()
    set_run_font(p.add_run(text), size=9, cn=MONO_FONT, en=MONO_FONT)
    p.paragraph_format.left_indent = Cm(0.8)
    p.paragraph_format.space_before = Pt(3)
    p.paragraph_format.space_after = Pt(3)
    pPr = p._element.get_or_add_pPr()
    shd = pPr.makeelement(qn('w:shd'), {qn('w:val'): 'clear', qn('w:fill'): 'F2F2F2'})
    pPr.append(shd)
    return p


def caption(doc, text):
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    set_run_font(p.add_run(text), size=9, bold=True, color=(0x40, 0x40, 0x40))
    p.paragraph_format.space_before = Pt(6)
    p.paragraph_format.space_after = Pt(2)
    return p


def table(doc, header, rows, widths=None, font=9):
    t = doc.add_table(rows=1, cols=len(header))
    t.style = 'Table Grid'
    t.alignment = WD_TABLE_ALIGNMENT.CENTER
    for i, h in enumerate(header):
        c = t.rows[0].cells[i]
        c.text = ''
        p = c.paragraphs[0]
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        set_run_font(p.add_run(str(h)), size=font, bold=True)
        pPr = c._element.get_or_add_tcPr()
        shd = pPr.makeelement(qn('w:shd'), {qn('w:val'): 'clear', qn('w:fill'): 'DCE6F1'})
        pPr.append(shd)
    for row in rows:
        cells = t.add_row().cells
        for i, v in enumerate(row):
            cells[i].text = ''
            p = cells[i].paragraphs[0]
            p.alignment = WD_ALIGN_PARAGRAPH.CENTER if i else WD_ALIGN_PARAGRAPH.LEFT
            set_run_font(p.add_run(str(v)), size=font)
    if widths:
        for r in t.rows:
            for i, w in enumerate(widths):
                r.cells[i].width = Cm(w)
    doc.add_paragraph()
    return t


def figure_ph(doc, text):
    """图片占位框（生成 docx 时没有截图，留出位置便于后续插图）。"""
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    set_run_font(p.add_run('［此处插入：%s］' % text), size=9, color=(0x99, 0x99, 0x99))
    p.paragraph_format.space_before = Pt(4)
    p.paragraph_format.space_after = Pt(4)


# ---------------------------------------------------------------- 正文
def build():
    doc = Document()
    init_styles(doc)
    # 页边距
    for s in doc.sections:
        s.left_margin = Cm(2.4)
        s.right_margin = Cm(2.4)
        s.top_margin = Cm(2.2)
        s.bottom_margin = Cm(2.2)

    # ======== 封面 / 标题 ========
    title(doc, '基于紫光同创 RISC-V 指令集 CPU 的\n智能视觉处理平台')
    subtitle(doc, '参赛队成员：（请填写姓名）')
    subtitle(doc, '硬件平台：盘古 MES2L676-200HP-MINI（PG2L200H-6FBB676）', size=9.5)
    subtitle(doc, '开发工具：Pango Design Suite 2022.2-SP6.4', size=9.5)
    subtitle(doc, '文档日期：2026-10-22', size=9.5)

    # ======== 第一部分 ========
    h1(doc, '第一部分 设计概述')

    h2(doc, '1.1 设计目的')
    para(doc, '本作品基于紫光同创 PG2L200H FPGA 自主设计并实现了一颗 32 位 RISC-V 处理器核，'
              '并围绕该处理器构建了一个完整的智能视觉处理 SoC 平台。处理器采用五级流水线、'
              'RV32I 指令集并扩展 Zmmul 乘法子集，运行于 93.75 MHz；SoC 集成了 DDR3 存储控制器、'
              'OV5640 图像传感器接口、HDMI 视频输出、INT8 卷积神经网络加速器以及 UART 固件加载器等模块。')
    para(doc, '本作品的目标是验证"自研 RISC-V 处理器 + 硬件 AI 加速 + 实时视频通路"这一完整技术栈'
              '在国产 FPGA 上的可行性：摄像头采集的图像经自研 CPU 调度、DDR3 缓存、硬件 CNN 推理后，'
              '推理结果通过硬件 OSD 叠加模块直接回显到 HDMI 画面上，形成一条从采集到显示的闭环链路，'
              '全程不依赖任何外部处理器。')

    h2(doc, '1.2 应用领域')
    para(doc, '本平台以自研 RISC-V 处理器为核心，具备通用计算与视觉推理双重能力，可应用于以下场景：')
    bullet(doc, '工业视觉检测：嵌入式产线缺陷检测、零件分类与尺寸测量，硬件 CNN 可在毫秒级完成单帧推理。')
    bullet(doc, '智能安防与边缘计算：本地完成目标识别，无需上传云端，兼顾实时性与数据隐私。')
    bullet(doc, '教学与研究：完整的自研 CPU + SoC + AI 加速链路，是计算机体系结构与嵌入式系统教学的理想实验平台。')
    bullet(doc, '国产化替代：全链路基于紫光同创 FPGA 与 RISC-V 开放指令集，为芯片与工具链国产化提供可行路径。')

    h2(doc, '1.3 主要技术特点')
    bullet(doc, '自主设计五级流水 RISC-V 处理器核，支持 RV32I 全部整数指令与 Zmmul 乘法扩展。')
    bullet(doc, '处理器主频 93.75 MHz，由 DDR3 控制器输出的 ddrphy_sysclk 供给，全系统单时钟域协同。')
    bullet(doc, 'DDR3 存储子系统带指令/数据行缓冲（line buffer + tag 匹配），显著降低了 DDR 单笔事务延迟对性能的影响。')
    bullet(doc, '完整的实时视频通路：OV5640 采集 → DDR3 双缓冲 → 异步 FIFO → HDMI 720p60 输出，全链路无压缩。')
    bullet(doc, '自研 INT8 卷积神经网络加速器，单次推理仅 6.26 ms，等效算力约 160 次/秒。')
    bullet(doc, '硬件 OSD 叠加模块，将推理类别直接叠加到 HDMI 画面上，不占用 CPU 与总线带宽。')
    bullet(doc, '13 项 64 位硬件性能计数器，为体系结构优化提供精确的量化依据。')

    h2(doc, '1.4 关键性能指标')
    h3(doc, '1.4.1 FPGA 资源占用情况')
    para(doc, '本作品使用盘古 MES2L676-200HP-MINI 开发板，板载 PG2L200H-6FBB676 器件，'
              '具有 159,800 个 LUT、319,600 个寄存器、415 个 DRM36K 块存储器与 740 个 APM 乘法单元。'
              '表 1 为本作品的资源消耗情况。')
    caption(doc, '表 1 板载资源消耗')
    table(doc,
          ['资源类型', '已使用', '总量', '占用率'],
          [['LUT（查找表）', '20,453', '159,800', '12.80%'],
           ['Register（寄存器）', '19,720', '319,600', '6.17%'],
           ['DRM36K（块存储器）', '27.5', '415', '6.63%'],
           ['APM（乘法单元）', '8', '740', '1.08%'],
           ['I/O 端口', '108', '400', '27.00%'],
           ['Latch（锁存器）', '0', '—', '—']],
          widths=[5.0, 3.2, 3.2, 3.2])
    para(doc, '分析：整体资源占用率较低（LUT 12.80%、寄存器 6.17%），为后续扩展预留了充足空间。'
              '块存储器占用 6.63% 主要来自 DDR3 控制器、图像缓冲 FIFO 与 CNN 的激活内存；'
              '乘法单元仅用 8 个（1.08%），其中 Zmmul 扩展使用一个 33×33 有符号乘法器 IP 覆盖全部四种乘法指令。')

    h3(doc, '1.4.2 CPU 跑分情况')
    para(doc, '本作品的 CPU 性能测试采用 CoreMark 1.0 标准程序，编译器为 GCC 15.2.0，'
              '编译选项为 -Os，目标架构 RV32I/ILP32，测试数据集大小 666。具体结果如表 2 所示。')
    caption(doc, '表 2 CPU 跑分测试情况')
    table(doc,
          ['测试项', '主频', '迭代次数', '运行时间(s)', '每秒迭代(iter/s)', 'CoreMark/MHz'],
          [['正式跑分', '93.75 MHz', '700', '10.814', '64.728812', '0.690441'],
           ['短跑交叉验证', '93.75 MHz', '60', '0.927', '64.723336', '0.690449'],
           ['历史基准（优化前）', '93.75 MHz', '60', '17.750', '3.380277', '0.036']],
          widths=[3.6, 2.4, 2.2, 2.6, 3.2, 2.6])
    para(doc, '分析：两次独立跑分（迭代数相差 11.7 倍）的分数仅相差 0.008%，测量结果高度可靠。'
              '与优化前的历史基准（0.036 CoreMark/MHz）相比，性能提升约 19.1 倍。'
              '该提升主要来自 DDR3 桥内引入的指令/数据行缓冲：优化前每条取指与每次访存都需经过'
              'DDR 单笔事务桥，延迟约为正常值的 50 倍；加入行缓冲后，命中时不再访问 DDR，'
              '彻底消除了这一瓶颈。')
    para(doc, 'CoreMark/MHz 为 0.690，处于"无分支预测、仅具备行缓冲的五级流水设计"的合理区间'
              '（业界参考：简单 FPGA 教学核约 0.3~0.6，带 BTB 与完整 Cache 的优化核约 1.0~1.5）。')

    h2(doc, '1.5 主要创新点')
    bullet(doc, '自研处理器 + 自研加速器的紧耦合设计：CNN 加速器以 MMIO 形式挂载在自研总线上，'
                'CPU 通过普通 load/store 指令即可驱动推理，架构清晰且易于扩展。')
    bullet(doc, '全链路无压缩的实时视频通路：1280×720 RGB565 数据以 27.8 MB/s 写入 DDR3、'
                '以 110.6 MB/s 读出送显示，仅占用 DDR3 带宽的 3.25%，画质不受传输环节影响。')
    bullet(doc, '硬件 OSD 叠加：识别结果由硬件直接合成到视频像素流中，不占用总线与 CPU，'
                '也不需修改总线互连结构，实现代价极低。')
    bullet(doc, 'UART 固件加载器 + 软重启回 Loader：固件通过串口写入 DDR3 后运行，'
                '运行结束可跳回 0x0 的 Loader 重新加载，使"烧一次位流、反复迭代固件"成为可能。')
    bullet(doc, '可复用的性能测量基础设施：13 项 64 位硬件计数器配合 CoreMark，'
                '使每一次 RTL 改动都能被精确量化（本次优化的 19.1 倍提升即由此定位）。')

    # ======== 第二部分 ========
    h1(doc, '第二部分 系统组成及功能说明')

    h2(doc, '2.1 整体介绍')
    para(doc, '本作品的 SoC 以自研 RISC-V 处理器为核心，通过数据总线连接 DDR3 存储控制器、'
              'UART、GPIO、摄像头控制器、图像预处理单元与 CNN 加速器；视频通路则独立于 CPU，'
              '由摄像头控制器写入 DDR3、显示控制器读出并送 HDMI 输出。整体结构如图 1 所示。')
    figure_ph(doc, '系统总体框图')
    para(doc, '系统上电后，FPGA 从外部配置器件加载位流；DDR3 控制器完成校准后释放 SoC 复位，'
              '处理器从 0x0 的 Boot ROM 开始执行 UART 固件加载器。上位机通过串口把固件写入 DDR3 '
              '并跳转执行，固件随后配置 OV5640、启动视频流、驱动 CNN 推理，并把结果通过串口与 OSD 输出。')

    h3(doc, '2.1.1 视频通路')
    para(doc, 'OV5640 图像传感器以 DVP 接口输出 1280×720 RGB565 数据，经摄像头控制器打包为 256 位'
              '突发写入 DDR3 双缓冲（帧 A 起始 0x0400000、帧 B 起始 0x0480000，单帧 1,843,200 字节）。'
              '显示侧由独立的帧读取器线性读出，经异步 FIFO 跨到 74.25 MHz 像素时钟域，'
              '转为 RGB888 后由 TMDS 编码器送 HDMI 输出 720p60。')
    para(doc, '该通路的带宽核算如下：相机写入 27.80 MB/s（222.4 Mbps），显示读出 110.59 MB/s（884.7 Mbps），'
              'DDR3 合计占用 138.39 MB/s，仅为其峰值 4.26 GB/s 的 3.25%。')

    h3(doc, '2.1.2 AI 加速通路')
    para(doc, '摄像头帧在 DDR3 中就绪后，CPU 启动预处理单元：把 1280×720 的源帧读出、'
              '缩放为 96×96 RGB888（27,648 字节）并写回 DDR3；随后 CNN 加速器把 96×96 RGB '
              '做 3×3 块平均降为 32×32 灰度，再经 4 层卷积（8/16/32 通道）+ 全局平均池化 + 全连接输出推理结果。')
    para(doc, '推理结果（类别与分数）由 CPU 通过 MMIO 读回，同时其中的"类别"字段直接引出到 OSD 叠加模块，'
              '由硬件合成到 HDMI 画面左上角，无需 CPU 参与显示。')

    h2(doc, '2.2 各模块介绍')

    h3(doc, '2.2.1 RISC-V 处理器核心')
    para(doc, '处理器采用经典五级流水线（取指 IF、译码 ID、执行 EX、访存 MEM、写回 WB），'
              '支持 RV32I 全部整数指令，并扩展 Zmmul 乘法子集（MUL/MULH/MULHSU/MULHU）。')
    para(doc, '乘法单元由一个带符号 33×33 乘法器 IP 实现，通过对操作数做符号扩展，'
              '可用同一硬件覆盖有符号与无符号四种乘法指令；结果为多周期输出（约 4 拍），'
              '通过独立的 mul_busy/mul_done 握手与流水线衔接，不阻塞其他指令。')
    para(doc, '为提升取指效率，前端实现了单 outstanding 请求跟踪与指令缓冲，'
              '并支持分支响应复用（branch response reuse）：当分支目标恰好等于正在飞行的取指地址时，'
              '直接复用该响应而不必重新发起请求，省去一个取指气泡。')
    para(doc, '处理器内置 13 项 64 位硬件性能计数器，可统计指令数、分支重定向次数、'
              '取指命中/缺失、访存停顿等事件，为体系结构优化提供量化依据。')

    h3(doc, '2.2.2 DDR3 存储子系统')
    para(doc, 'DDR3 控制器通过 Pango 的 DDRPHY IP 实现，参考时钟 125 MHz 差分输入，'
              '输出 ddrphy_sysclk 作为全系统 core_clk（93.75 MHz）。上电后需约 2~4 秒完成校准，'
              '校准完成由板上 C19 指示灯常亮指示。')
    para(doc, '为解决"每条取指/访存都经过 DDR 单笔事务桥、延迟极高"的瓶颈，'
              '在 CPU 侧 DDR 桥内实现了两组行缓冲：')
    code(doc, 'parameter integer INST_LINE_BUFFER_ENABLE = 1,\n'
              'parameter integer DATA_LINE_BUFFER_ENABLE = 1,')
    para(doc, '指令/数据行缓冲各自维护一套 tag 与有效位，命中时直接由同步 DRM 返回数据，'
              '不再发起 AXI 事务。实测该改动使 CoreMark 从 0.036 CoreMark/MHz 提升到 0.690 CoreMark/MHz，'
              '提升 19.1 倍，是本作品性能优化中最关键的一步。')

    h3(doc, '2.2.3 视频采集与显示')
    para(doc, '摄像头控制器负责 OV5640 的 SCCB 配置、DVP 数据捕获、CRC 校验与 DDR3 写入。'
              '为支持"CPU 读帧"与"显示读帧"并发，实现了 A/B 双缓冲：相机交替写入两个缓冲，'
              '每次开始写某缓冲时把其序号清零、写完才置为主序号，因此读取方总能选到已完成的帧。')
    para(doc, '显示侧帧读取器以 16 拍（512 字节）为突发，每帧固定读取 3600 个突发，'
              '读满即停、等待下一帧的 vs 起点，从而保证帧边界严格对齐显示器的垂直同步。')
    para(doc, '异步 FIFO 深度 64×256 位，写侧受 almost_full 反压，读侧每 16 个像素时钟取一个字，'
              '两侧速率自动匹配。')

    h3(doc, '2.2.4 INT8 卷积神经网络加速器')
    para(doc, '加速器为 INT8 定点实现，采用"灰度量化为 32×32 灰度 → 4 层卷积（通道 8/16/32，'
              '3×3 卷积核、步长 2）→ 全局平均池化 → 全连接"的结构。激活内存为两个 2 KiB 同步 bank，'
              '参数通过 MMIO 逐词写入。')
    para(doc, '引擎的时序器针对不同任务做了两套实现，二者的特征提取部分相同、仅全连接输出维度不同：')
    caption(doc, '表 3 两套 CNN 配置对比')
    table(doc,
          ['配置', '全连接输出', '参数词数', '用途'],
          [['digits10_int8_v1', '10 类分数', '6,222', '手写数字识别（10 类）'],
           ['geomdet_int8_v1', '3 类分数 + cx/cy/w/h', '6,123', '几何物体检测（ball/cube/cylinder + 边界框）']],
          widths=[4.6, 4.2, 3.0, 5.4])
    para(doc, '单次推理耗时 587,027 个时钟周期，即 6.26 ms（93.75 MHz），等效约 160 次/秒；'
              '预处理耗时 355,075 个周期，即 3.79 ms。整个推理链路周期抖动小于 0.5%。')

    h3(doc, '2.2.5 硬件 OSD 叠加')
    para(doc, 'OSD 模块插在 RGB888 数据与 TMDS 编码器之间，按像素坐标判断是否落在叠加区域内，'
              '查 8×8 字模（放大 8 倍）后替换该像素：笔画为白色，底色为原像素亮度的一半，'
              '因此在任何背景上都能清晰辨认。')
    para(doc, '识别类别直接取自 CNN 引擎的 prediction 输出，经两级寄存器同步到像素时钟域；'
              '该设计完全不需要新增 MMIO 地址，也不必修改总线互连结构。')

    h3(doc, '2.2.6 启动与固件加载')
    para(doc, '系统采用"位流 + 固件"两级加载：FPGA 位流固化在配置器件中，上电后自动加载；'
              '应用固件则由 Boot ROM 中的 UART 加载器通过串口写入 DDR3（起始地址 0x4000_0000），'
              '校验 CRC 后跳转执行。')
    para(doc, '固件运行结束时通过一条跳转到 0x0 的指令返回 Loader，使上位机可以直接再次下载固件，'
              '无需重新烧写位流；同时 CNN 模型在第二次加载时若校验通过即直接复用，'
              '省去 6,222 个参数的重复传输。')

    h2(doc, '2.3 关键问题与解决方案')
    para(doc, '在开发过程中遇到并解决了若干具有代表性的问题，记录如下。')

    h3(doc, '2.3.1 显示画面的三类缺陷')
    para(doc, '视频通路刚打通时，画面上出现了三类不同性质的显示缺陷，逐一分析与解决：')
    bullet(doc, '画面被切割成多个矩形区域：读侧帧边界自由运行，绕回点落在显示画面的任意位置，'
                '造成一条水平接缝，同时绕回时行内相位错位又产生一条垂直接缝。'
                '解决方法是把帧读取器的帧边界对齐到显示器的 vs 上升沿。')
    bullet(doc, '整幅图像右移形成一条竖线：帧切换时异步 FIFO 中残留约 13 个 256 位字，'
                '新帧到来后先被消费掉，导致整幅图水平偏移 16×13≈208 像素。'
                '解决方法是在帧起点同时冲刷 FIFO 两端指针。')
    bullet(doc, '屏幕左边缘周期性闪烁：帧起点原本取"第一个有效行的 de 上升沿"，'
                '此时 FIFO 刚被清空，前若干像素取不到数据而输出黑色，缺失量随 DDR 仲裁延迟变化。'
                '解决方法是将帧起点提前到 vs 上升沿，利用约 30 行的垂直消隐期（约 667 μs）预填 FIFO。')

    h3(doc, '2.3.2 相机自动曝光的低频抖动')
    para(doc, '将画面固定后仍能观察到约 1 Hz 的整体明暗抽动。对录制的画面做逐帧亮度统计与自相关分析，'
              '在 0.93 秒（1.07 Hz）处出现明确峰值，峰峰值约 6.5%，确认为 OV5640 自动曝光控制环的极限环。')
    para(doc, '根因是曝光上限设置过低：原配置上限为 369 行，仅占一帧（VTS=1224 行）的 30%，'
              '在照度不足时自动曝光顶到上限，只能依靠自动增益大幅抬升，'
              '形成"过冲—回调"的振荡。将曝光上限提升到 960 行（占一帧的 78%）后，'
              '自动曝光有充足调节余量，抖动显著减弱。')

    h3(doc, '2.3.3 分支预测（BTB）的尝试与回退')
    para(doc, '为继续提升 CPU 性能，曾尝试引入 64 项 BTB + 2 位饱和计数器的分支预测器。'
              '实现时把预测结果沿"在飞请求 → 指令缓冲 → IF/ID"逐级寄存，'
              '并新增了一条 ID 级误预测重定向路径。构建后零时序违例，但上板后处理器无法启动：'
              'DDR 校准指示灯正常点亮（该灯由 DDR IP 独立驱动），而 Boot ROM 的加载器对 PING 无任何应答。')
    para(doc, '分析认为：原设计有意把分支重定向推迟到 EX 级，以切断'
              '"ID 比较 → 取指地址 → 总线互连 → DDR 桥"这条跨级组合链；'
              '新增的 ID 级重定向会让同一条分支先被 ID 重定向、再被 EX 重定向，'
              '而取指路径中存在依赖"在飞请求地址等于分支目标"的响应复用优化，'
              '两次重定向会破坏该判断，进而打乱取指流。')
    para(doc, '由于该问题在硬件上难以定位，且 BTB 的预期收益（约 5%~15%）与布局布线非确定性'
              '带来的性能波动（实测约 2.5%）量级接近，最终决定回退该改动，'
              '将分支预测列为后续工作，需先在仿真环境中验证通过再上板。')

    # ======== 第三部分 ========
    h1(doc, '第三部分 完成情况及性能参数')

    h2(doc, '3.1 完成情况')
    caption(doc, '表 4 完成情况表')
    table(doc,
          ['赛题要求', '完成情况', '是否完成'],
          [['在紫光同创 FPGA 上移植并实现 RISC-V CPU 核心',
            '自主设计五级流水 RV32I 处理器，在 PG2L200H 上稳定运行于 93.75 MHz', '√'],
           ['支持基本 RISC-V 指令集',
            '支持 RV32I 全部整数指令，并扩展 Zmmul 乘法子集', '√'],
           ['实现最小工作系统（基本外设 + 存储器）',
            '实现 UART、GPIO 外设与完整 DDR3 存储子系统，具备固件加载能力', '√'],
           ['设计并实现至少一个自定义外设并与 CPU 集成',
            '自主实现摄像头控制器、图像预处理单元、CNN 加速器、OSD 叠加四个自定义外设', '√'],
           ['选择并实现一个特定应用场景验证系统功能',
            '实现"摄像头采集 → DDR3 缓存 → CNN 推理 → HDMI 显示"完整智能视觉应用', '√'],
           ['优化 CPU 实现以提高系统性能',
            '引入指令/数据行缓冲，CoreMark 由 0.036 提升至 0.690 CoreMark/MHz（19.1 倍）', '√'],
           ['AI 加速（高阶）',
            '自研 INT8 CNN 加速器，单次推理 6.26 ms，支持数字识别与几何物体检测两套模型', '√'],
           ['硬件 OSD 显示识别结果',
            '实现硬件像素级叠加，识别类别直接显示在 HDMI 画面上', '√']],
          widths=[6.2, 8.6, 2.2])

    h2(doc, '3.2 实现效果')
    bullet(doc, '实时视频通路：摄像头画面稳定显示在 HDMI 显示器上，分辨率 1280×720、刷新率 60 Hz，'
                '相机采集速率 15.08 帧/秒，连续 300 帧运行零失败。')
    bullet(doc, '硬件 OSD：屏幕左上角稳定显示识别类别数字，白字压暗底色，在不同背景下均清晰可辨。')
    bullet(doc, 'CoreMark 跑分：700 次迭代 10.814 秒完成，CoreMark/MHz 达 0.690，'
                '算法 CRC（crclist/crcmatrix/crcstate）全部与已验证基准一致。')
    bullet(doc, 'CNN 推理：单次推理 6.26 ms，周期抖动小于 0.5%，与上位机整数参考实现逐值一致。')
    bullet(doc, '固件迭代：支持串口加载与软重启回 Loader，单次固件迭代约 20 秒，无需重烧位流。')
    figure_ph(doc, 'HDMI 实时画面与 OSD 叠加效果')
    figure_ph(doc, 'CoreMark 跑分串口输出')

    h2(doc, '3.3 性能参数')

    h3(doc, '3.3.1 FPGA 资源占用情况')
    caption(doc, '表 5 各功能模块资源占用估算')
    table(doc,
          ['模块', '主要资源', '说明'],
          [['RISC-V 处理器核', '约 6,000 LUT / 4,000 寄存器', '五级流水、Zmmul 乘法器、性能计数器'],
           ['DDR3 存储子系统', '约 5,000 LUT / 27 DRM', 'DDRPHY、行缓冲、AXI 桥'],
           ['视频采集与显示', '约 4,500 LUT / 少量 DRM', '摄像头控制器、帧读取器、异步 FIFO、TMDS'],
           ['CNN 加速器', '约 4,000 LUT / 2 KiB×2 激活内存', 'INT8 卷积、池化、全连接'],
           ['OSD 叠加', '约 300 LUT', '字模查表与像素合成'],
           ['合计', '20,453 LUT / 19,720 寄存器 / 27.5 DRM', 'LUT 12.80%、寄存器 6.17%']],
          widths=[4.4, 6.4, 6.4])

    h3(doc, '3.3.2 CPU 跑分情况')
    para(doc, 'CoreMark 测试完整输出如下：')
    code(doc, '2K performance run parameters for coremark.\n'
              'CoreMark Size    : 666\n'
              'Total ticks      : 1013845279\n'
              'Total time (secs): 10\n'
              'Iterations       : 700\n'
              'Compiler version : GCC15.2.0\n'
              'Compiler flags   : -Os -march=rv32i -mabi=ilp32; no LTO\n'
              'seedcrc          : 0xe9f5\n'
              '[0]crclist       : 0xe714\n'
              '[0]crcmatrix     : 0x1fd7\n'
              '[0]crcstate      : 0x8e3a\n'
              '[0]crcfinal      : 0x65c5\n'
              'Correct operation validated.')
    para(doc, '换算：运行时间 = 1,013,845,279 / 93,750,000 = 10.814349643 秒；'
              '分数 = 700 / 10.814349643 = 64.728811545 次/秒；'
              '归一化 = 64.728811545 / 93.75 = 0.690440656 CoreMark/MHz。')

    h3(doc, '3.3.3 AI 推理性能')
    caption(doc, '表 6 AI 加速器性能参数')
    table(doc,
          ['指标', '数值', '说明'],
          [['模型类型', 'INT8 定点卷积网络', '4 层卷积 + 全局平均池化 + 全连接'],
           ['输入尺寸', '32×32 灰度', '由 96×96 RGB 做 3×3 块平均得到'],
           ['激活内存', '2 KiB × 2 bank', '双 bank 交替读写'],
           ['单次推理周期', '587,027', '抖动 < 0.5%'],
           ['单次推理耗时', '6.26 ms', '@ 93.75 MHz'],
           ['等效吞吐', '约 160 次/秒', '仅算推理，不含预处理'],
           ['预处理耗时', '355,075 周期 = 3.79 ms', '1280×720 → 96×96'],
           ['端到端帧率', '9.8 ~ 15 帧/秒', '受限于相机采集速率，非算力瓶颈']],
          widths=[4.6, 5.0, 7.6])

    h3(doc, '3.3.4 视频通路性能')
    caption(doc, '表 7 视频通路数据量与带宽')
    table(doc,
          ['项目', '数值', '备注'],
          [['分辨率 / 格式', '1280×720 RGB565', '16 bit/像素，无压缩'],
           ['单帧数据量', '1,843,200 B（14.75 Mbit）', ''],
           ['相机采集速率', '15.08 帧/秒', '由传感器配置决定'],
           ['相机→DDR3 写入', '27.80 MB/s（222.4 Mbps）', ''],
           ['DDR3→显示读出', '110.59 MB/s（884.7 Mbps）', '显示端 60 Hz 重复读取'],
           ['DDR3 总占用', '138.39 MB/s（1107 Mbps）', '占峰值 4.26 GB/s 的 3.25%'],
           ['HDMI 像素时钟', '74.25 MHz', '720p60，24 bit RGB888 直通']],
          widths=[4.6, 5.8, 6.8])

    # ======== 第四部分 ========
    h1(doc, '第四部分 总结')

    h2(doc, '4.1 可扩展之处')
    bullet(doc, '分支预测：BTB 分支预测器已实现并完成构建，但因上板后处理器无法启动而回退。'
                '后续应在仿真环境中定位并修复"ID 级与 EX 级双重定向"的时序冲突，再重新上板。')
    bullet(doc, '提高 AI 输入分辨率：当前 32×32 受限于 2 KiB 的激活内存。'
                '若把激活内存扩展到支持 96×96，可直接对整幅图像做检测，小目标识别能力将显著提升。')
    bullet(doc, 'Cache 容量扩展：目前为行缓冲结构，后续可实现 2 路组相联指令/数据 Cache，'
                '并配合 FENCE.I 指令，进一步提升访存性能。')
    bullet(doc, '检测结果可视化：CNN 的 geomdet 模型已输出 cx/cy/w/h 四个回归量，'
                '只需在 OSD 中增加矩形绘制逻辑，即可在画面上直接框出被识别的物体。')
    bullet(doc, '多类别扩展：现有加速器支持通过替换参数与全连接层维度切换任务，'
                '可扩展至更多类别或更大规模的分类网络。')

    h2(doc, '4.2 心得体会')
    para(doc, '（请各队员分别撰写，建议围绕以下方面展开：体系结构设计中"性能数字驱动决策"的体会、'
              '硬件调试与仿真验证分工的经验、跨时钟域与显示时序问题的排查过程、以及团队协作的感受。）')

    # ======== 第五部分 ========
    h1(doc, '第五部分 参考文献')
    refs = [
        '[1] 马颖颖. 基于 RISC-V 架构的 SoC 设计与实现[D]. 福州大学, 2022.',
        '[2] 李孟晗. 面向物联网应用的 RISC-V 架构 SoC 设计与实现[D]. 哈尔滨工业大学, 2023.',
        '[3] 周强. 基于 RISC-V 指令集架构的微控制器的设计与实现[D]. 电子科技大学, 2020.',
        '[4] 李维然. 基于 RISC-V 架构 SMP 处理器的多核 RTOS 优化研究与实现[D]. 北京邮电大学, 2023.',
        '[5] 常龙鑫, 虞致国, 钟啸宇, 等. 面向 RISC-V 处理器的高速浮点单元设计[J]. 电子器件, 2022, 45(06): 1289-1295.',
        '[6] 李青青. 基于 RISC-V 多核处理器的 Cache 及其一致性协议研究[D]. 江南大学, 2021.',
        '[7] Waterman A, Asanović K. The RISC-V Instruction Set Manual, Volume I: Unprivileged ISA. RISC-V Foundation, 2019.',
        '[8] CoreMark: An Industry Standard Benchmark for Embedded Processors. EEMBC, 2009.',
        '[9] Pango Design Suite 2022.2 用户指南. 紫光同创, 2022.',
        '[10] OV5640 CMOS Image Sensor Datasheet. OmniVision Technologies, 2015.',
    ]
    for r in refs:
        p = doc.add_paragraph()
        set_run_font(p.add_run(r), size=10)
        p.paragraph_format.space_after = Pt(2)

    # ======== 第六部分 ========
    h1(doc, '第六部分 附录')
    para(doc, '附录 A 关键源文件清单')
    caption(doc, '表 8 关键源文件')
    table(doc,
          ['路径', '说明'],
          [['myriscv/mycpu_sync.v', 'RISC-V 五级流水处理器核（含 Zmmul 乘法的多周期握手）'],
           ['myriscv/dual_sram_to_pango_ddr_bridge.v', 'CPU 侧 DDR3 桥（含指令/数据行缓冲）'],
           ['myriscv/camera_mmio.v', '摄像头控制器（SCCB 配置、DVP 捕获、A/B 双缓冲写 DDR3）'],
           ['myriscv/ov5640_config_rom.v', 'OV5640 寄存器配置表（含曝光/增益调参）'],
           ['myriscv/preprocess_mmio.v', '图像预处理（1280×720 → 96×96）'],
           ['myriscv/cnn_digits_engine.v', 'INT8 CNN 推理引擎'],
           ['myriscv/cnn_mmio.v', 'CNN 加速器 MMIO 接口'],
           ['myriscv/cnn_rgb96_gray32.v', '96×96 RGB → 32×32 灰度转换'],
           ['myriscv/video/display_frame_reader.v', '显示帧读取器（突发读 DDR3、帧边界对齐 vs）'],
           ['myriscv/video/async_fifo_256.v', '256 位异步 FIFO（跨时钟域）'],
           ['myriscv/video/hdmi_frame_out.v', 'HDMI 时序生成与像素串行化'],
           ['myriscv/video/osd_overlay.v', '硬件 OSD 叠加（字模查表与像素合成）'],
           ['myriscv/soc_ddr3_top.v', 'SoC 顶层（总线互连与外设集成）'],
           ['myriscv/board_top.v', '板级顶层（时钟、复位、引脚）'],
           ['tools/coremark_score/run.py', 'CoreMark 跑分工具'],
           ['tools/cnn_digits_stream/run.py', '视觉通路与 CNN 流式运行工具']],
          widths=[7.6, 9.4], font=8.5)

    para(doc, '附录 B 复现步骤')
    code(doc, '# 1) 烧写位流（每次上电必须重新烧写，FPGA 为 SRAM 工艺）\n'
              '#    generate_bitstream/board_top.sbit\n'
              '\n'
              '# 2) 跑 CoreMark 跑分（700 次迭代，约 13 秒）\n'
              'python -X utf8 tools/coremark_score/run.py --port COM7 --app performance_700\n'
              '\n'
              '# 3) 跑视觉通路 + CNN 流式推理\n'
              'python -X utf8 tools/cnn_digits_stream/run.py --port COM7 --frames 0 \\\n'
              '    --log-dir sim/cnn/stream_demo')

    doc.save(OUT)
    print('  ✓ 已生成：%s' % OUT)
    print('    %d 字节' % OUT.stat().st_size)
    return 0


if __name__ == '__main__':
    sys.exit(build())
