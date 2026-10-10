/*
 * console.c  ---  最小控制台：UART 输出 + 结果字符串 + CYCLE 计时
 *
 * 全部自己实现，因为裸机没有 libc。格式化只支持自检需要的几种：
 *   %c %s %d %i %u %x %X %p，以及 '-'/'0' 标志、宽度、'l' 长度修饰。
 * 同一套格式化内核既输出到串口（bt_printf），也输出到内存缓冲（bt_note）。
 */
#include <stdarg.h>
#include "boardtest.h"
#include "soc_mmio.h"

char g_bt_detail[112];
int  g_console_ok = 0;

/* ------------------------------------------------------------------ */
/* 输出后端                                                            */
/* ------------------------------------------------------------------ */
typedef void (*bt_out_fn)(char c, void *ctx);

void bt_putc(char c)
{
    uint32_t guard = 0;
    if (!g_console_ok)
        return;                 /* UART 没接就不要每写一个字节都去踩一次异常 */
    if (c == '\n') {
        bt_putc('\r');
    }
    /* 必须等 TX_READY：忙时写 TX_DATA 会被丢弃并返回总线错误（进而变成异常） */
    while (((UART_STATUS & UART_ST_TX_READY) == 0u) && (guard < 2000000u))
        guard++;
    UART_TX_DATA = (uint8_t)c;
}

void bt_puts(const char *s)
{
    while (*s)
        bt_putc(*s++);
}

static void out_uart(char c, void *ctx) { (void)ctx; bt_putc(c); }

/* 有界缓冲输出，供 bt_note 用 */
typedef struct {
    char *buf;
    int   left;      /* 还能写的字节数（含结尾 '\0'） */
} bt_bufctx;

static void out_bounded(char c, void *ctx)
{
    bt_bufctx *b = (bt_bufctx *)ctx;
    if (b->left > 1) {
        *b->buf++ = c;
        b->left--;
        *b->buf = '\0';
    }
}

/* ------------------------------------------------------------------ */
/* 格式化内核                                                          */
/* ------------------------------------------------------------------ */
static void emit_uint(bt_out_fn out, void *ctx, uint32_t v, uint32_t base,
                      int upper, int width, int zero_pad)
{
    char buf[36];
    const char *dig = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    int n = 0;

    if (v == 0) {
        buf[n++] = '0';
    } else {
        while (v && n < (int)sizeof(buf)) {
            buf[n++] = dig[v % base];
            v /= base;
        }
    }
    while (width > n) {
        out(zero_pad ? '0' : ' ', ctx);
        width--;
    }
    while (n > 0)
        out(buf[--n], ctx);
}

static void emit_int(bt_out_fn out, void *ctx, int32_t v, int width, int zero_pad)
{
    uint32_t mag;
    if (v < 0) {
        out('-', ctx);
        mag = (uint32_t)(-(int32_t)v);
        if (width > 0)
            width--;
    } else {
        mag = (uint32_t)v;
    }
    emit_uint(out, ctx, mag, 10u, 0, width, zero_pad);
}

static void bt_vformat(bt_out_fn out, void *ctx, const char *fmt, va_list ap)
{
    while (*fmt) {
        int zero = 0, width = 0;

        if (*fmt != '%') {
            out(*fmt++, ctx);
            continue;
        }
        fmt++;                                    /* 跳过 '%' */

        while (*fmt == '0' || *fmt == '-' || *fmt == '+' || *fmt == ' ') {
            if (*fmt == '0')
                zero = 1;
            fmt++;
        }
        while (*fmt >= '0' && *fmt <= '9') {
            width = width * 10 + (*fmt - '0');
            fmt++;
        }
        if (*fmt == 'l' || *fmt == 'z') {         /* rv32 上 long 就是 32 位 */
            fmt++;
            if (*fmt == 'l')
                fmt++;
        }

        switch (*fmt) {
        case 'd': case 'i': emit_int(out, ctx, va_arg(ap, int32_t), width, zero); break;
        case 'u': emit_uint(out, ctx, va_arg(ap, uint32_t), 10u, 0, width, zero); break;
        case 'x': emit_uint(out, ctx, va_arg(ap, uint32_t), 16u, 0, width, zero); break;
        case 'X': emit_uint(out, ctx, va_arg(ap, uint32_t), 16u, 1, width, zero); break;
        case 'p':
            out('0', ctx); out('x', ctx);
            emit_uint(out, ctx, va_arg(ap, uint32_t), 16u, 0, 8, 1);
            break;
        case 'c': out((char)va_arg(ap, int), ctx); break;
        case 's': {
            const char *s = va_arg(ap, const char *);
            if (!s)
                s = "(null)";
            while (*s)
                out(*s++, ctx);
            break;
        }
        case '%': out('%', ctx); break;
        case '\0': fmt--; break;                  /* 串尾是 '%'，保护 */
        default:  out('%', ctx); out(*fmt, ctx); break;
        }
        if (*fmt)
            fmt++;
    }
}

int bt_printf(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    bt_vformat(out_uart, 0, fmt, ap);
    va_end(ap);
    return 0;
}

/* 把细节写进 g_bt_detail，超长自动截断；主流程随后统一打印 */
void bt_note(const char *fmt, ...)
{
    bt_bufctx b;
    va_list   ap;

    b.buf  = g_bt_detail;
    b.left = (int)sizeof(g_bt_detail);
    g_bt_detail[0] = '\0';

    va_start(ap, fmt);
    bt_vformat(out_bounded, &b, fmt, ap);
    va_end(ap);
}

/* ------------------------------------------------------------------ */
/* UART / 计时辅助                                                     */
/* ------------------------------------------------------------------ */
uint8_t bt_uart_status(void) { return (uint8_t)(UART_STATUS & 0xFFu); }

int bt_uart_tx_ready(void)
{
    return (bt_uart_status() & UART_ST_TX_READY) ? 1 : 0;
}

int bt_uart_getc(void)
{
    if (bt_uart_status() & UART_ST_RX_NOT_EMPTY)
        return (int)(UART_RX_DATA & 0xFFu);
    return -1;
}

uint32_t bt_cycle(void) { return MMIO_CYCLE; }
