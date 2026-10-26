# 几何物品检测 CAM2 应用

由 `tests/cnn_handwritten_photo` 成功控制流程另建，使用训练模型 `85d3d177`（geomdet_int8_v1），保留原成功源码/固件和全部证据。CPU 只执行 ABI1 装载、相机所有权、PP/CNN 控制、UART 导出及 CRC，不执行软件 CNN 代替 FPGA。

固定应用 `build/geomdet_20261020_b/program.bin`，42660 byte，入口/装载地址 0x40000000，SHA256 `b921913d2362f7ace93a9670fa2ca520bb5601c8403e05cd569b1a7c25c743da`，CRC32 `9765ee42`。RISC-V RV32I 编译/指令静态审计及模型 word 逐字节嵌入检查通过。

模型头在构建目录生成，由已复核训练包生成全部 word（`MODEL_WORDS` 由 `model.json` 的 `load_words` 决定，旧模型为 6123），编译后 ELF 中 `model_words` 区域与装载流完全相同。源码不包含零占位参数，不改变 ABI/权重布局/类别顺序。Loader 仍从原 ROM 驻留执行，经 UART 下载新 BIN；不替换 ROM/RAM IP、生成新位流或从数据 RAM 执行。

> **换模型**：`build.py --model <模型包目录>` 即可重建固件，字数与 CRC 自动跟随。但模型必须与位流匹配：
> 当前位流只认 8/16/32 的 6123 word 模型；宽模型（16/32/64，23755 word）需先综合新位流。

新应用 banner 为 `CNN_GEOMDET_APP=1`，协议 CN03，7 输出（3 类分数 + cx,cy,w,h）。一次运行领取 A 帧、STOP/排空、PP、CNN，等待 PC 命令 `d` 快速导出 RGB96 或 `D` 完整同源 RGB96+720p；两模式均保持源帧 CPU 所有权到导出完成，再释放所有发布帧，读取 7 个 signed32 分数并核 argmax（仅前 3 类）。每次新运行需 KEY0 回到 Loader。

操作命令、标签/session 记录、快速模式边界及只读复核见 [PC 入口](../../tools/geomdet_photo/README.md)。本应用尚无新模型实板 PASS。

仅在后续明确修改新源码时用新 tag 构建，不覆盖已封存 b 目录：

```powershell
python -X utf8 tests/geomdet_photo/build.py --tag your_new_tag
```

源码/API 变更后需绑定新 PC manifest、重新做相关检查与封存，不能把重建 BIN 当作已验收的原固定文件。离线 native 自测在 `sim/geomdet/selfcheck.py`，验证 PC 解析与板端字节流完全对齐（不含真实 CPU/HDL/物理 DDR）。
