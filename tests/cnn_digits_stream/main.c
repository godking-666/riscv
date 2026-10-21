
#include <stdint.h>
#include "pp01_wire.h"


#ifdef PP_NATIVE
uint32_t diag_read(uint32_t address);
void diag_write(uint32_t address, uint32_t value);
void diag_halt(void) __attribute__((noreturn));
#define R32(a) diag_read(a)
#define W32(a,v) diag_write(a,v)
#else
#define R32(a) (*(volatile uint32_t *)(a))
#define W32(a,v) (*(volatile uint32_t *)(a)=(v))
#endif

#define CAM   0x10002000u
#define PP    0x10003000u
#define UART  0x10001000u
#define CYCLE 0x10000008u
#define TEST_STATUS 0x10000010u
#define HZ    93750000u

#define SRC_A 0x41000000u
#define SRC_B 0x41200000u
#define SRC_BYTES 1843200u
#define SRC_PIXELS 921600u
#define SRC_BEATS 57600u
#define OUT_BASE 0x42000000u
#define OUT_BYTES 27648u
#define OUT_PIXELS 9216u
#define OUT_BEATS 864u
#define OUT_SIZE 0x00600060u
#define CHUNK 1024u
#define GROUPS 1u
#define MAX_LEDGER 16u


#define TX_LIMIT       (5ull * HZ)    
#define ACK_LIMIT      (5ull * HZ)    
#define CMD_LIMIT      (30ull * HZ)   
#define CMD_LIMIT_USER (600ull * HZ)  
#define CONFIG_LIMIT   (5ull * HZ)    
#define READY_LIMIT    (5ull * HZ)    
#define PP_LIMIT       (5ull * HZ)    
#define CPU_LIMIT      (20ull * HZ)   


#define CAM_CTRL        0x04u
#define CAM_STATUS      0x08u
#define CAM_FRAME_BASE  0x0cu
#define CAM_FRAME_BYTES 0x10u
#define CAM_FRAME_SEQ   0x14u
#define CAM_PIXELS      0x18u
#define CAM_ERROR       0x1cu
#define CAM_SENSOR      0x20u
#define CAM_BEATS       0x24u
#define CAM_CRC         0x28u
#define CAM_SELECT      0x2cu
#define CAM_BUFSTATE    0x30u
#define CAM_GLOBAL_SEQ  0x34u
#define CAM_TOKEN       0x38u
#define CAM_OK_ID       0x43414d02u

#define CAM_CMD_STREAM_START 0x08u
#define CAM_CMD_STREAM_STOP  0x10u
#define CAM_CMD_CLAIM        0x20u
#define CAM_CMD_RELEASE      0x40u


#define PP_ID         0x00u
#define PP_CTRL       0x04u
#define PP_STATUS     0x08u
#define PP_SOURCE_BUF 0x0cu
#define PP_EXPECTED   0x10u
#define PP_RESULT_SEQ 0x14u
#define PP_OUT_BASE   0x18u
#define PP_OUT_BYTES  0x1cu
#define PP_OUT_CRC    0x20u
#define PP_ERROR      0x24u
#define PP_READS      0x28u
#define PP_WRITES     0x2cu
#define PP_PRODUCED   0x30u
#define PP_CYCLES     0x34u
#define PP_OUT_SIZE   0x38u
#define PP_RESULT_BUF 0x3cu
#define PP_OK_ID      0x50525001u

#define UART_TX_DATA 0x00u
#define UART_RX_DATA 0x04u
#define UART_STATUS  0x08u


volatile uint32_t boot_cookie = 0x50505531u; 
static uint8_t payload[CHUNK];
static uint8_t packet[32];
static uint8_t failing;
static uint64_t elapsed, previous_tick, program_start;

static uint32_t group_no, cur_buf, cur_seq, cur_pp_crc;
static uint32_t ledger_seq[MAX_LEDGER], ledger_buf[MAX_LEDGER];
static uint32_t ledger_n, target_claims, discard_claims, last_discard;

// ★ 软重启回 Loader。
// 背景：KEY0 按下后 DDR 不会重新校准（实测 C19 不亮），于是
//       soc_resetn = ddr_init_done && pll_lock 一直不放，CPU 被按在复位里，
//       Loader 也就不响应 PING —— 每测一次都得重烧位流。
//       跳回 0x0（ROM 里的 Loader）是纯软件路径，不依赖 DDR 重新校准，
//       让"烧一次位流 → 反复下载固件运行"成为可能。
static void reboot_to_loader(void) __attribute__((noreturn));
static void reboot_to_loader(void)
{
#ifndef PP_NATIVE
    // 等最后一行 UART 字节发完（115200 下几十字节只需几毫秒，这里留足余量）
    for (volatile uint32_t i = 0; i < 200000u; i++) { }
    // 直接跳回 0x0（ROM 里的 Loader）。不需要 fence.i：
    // 目标代码在 ROM 里且不会变化，本程序也不打算再取自己的指令。
    __asm__ volatile ("li t0, 0\n\t"
                      "jr t0\n\t" ::: "t0");
#endif
    for (;;) { }
}

static void halt(void) __attribute__((noreturn));
static void halt(void) {
#ifdef PP_NATIVE
    diag_halt();
#else
    reboot_to_loader();
#endif
}
static void fail(const char *why) __attribute__((noreturn));

static uint64_t ticks(void)
{
    uint32_t value = R32(CYCLE);
    elapsed += (uint32_t)(value - previous_tick);
    previous_tick = value;
    return elapsed;
}

static void uart_put(uint8_t byte)
{
    uint64_t start = ticks();
    while (!(R32(UART + UART_STATUS) & 1u)) {
        if (ticks() - start >= TX_LIMIT) {
            if (failing) {
                return; 
            }
            fail("UART_TX_DEADLINE");
        }
    }
#ifdef PP_NATIVE
    diag_write(UART + UART_TX_DATA, byte);
#else
    *(volatile uint8_t *)(UART + UART_TX_DATA) = byte;
#endif
}

static void text(const char *s) { while (*s) { uart_put((uint8_t)*s++); } }

static void hex(uint32_t value)
{
    for (int i = 7; i >= 0; i--) {
        uart_put((uint8_t)"0123456789abcdef"[(value >> (i * 4)) & 15u]);
    }
}

static void dec(uint64_t value)
{
    char buf[21];
    unsigned n = 20;
    buf[n] = '\0';
    do {
        buf[--n] = (char)('0' + (int)(value % 10u));
        value /= 10u;
    } while (value);
    text(buf + n);
}

static void hfield(const char *key, uint32_t value) { text(key); hex(value); }

static void fail(const char *why)
{
    failing = 1;
    text("CNN_FAIL REASON=");
    text(why);
    text(" GROUP=");
    dec(group_no);
    text(" BUF=");
    dec(cur_buf);
    text(" SEQ=");
    dec(cur_seq);
    text(" CLAIMS=");
    dec(ledger_n);
    text(" TARGET_CLAIMS=");
    dec(target_claims);
    text(" DISCARD_CLAIMS=");
    dec(discard_claims);
    text(" LAST_DISCARD=");
    dec(last_discard);
    hfield(" CAM_STATUS=", R32(CAM + CAM_STATUS));
    hfield(" CAM_ERR=", R32(CAM + CAM_ERROR));
    hfield(" CAM_BUFSTATE=", R32(CAM + CAM_BUFSTATE));
    hfield(" CAM_GLOBAL_SEQ=", R32(CAM + CAM_GLOBAL_SEQ));
    hfield(" PP_STATUS=", R32(PP + PP_STATUS));
    hfield(" PP_ERR=", R32(PP + PP_ERROR));
    hfield(" UART_STATUS=", R32(UART + UART_STATUS));
    hfield(" CNN_STATUS=",R32(0x10004008u));hfield(" CNN_ERROR=",R32(0x1000403cu));
    text(" LOAD_COUNT=");dec(R32(0x10004018u));hfield(" MODEL_CRC=",R32(0x10004014u));hfield(" MODEL_ID=",R32(0x1000400cu));
    text(" ELAPSED_TICKS=");
    dec(ticks() - program_start);
    text("\n");
    W32(TEST_STATUS, 3u);
    halt();
}

void camera_trap(uint32_t cause, uint32_t pc, uint32_t value)
{
    text("CNN_TRAP CAUSE=");
    hex(cause);
    text(" PC=");
    hex(pc);
    text(" TVAL=");
    hex(value);
    text("\n");
    fail("CPU_TRAP");
}





static void uart_bytes(const uint8_t *p, uint32_t n)
{
    while (n--) {
        uart_put(*p++);
    }
}

static void send_packet(uint32_t kind, uint32_t seq, uint32_t offset, uint32_t length,
                        uint32_t total, uint32_t data_crc)
{
    pp01_build_header(packet, kind, seq, offset, length, total, data_crc);
    uart_bytes(packet, PP01_HEADER_BYTES);
    if (length) {
        uart_bytes(payload, length);
    }
    uint64_t start = ticks();
    for (;;) {
        uint32_t status = R32(UART + UART_STATUS);
        if (status & 0x30u) {
            fail("UART_RX_ERROR");
        }
        if (status & 4u) {
            break;
        }
        if (ticks() - start >= ACK_LIMIT) {
            fail("EXPORT_ACK_TIMEOUT");
        }
    }
    if ((uint8_t)(R32(UART + UART_RX_DATA) & 0xffu) != 0x4bu) {
        fail("EXPORT_ACK_BYTE");
    }
}

static uint8_t wait_command(uint64_t limit)
{
    uint64_t start = ticks();
    for (;;) {
        uint32_t status = R32(UART + UART_STATUS);
        if (status & 0x30u) {
            fail("UART_RX_ERROR");
        }
        if (status & 4u) {
            return (uint8_t)(R32(UART + UART_RX_DATA) & 0xffu);
        }
        if (ticks() - start >= limit) {
            fail("COMMAND_TIMEOUT");
        }
    }
}


static void load_words(uint32_t base, uint32_t offset, uint32_t words)
{
    const volatile uint32_t *src = (const volatile uint32_t *)(base + offset);
    for (uint32_t i = 0; i < words; i++) {
        uint32_t w = src[i];
        payload[4u * i] = (uint8_t)w;
        payload[4u * i + 1u] = (uint8_t)(w >> 8);
        payload[4u * i + 2u] = (uint8_t)(w >> 16);
        payload[4u * i + 3u] = (uint8_t)(w >> 24);
    }
}

static uint32_t output_reread(void)
{
    uint32_t c = 0xffffffffu;
    uint64_t start = ticks();
    for (uint32_t off = 0; off < OUT_BYTES; off += CHUNK) {
        load_words(OUT_BASE, off, CHUNK / 4u);
        for (uint32_t i = 0; i < CHUNK; i++) {
            c = pp01_crc_step(c, payload[i]);
        }
        if (ticks() - start >= CPU_LIMIT) {
            fail("CPU_OUTPUT_REREAD_TIMEOUT");
        }
    }
    return pp01_crc_finish(c);
}


static void cam_write(uint32_t offset, uint32_t value) { W32(CAM + offset, value); }

static uint32_t cam_state(uint32_t buf)
{
    return (R32(CAM + CAM_BUFSTATE) >> (2u * buf)) & 3u;
}

static void cam_healthy(void)
{
    uint32_t s = R32(CAM + CAM_STATUS);
    if ((s & 1u) == 0u) {
        fail("CAMERA_CONFIG_LOST");
    }
    if (s & 8u) {
        fail("CAMERA_OVERFLOW");
    }
    if (s & 16u) {
        fail("CAMERA_ERROR");
    }
    if (R32(CAM + CAM_ERROR) != 0u) {
        fail("CAMERA_ERROR_CODE");
    }
}


static void cam_idle_state(void)
{
    uint32_t st = R32(CAM + CAM_BUFSTATE);
    if (st & 0x2cfu) {
        fail("CAMERA_NOT_IDLE_FREE");
    }
    if (R32(CAM + CAM_STATUS) & 2u) {
        fail("CAMERA_BUSY");
    }
    if (R32(CAM + CAM_STATUS) & 0x40u) {
        fail("CAMERA_STREAM_ENABLED");
    }
}

static void cam_claim(uint32_t buf, uint32_t seq)
{
    cam_write(CAM_SELECT, buf);
    cam_write(CAM_TOKEN, seq);
    if (cam_state(buf) != 2u) {
        fail("CLAIM_STATE");
    }
    if (R32(CAM + CAM_FRAME_SEQ) != seq) {
        fail("CLAIM_SEQ");
    }
    cam_write(CAM_CTRL, CAM_CMD_CLAIM);
    if (cam_state(buf) != 3u) {
        fail("CLAIM_NOT_ACCEPTED");
    }
}

static void cam_release(uint32_t buf, uint32_t seq)
{
    cam_write(CAM_SELECT, buf);
    cam_write(CAM_TOKEN, seq);
    if (cam_state(buf) != 3u) {
        fail("RELEASE_STATE");
    }
    if (R32(CAM + CAM_FRAME_SEQ) != seq) {
        fail("RELEASE_SEQ");
    }
    cam_write(CAM_CTRL, CAM_CMD_RELEASE);
    if (cam_state(buf) == 3u) {
        fail("RELEASE_NOT_ACCEPTED");
    }
}

static void ledger_add(uint32_t buf, uint32_t seq, uint32_t target)
{
    if (ledger_n >= MAX_LEDGER) {
        fail("LEDGER_OVERFLOW");
    }
    for (uint32_t i = 0; i < ledger_n; i++) {
        if (ledger_buf[i] == buf && ledger_seq[i] == seq) {
            fail("LEDGER_DUPLICATE");
        }
    }
    ledger_seq[ledger_n] = seq;
    ledger_buf[ledger_n] = buf;
    ledger_n++;
    if (target) {
        target_claims++;
    } else {
        discard_claims++;
        last_discard = seq;
    }
}

// ★ 流式循环修正：账本原本是"单次拍照"语义（最多 MAX_LEDGER=16 条），
//   连续循环跑到第 9 帧就会 LEDGER_OVERFLOW（16 = 8 帧 × 2 次 claim）。
//   这里在每次迭代开头清空，保持"claims == target + discards"的逐轮语义。
static void ledger_reset(void)
{
    ledger_n = 0;
    target_claims = 0;
    discard_claims = 0;
    last_discard = 0;
}


static uint32_t wait_target(uint32_t buf)
{
    uint64_t start = ticks();
    for (;;) {
        cam_healthy();
        if (cam_state(buf) == 2u) {
            cam_write(CAM_SELECT, buf);
            uint32_t seq = R32(CAM + CAM_FRAME_SEQ);
            if (R32(CAM + CAM_FRAME_BYTES) != SRC_BYTES ||
                R32(CAM + CAM_PIXELS) != SRC_PIXELS ||
                R32(CAM + CAM_BEATS) != SRC_BEATS ||
                R32(CAM + CAM_FRAME_BASE) != (buf ? SRC_B : SRC_A)) {
                fail("SOURCE_LAYOUT");
            }
            cam_claim(buf, seq);
            ledger_add(buf, seq, 1u);
            return seq;
        }
        if (ticks() - start >= READY_LIMIT) {
            fail("TARGET_READY_TIMEOUT");
        }
    }
}

static void stop_and_drain(void)
{
    cam_write(CAM_CTRL, CAM_CMD_STREAM_STOP);
    uint64_t start = ticks();
    for (;;) {
        cam_healthy();
        if (!(R32(CAM + CAM_BUFSTATE) & 0x40u) && !(R32(CAM + CAM_STATUS) & 2u)) {
            break;
        }
        if (ticks() - start >= READY_LIMIT) {
            fail("STOP_DRAIN_TIMEOUT");
        }
    }
}


static void drain_unselected(uint32_t target)
{
    for (uint32_t buf = 0; buf < 2u; buf++) {
        if (buf == target) {
            continue;
        }
        for (;;) {
            cam_healthy();
            if (cam_state(buf) != 2u) {
                break;
            }
            cam_write(CAM_SELECT, buf);
            uint32_t seq = R32(CAM + CAM_FRAME_SEQ);
            if (cam_state(buf) != 2u) {
                fail("DISCARD_STATE");
            }
            cam_claim(buf, seq);
            ledger_add(buf, seq, 0u);
            cam_release(buf, seq);
            if (cam_state(buf) == 3u) {
                fail("DISCARD_NOT_RELEASED");
            }
        }
    }
}


static void pp_start(uint32_t buf, uint32_t seq)
{
    if (R32(PP + PP_STATUS) & 1u) {
        fail("PP_BUSY");
    }
    W32(PP + PP_SOURCE_BUF, buf);
    W32(PP + PP_EXPECTED, seq);
    if (R32(PP + PP_SOURCE_BUF) != buf || R32(PP + PP_EXPECTED) != seq) {
        fail("PP_CONFIG_READBACK");
    }
    W32(PP + PP_CTRL, 1u);
    
    if ((R32(PP + PP_STATUS) & 1u) == 0u) {
        fail("PP_NOT_BUSY");
    }
    if (R32(PP + PP_SOURCE_BUF) != buf) {
        fail("PP_ACTIVE_SOURCE");
    }
    if (cam_state(buf) != 3u) {
        fail("SOURCE_LOCK_LOST");
    }
    if (R32(CAM + CAM_ERROR) != 0u || (R32(CAM + CAM_STATUS) & 16u)) {
        fail("SOURCE_LOCK_ERROR");
    }
}

static void pp_wait_done(void)
{
    uint64_t start = ticks();
    for (;;) {
        uint32_t status = R32(PP + PP_STATUS);
        if (status & 4u) {
            fail("PP_ERROR");
        }
        if (status & 2u) {
            break;
        }
        if (ticks() - start >= PP_LIMIT) {
            fail("PP_TIMEOUT");
        }
    }
}

static void pp_check(uint32_t buf, uint32_t seq, uint32_t *pp_crc)
{
    if (R32(PP + PP_STATUS) != 2u) fail("PP_NOT_EXACT_DONE");
    if (R32(PP + PP_RESULT_BUF) != buf) {
        fail("PP_RESULT_BUF");
    }
    if (R32(PP + PP_RESULT_SEQ) != seq) {
        fail("PP_RESULT_SEQ");
    }
    if (R32(PP + PP_OUT_BASE) != OUT_BASE) {
        fail("PP_OUTPUT_BASE");
    }
    if (R32(PP + PP_OUT_BYTES) != OUT_BYTES) {
        fail("PP_OUTPUT_BYTES");
    }
    if (R32(PP + PP_OUT_SIZE) != OUT_SIZE) {
        fail("PP_OUTPUT_SIZE");
    }
    if (R32(PP + PP_READS) != OUT_PIXELS) {
        fail("PP_READ_BEATS");
    }
    if (R32(PP + PP_WRITES) != OUT_BEATS) {
        fail("PP_WRITE_BEATS");
    }
    if (R32(PP + PP_PRODUCED) != OUT_BYTES) {
        fail("PP_PRODUCED_BYTES");
    }
    if (R32(PP + PP_ERROR) != 0u) {
        fail("PP_ERROR_CODE");
    }
    *pp_crc = R32(PP + PP_OUT_CRC);
}


#include "cnn.h"
int main(void){
    failing=0;previous_tick=R32(CYCLE);program_start=ticks();W32(TEST_STATUS,1u);
    if(boot_cookie!=0x50505531u)fail("DATA_INIT");
    pp01_crc_init();
    if(R32(CAM)!=CAM_OK_ID || R32(PP)!=PP_OK_ID || R32(0x10004000u)!=0x434e4e01u)fail("DEVICE_ABI_IDS");
    text("CNN_DIGITS_STREAM=1 CONTRACT=digits10_int8_v1 HZ=93750000 MODE=REALTIME IMAGE_EXPORT=OFF\n");
    cnn_load();uint64_t start=ticks();
    while(!(R32(CAM+CAM_STATUS)&1u)){
        if(R32(CAM+CAM_STATUS)&24u)fail("CAMERA_CONFIG");
        if(ticks()-start>5ull*HZ)fail("CONFIG_TIMEOUT");
    }
    // ★ 软重启（reboot_to_loader 跳 0x0）**不会复位 camera/preprocess 外设**，
    //   所以不能要求"上电级全新"：CAM_GLOBAL_SEQ 会保留（无法清零）、
    //   缓冲可能停在 READY。这里主动做一次热复位，把它们拉回可用状态。
    // ★ 陷阱提醒：camera_mmio 的错误响应对 CPU 是**致命**的。
    //   camera_mmio 里 stream_stop_cmd 要求 `dual_mode` 才成立；冷启动时
    //   dual_mode==0，此时写 CAM_CTRL=0x10 不匹配任何合法命令 -> rsp_error=1
    //   -> CPU 的 store 变成 mcause=7 (store access fault)，实测 PC=0x40001168。
    //   所以只在"流确实开着"时才发 STREAM_STOP（流只在 dual 模式跑，此时合法）。
    if (R32(CAM + CAM_STATUS) & 0x40u) {
        cam_write(CAM_CTRL, CAM_CMD_STREAM_STOP);
        uint64_t t = ticks();
        while ((R32(CAM + CAM_STATUS) & 2u) && ticks() - t < READY_LIMIT) { }  // 等 busy 落
    }
    for (uint32_t b = 0; b < 2u; b++) {          // 排空遗留的 READY 缓冲
        if (cam_state(b) == 2u) {
            cam_write(CAM_SELECT, b);
            uint32_t s = R32(CAM + CAM_FRAME_SEQ);
            cam_claim(b, s);
            cam_release(b, s);
        }
    }
    if ((R32(CAM + CAM_STATUS) & 1u) == 0u || R32(CAM + CAM_SENSOR) != 0x5640u)
        fail("CAMERA_NOT_CONFIGURED");
    if (R32(PP + 8) != 0u && R32(PP + 8) != 2u) fail("PP_UNEXPECTED_STATE");
    text("SENSOR_ID=00005640 CONFIG=OK\nCNN_READY\n");
    if(wait_command(CMD_LIMIT)!='G')fail("GO_COMMAND");
    // ================= 实时循环：取帧 -> 预处理 -> CNN -> 只回读分数 =================
    // 图像始终留在 DDR/硬件里，UART 只传 CLASS + 10 个分数 + 周期数。
    // 指令：Q/q 退出；D 回传本帧源图(1.8MB)；d 回传本帧 RGB96(27KB)；其它忽略。
    uint32_t frame=0, dump_requests=0;
    text("STREAM_START Enter=noop  Q=quit  D=full-source  d=rgb96\n");
    stream_open();          // ★ 开一次流，之后不再启停相机（显示端才能连续）
    for(;;){
        uint32_t us=R32(UART+UART_STATUS);
        if(us&0x30u)fail("UART_RX_ERROR");
        if(us&4u){
            uint8_t c=(uint8_t)(R32(UART+UART_RX_DATA)&0xffu);
            if(c=='Q'||c=='q')break;
            if((c=='D'||c=='d') && cur_seq!=0u){
                full_source_export=(c=='D');
                export_group();
                dump_requests++;
                text("STREAM_CONTINUE AFTER_DUMP FRAMES=");dec(frame);text("\n");
            }
            // 其它字符忽略，继续取下一帧
        }
        frame++;
        group_no=frame;
        ledger_reset();   // ★ 每轮清账本，避免跑到第 9 帧 LEDGER_OVERFLOW
        // 双缓冲乒乓：A/B 交替（capture_group_stream 内部已做 claim/release）
        capture_group_stream(frame&1u);
        text("STREAM_FRAME NO=");dec(frame);
        text(" CLS=");dec(prediction);
        text(" CNN_CYC=");dec(cnn_cycles);
        text(" PP_CYC=");dec(pp_cycles);
        text(" CONF=");
        {
            uint32_t best=scores[prediction];
            uint32_t second=0u;unsigned i;
            for(i=0;i<10u;i++){ if(i!=prediction && scores[i]>second) second=scores[i]; }
            if(best&0x80000000u) text("-");
            dec(best&0x7fffffffu);
            text("/");
            if(second&0x80000000u) text("-");
            dec(second&0x7fffffffu);
        }
        text("\n");
    }
    stream_close();          // ★ 先停流
    // 收尾**故意不做** cam_idle_state() 的严格检查：
    // 停流那一瞬间相机很可能正在写某个缓冲（实测 CAM_BUFSTATE=0x112，buf0=WRITING），
    // 那是正常残留，不是故障。紧接着会 reboot_to_loader()，
    // 下次加载固件时相机会被重新初始化，所以这里不必也不该 fail。
    text("CNN_STREAM_DONE FRAMES=");dec(frame);text(" DUMPS=");dec(dump_requests);
    text(" CPU_CYCLES=");dec(ticks()-program_start);
    text(" AVG_CYCLES_PER_FRAME=");dec(frame?(ticks()-program_start)/frame:0u);
    text("\nMODEL=");hex(MODEL_ID);text("\n");
    W32(TEST_STATUS,2);halt();
}

