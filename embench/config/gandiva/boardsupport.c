/*
 * boardsupport.c — Gandiva Embench board support
 */
#include "boardsupport.h"
#include <stdint.h>

#define UART_BASE 0x10000000U

static void uart_putc(char c) {
    volatile uint32_t *uart = (volatile uint32_t *)UART_BASE;
    while ((*uart) & 1u);
    *uart = (uint32_t)(unsigned char)c;
}

static void uart_puts(const char *s) {
    while (*s) uart_putc(*s++);
}

static void print_uint(uint32_t v) {
    char buf[12];
    int n = 0;
    if (v == 0) { uart_putc('0'); return; }
    while (v) {
        buf[n++] = '0' + (v % 10);
        v /= 10;
    }
    for (int i = n - 1; i >= 0; i--) {
        uart_putc(buf[i]);
    }
}

volatile uint32_t start_cycles_lo;
volatile uint32_t start_cycles_hi;
volatile uint32_t stop_cycles_lo;
volatile uint32_t stop_cycles_hi;

void initialise_board() {
    /* Delay for ~2 seconds (50M cycles at 25MHz) to allow the host PC's 
       USB-UART driver to re-enumerate and the Python listener to attach 
       after openFPGALoader resets the FTDI chip. */
    uint32_t start_lo;
    __asm__ volatile("csrr %0, mcycle" : "=r"(start_lo));
    while (1) {
        uint32_t now;
        __asm__ volatile("csrr %0, mcycle" : "=r"(now));
        if (now - start_lo > 50000000) {
            break;
        }
    }
    uart_puts("BOOT\n");
}

void __attribute__ ((noinline)) start_trigger() {
    uart_puts("START\n");
    __asm__ volatile("csrr %0, mcycle" : "=r"(start_cycles_lo));
    __asm__ volatile("csrr %0, mcycleh" : "=r"(start_cycles_hi));
}

void __attribute__ ((noinline)) stop_trigger() {
    __asm__ volatile("csrr %0, mcycle" : "=r"(stop_cycles_lo));
    __asm__ volatile("csrr %0, mcycleh" : "=r"(stop_cycles_hi));
}

/* Embench expects the environment to provide the result, 
   but for Gandiva simulation we print it via UART before exit. */
void _exit(int code) {
    uint64_t start = ((uint64_t)start_cycles_hi << 32) | start_cycles_lo;
    uint64_t stop = ((uint64_t)stop_cycles_hi << 32) | stop_cycles_lo;
    uint32_t elapsed = (uint32_t)(stop - start); // Assuming it fits in 32-bit for simulation

    uart_puts("RET=");
    print_uint((uint32_t)code);
    uart_puts("\nCYCLES=");
    print_uint(elapsed);
    uart_puts("\n");

    volatile uint32_t *tohost = (volatile uint32_t *)0x20000000;
    *tohost = 1;
    while(1);
}
