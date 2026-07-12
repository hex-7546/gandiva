/* Freestanding libc stubs pulled in by the FreeRTOS kernel (queue/task). */
#include <stddef.h>

void *memcpy( void *d, const void *s, size_t n )
{
    unsigned char *dd = d;
    const unsigned char *ss = s;
    while( n-- ) *dd++ = *ss++;
    return d;
}

void *memset( void *d, int c, size_t n )
{
    unsigned char *dd = d;
    while( n-- ) *dd++ = (unsigned char) c;
    return d;
}

void *memmove( void *d, const void *s, size_t n )
{
    unsigned char *dd = d;
    const unsigned char *ss = s;
    if( dd < ss )
        while( n-- ) *dd++ = *ss++;
    else
    {
        dd += n; ss += n;
        while( n-- ) *--dd = *--ss;
    }
    return d;
}
