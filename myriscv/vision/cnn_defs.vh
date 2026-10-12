//======================================================================
// cnn_defs.vh -- LiteNet-3 常量（★ 由 tools/cnn_golden.py 自动生成，勿手改 ★）
//
// 单独成一个文件，是为了让「只想要常量」的模块（vision_cnn_top）也能 include，
// 而又不会把权重 ROM 的数据重复综合一份。
// 生成命令：py tools/cnn_golden.py --gen-weights rtl/cnn_weights.vh
//======================================================================

// 常量用 `define 宏而非 module 外 localparam：PDS ADS 编译器不识别文件级
// localparam（iverilog 接受），宏则两个工具链都支持。RTL 里无前缀引用即可。
`define CNN_CLASSES 100
`define CNN_FC_GROUPS 25
`define CNN_NONE_CLASS -1
`define CNN_IN_H    32
`define CNN_IN_W    32
`define CNN_NLAYER 10
`define CNN_CFG_N  13
`define CNN_F_KIND  0
`define CNN_F_CI    1
`define CNN_F_CO    2
`define CNN_F_K     3
`define CNN_F_IH    4
`define CNN_F_IW    5
`define CNN_F_OH    6
`define CNN_F_OW    7
`define CNN_F_TAPS  8
`define CNN_F_WBASE 9
`define CNN_F_BBASE 10
`define CNN_F_M     11
`define CNN_F_SH    12

// 容量（字/位宽），由网络结构算出；换结构重新生成即自动适配，RTL 不用改。
`define CNN_MEMA_WORDS 3072   // memA 深度（字）
`define CNN_MEMB_WORDS 12288   // memB 深度（字）
`define CNN_MEMA_AW 12      // memA 地址位宽
`define CNN_MEMB_AW 14      // memB 地址位宽
`define CNN_W_AW 16         // 卷积权重 ROM 地址位宽
`define CNN_B_AW 7         // bias ROM 地址位宽
`define CNN_FC_AW 12        // FC 权重 ROM 地址位宽
`define CNN_FC_IN 144        // FC 输入通道数（= GAP 输出通道）
`define CNN_GAP_SHIFT 4    // GAP 右移位数（=log2(h*w)，float mean 语义；8x8->6，4x4->4）

