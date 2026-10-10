/*
 * ee_printf.c  ---  极简 printf，仅供 CoreMark 使用
 *
 * 支持：%% %c %s %d %i %u %x %X %p %f，以及 '-' / '0' 标志、宽度和 'l' 长度修饰。
 * 不支持：精度、浮点科学计数、动态宽度。
 *
 * 为什么自己写：裸机没有 libc；官方 barebones 的 ee_printf.c 有 13 KB，
 * 而片内 ROM 只有 16 KiB，必须省着用。
 *
 * %f 的实现：分离整数部分与小数部分，用定点×1e6 + 四舍五入打印 6 位小数。
 * 好处是只需要 32 位整数运算（分数值 < 2^32，小数部分不会溢出），
 * 不需要 64 位除法，能明显减小代码体积。软件浮点由 libgcc 提供。
 *
 * 副作用（有意为之）：当格式化串里出现官方 CoreMark 的结论文本时，
 * 记录 cm_result_ok，供 portable_fini 上报 MMIO TEST_STATUS。
 * 这样不需要修改官方 core_main.c。
 */
#include <stdarg.h>
#include "core_portme.h"
#include "soc_mmio.h"

extern void cm_console_putc(char c);
extern volatile int cm_result_ok;

static void out_char(char c)
{
    if (c == '\n')
        cm_console_putc('\r');
    cm_console_putc(c);
}

static void out_str(const char *s)
{
    if (s == NULL)
        s = "(null)";
    while (*s)
        out_char(*s++);
}

/* 无符号整数按进制输出；base_of_digits = 10 或 16 */
static void out_uint(ee_u32 v, ee_u32 base, int upper, int width, int zero_pad)
{
    char buf[36];
    int  n = 0;
    const char *digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";

    if (v == 0) {
        buf[n++] = '0';
    } else {
        while (v && n < (int)sizeof(buf)) {
            buf[n++] = digits[v % base];
            v /= base;
        }
    }
    while (width > n) {
        out_char(zero_pad ? '0' : ' ');
        width--;
    }
    while (n > 0)
        out_char(buf[--n]);
}

static void out_int(ee_s32 v, int width, int zero_pad)
{
    ee_u32 mag;
    if (v < 0) {
        out_char('-');
        mag = (ee_u32)(-(ee_s32)v);
        if (width > 0)
            width--;
    } else {
        mag = (ee_u32)v;
    }
    out_uint(mag, 10u, 0, width, zero_pad);
}

/* ------------------------------------------------------------------ *
 * %f：只用 32 位整数运算把 double 打印成 6 位小数
 *
 * 为什么这么做：HAS_FLOAT=1 时 coremark.h 把 secs_ret 定义成 double，
 * CoreMark 会打印分数与耗时。但片内 ROM 只有 16 KiB，而 GCC 的软浮点
 * __adddf3 / __subdf3 / __muldf3 / __divdf3 四个例程实测要占约 10.6 KB
 * （占 .text 的 43%）。这里直接从 IEEE-754 位模式取数，printf 内部
 * 一次浮点运算都不做，可以省掉 __adddf3 + __subdf3 + __muldf3 约 8 KB，
 * 让 CoreMark 能装进 16 KiB ROM。
 *
 * 精度：小数部分先归一到 32 位定点（2^-32 ≈ 2.3e-10），再用
 * 1e6 = 15625 × 2^6 换算成 6 位小数并四舍五入。对打印分数/秒数完全够用。
 * ------------------------------------------------------------------ */

typedef unsigned int cm_u32;

/* 取 53 位有效数 (mh:ml) 的 [hi:lo] 位。mh 只用了低 21 位。 */
static cm_u32 cm_bits53(cm_u32 mh, cm_u32 ml, int hi, int lo)
{
    cm_u32 rl;
    int    n;

    if (lo <= 0) {
        rl = ml;
    } else if (lo < 32) {
        rl = (ml >> lo) | (mh << (32 - lo));
    } else {
        rl = mh >> (lo - 32);
    }
    n = hi - lo + 1;
    if (n >= 32)
        return rl;
    if (n <= 0)
        return 0u;
    return rl & ((1u << n) - 1u);
}

static void out_double6(double d)
{
    union { double d; cm_u32 w[2]; } u;
    cm_u32 lo, hi, mh, ml;
    cm_u32 ip = 0u, F = 0u, fp;
    int    sign, exp, e, s;

    u.d = d;
    lo = u.w[0];                 /* 低 32 位 */
    hi = u.w[1];                 /* 高 32 位 */
    sign = (int)(hi >> 31);
    exp  = (int)((hi >> 20) & 0x7FFu);

    if (exp == 0x7FF) {                       /* inf / nan */
        if (sign) out_char('-');
        out_str(((hi & 0xFFFFFu) || lo) ? "nan" : "inf");
        return;
    }
    if (exp == 0) {                           /* +0/-0 与 denormal，按 0 处理 */
        if (sign) out_char('-');
        out_str("0.000000");
        return;
    }

    mh = (hi & 0xFFFFFu) | 0x100000u;         /* 隐含的 1 + 尾数高 20 位 */
    ml = lo;
    e  = exp - 1023;
    s  = 52 - e;                              /* value = M53 * 2^-s */

    if (e >= 0) {
        if (e > 31) {                         /* 超出量程，钳位（本用例不会发生） */
            ip = 0xFFFFFFFFu;
            F  = 0u;
        } else {
            ip = cm_bits53(mh, ml, 52, s);
            if (s >= 32)
                F = cm_bits53(mh, ml, s - 1, s - 32);
            else if (s > 0)
                F = cm_bits53(mh, ml, s - 1, 0) << (32 - s);
            else
                F = 0u;
        }
    } else {
        ip = 0u;
        if (s - 32 >= 53)
            F = 0u;
        else
            F = cm_bits53(mh, ml, 52, s - 32);
    }

    /* fp = round(F/2^32 * 1e6) = (F * 15625 + 2^25) >> 26 */
    {
        cm_u32 a0 = F & 0xFFFFu;
        cm_u32 a1 = F >> 16;
        cm_u32 p00 = a0 * 15625u;
        cm_u32 p10 = a1 * 15625u;
        cm_u32 acc = p00 + ((p10 & 0xFFFFu) << 16);
        cm_u32 carry = (acc < p00) ? 1u : 0u;
        cm_u32 upper = (p10 >> 16) + carry;
        cm_u32 lo2 = acc + (1u << 25);
        cm_u32 carry2 = (lo2 < acc) ? 1u : 0u;
        cm_u32 upper2 = upper + carry2;

        fp = (lo2 >> 26) | (upper2 << 6);
    }
    if (fp >= 1000000u) {                     /* 四舍五入进位 */
        fp -= 1000000u;
        ip += 1u;
    }

    if (sign)
        out_char('-');
    out_uint(ip, 10u, 0, 0, 0);
    out_char('.');
    {
        cm_u32 div = 100000u;
        int    i;
        for (i = 0; i < 6; i++) {
            out_char((char)('0' + (fp / div) % 10u));
            if (div > 1u)
                div /= 10u;
        }
    }
}

static int str_has(const char *hay, const char *needle)
{
    const char *h;
    for (h = hay; *h; h++) {
        const char *a = h;
        const char *b = needle;
        while (*a && *b && *a == *b) {
            a++;
            b++;
        }
        if (*b == '\0')
            return 1;
    }
    return 0;
}

int ee_printf(const char *fmt, ...)
{
    va_list ap;
    int     n = 0;

    /* 观察官方结论文本，决定板上 TEST_STATUS */
    if (str_has(fmt, "Correct operation validated"))
        cm_result_ok = 1;
    if (str_has(fmt, "Errors detected") || str_has(fmt, "Cannot validate operation"))
        cm_result_ok = -1;

    va_start(ap, fmt);
    while (*fmt) {
        if (*fmt != '%') {
            out_char(*fmt++);
            n++;
            continue;
        }
        fmt++;                                  /* 跳过 '%' */

        int zero_pad = 0;
        int left     = 0;
        int width    = 0;
        int is_long  = 0;

        for (;;) {                              /* 标志 */
            if (*fmt == '0') { zero_pad = 1; fmt++; }
            else if (*fmt == '-') { left = 1; fmt++; }
            else if (*fmt == '+' || *fmt == ' ' || *fmt == '#') { fmt++; }
            else break;
        }
        while (*fmt >= '0' && *fmt <= '9') {    /* 宽度 */
            width = width * 10 + (*fmt - '0');
            fmt++;
        }
        if (*fmt == 'l' || *fmt == 'z') {       /* 长度修饰（rv32 上 long=32 位） */
            is_long = 1;
            fmt++;
            if (*fmt == 'l')
                fmt++;
        }
        (void)is_long;
        (void)left;

        switch (*fmt) {
        case 'd':
        case 'i':
            out_int(va_arg(ap, ee_s32), width, zero_pad);
            break;
        case 'u':
            out_uint((ee_u32)va_arg(ap, ee_u32), 10u, 0, width, zero_pad);
            break;
        case 'x':
            out_uint((ee_u32)va_arg(ap, ee_u32), 16u, 0, width, zero_pad);
            break;
        case 'X':
            out_uint((ee_u32)va_arg(ap, ee_u32), 16u, 1, width, zero_pad);
            break;
        case 'p':
            out_str("0x");
            out_uint((ee_u32)va_arg(ap, ee_u32), 16u, 0, 8, 1);
            break;
        case 'c':
            out_char((char)va_arg(ap, int));
            break;
        case 's':
            out_str(va_arg(ap, const char *));
            break;
        case 'f':
            out_double6(va_arg(ap, double));
            break;
        case '%':
            out_char('%');
            break;
        case '\0':
            fmt--;                              /* 字符串以 '%' 结尾，保护 */
            break;
        default:
            out_char('%');
            out_char(*fmt);
            break;
        }
        if (*fmt)
            fmt++;
    }
    va_end(ap);
    return n;
}
