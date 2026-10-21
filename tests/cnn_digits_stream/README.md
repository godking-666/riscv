# 视频流实时数字识别（digits10_int8_v1）

在队友已验证的 OV5640 + 预处理 + CNN 链上，做**实时循环**识别数字 0-9。

## 与 `tests/cnn_handwritten_photo` 的区别

| | handwritten_photo | **digits_stream（本目录）** |
|---|---|---|
| 流程 | 拍照一次 → 回传 1.8 MB 源帧 | **循环取帧，只回读 10 个分数** |
| 单帧耗时 | 约 3 分钟（UART 搬 1.8 MB） | UART 只传约 200 字节 |
| 用途 | 严格取证、离线对拍 | **实时演示** |

**硬件握手完全复用**（相机双缓冲 claim/wait/release、预处理、CNN 装载与运行、
identity 校验），只改了 `main()` 的顶层流程。

## 关键设计

* 模型只在启动时上传一次（6222 words ≈ 2 秒），之后**每帧不再传模型**。
* 每帧只回读 `CLASS` + 10 个分数 + `CNN_CYC/PP_CYC`，**图像数据不经过 UART**。
* 每帧结束必须 `cam_release` + `drain_unselected`，否则 claim 泄漏会让相机停止供帧。
* 保留 `D`/`d` 指令做单帧源图回传（调试用），因此 `export_group()` 仍被引用，
  不会触发 `-Werror` 的 unused-function。

## 指令

| 键 | 作用 |
|---|---|
| `G` | 开始（进入实时循环） |
| `Q` / `q` | 退出 |
| `D` | 回传**本帧**完整源图（1.8 MB，约 3 分钟） |
| `d` | 回传**本帧** RGB96（27 KB，约 3 秒） |
| 其它 | 忽略，继续取下一帧 |

## 构建

```powershell
Set-Location D:\riscv\RISCV
python -X utf8 tests/cnn_digits_stream/build.py --tag stream_20261020_a
```

产物：`tests/cnn_digits_stream/build/stream_20261020_a/program.bin`

## 上板

```powershell
python -X utf8 tools/cnn_digits_stream/run.py --port COM9 --log-dir sim/cnn/stream_20261020_a
```

## 串口输出格式（主机侧解析）

```text
STREAM_FRAME NO=17 CLS=3 CNN_CYC=XXXX PP_CYC=YYYY CONF=1234/567
```
`CONF` 是「最高分/次高分」的原始 int32 分数，比值越大越有把握 ——
可用作**拒识门限**（交接文档里「尚未实现拒识」的缺口，这里给出最简单的实现依据）。
