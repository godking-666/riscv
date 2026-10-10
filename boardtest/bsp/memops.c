/*
 * memops.c  ---  裸机需要的最小内存/字符串函数
 *
 * 用 -nostdlib 链接时没有 libc，但 GCC 会为结构体赋值、数组初始化等
 * 生成对 memcpy/memset 的调用（CoreMark 里 list_head 的赋值就会触发），
 * 所以必须自己提供。放在这里而不是 libgcc 里，是为了可读与可控。
 */
#include <stddef.h>

void *memcpy(void *dst, const void *src, size_t n)
{
    unsigned char       *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    /* 按字拷贝，再处理尾部。CoreMark 的数据块是对齐的，字拷贝能省不少时间。 */
    while (n >= 4 && (((unsigned long)d & 3u) == 0u) && (((unsigned long)s & 3u) == 0u)) {
        *(unsigned int *)d = *(const unsigned int *)s;
        d += 4;
        s += 4;
        n -= 4;
    }
    while (n--)
        *d++ = *s++;
    return dst;
}

void *memmove(void *dst, const void *src, size_t n)
{
    unsigned char       *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    if (d == s || n == 0)
        return dst;
    if (d < s) {
        while (n--)
            *d++ = *s++;
    } else {
        d += n;
        s += n;
        while (n--)
            *--d = *--s;
    }
    return dst;
}

void *memset(void *dst, int c, size_t n)
{
    unsigned char *d = (unsigned char *)dst;
    unsigned int   w;
    unsigned char  b = (unsigned char)c;

    w = (unsigned int)b | ((unsigned int)b << 8) |
        ((unsigned int)b << 16) | ((unsigned int)b << 24);
    while (n >= 4 && (((unsigned long)d & 3u) == 0u)) {
        *(unsigned int *)d = w;
        d += 4;
        n -= 4;
    }
    while (n--)
        *d++ = b;
    return dst;
}

int memcmp(const void *a, const void *b, size_t n)
{
    const unsigned char *x = (const unsigned char *)a;
    const unsigned char *y = (const unsigned char *)b;
    while (n--) {
        if (*x != *y)
            return (int)*x - (int)*y;
        x++;
        y++;
    }
    return 0;
}

size_t strlen(const char *s)
{
    const char *p = s;
    while (*p)
        p++;
    return (size_t)(p - s);
}

char *strcpy(char *dst, const char *src)
{
    char *d = dst;
    while ((*d++ = *src++) != '\0')
        ;
    return dst;
}

int strcmp(const char *a, const char *b)
{
    while (*a && (*a == *b)) {
        a++;
        b++;
    }
    return (int)(unsigned char)*a - (int)(unsigned char)*b;
}
