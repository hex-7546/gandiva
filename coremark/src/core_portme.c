#include "coremark.h"
#include "core_portme.h"

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

static CORE_TICKS start_time_val, stop_time_val;

#define MTIME_ADDR 0x0200BFF8

CORE_TICKS barebones_clock() {
    volatile uint32_t *mtime = (volatile uint32_t *)MTIME_ADDR;
    return *mtime;
}

void start_time(void) {
    start_time_val = barebones_clock();
}
void stop_time(void) {
    stop_time_val = barebones_clock();
}
CORE_TICKS get_time(void) {
    return stop_time_val - start_time_val;
}
secs_ret time_in_secs(CORE_TICKS ticks) {
    secs_ret retval = ((secs_ret)ticks) / (secs_ret)EE_TICKS_PER_SEC;
    return retval;
}

ee_u32 default_num_contexts = 1;

void portable_init(core_portable *p, int *argc, char *argv[]) {
    (void)argc;
    (void)argv;
    if (sizeof(ee_ptr_int) != sizeof(ee_u8 *)) {
        ee_printf("ERROR! Please define ee_ptr_int to a type that holds a pointer!\n");
    }
    if (sizeof(ee_u32) != 4) {
        ee_printf("ERROR! Please define ee_u32 to a 32b unsigned type!\n");
    }
    p->portable_id = 1;
}

void portable_fini(core_portable *p) {
    p->portable_id = 0;
}

// CoreMark ee_printf uses uart_send_char if HAS_PRINTF=0 and HAS_STDIO=0
void uart_send_char(char c) {
    volatile uint32_t *uart_status = (volatile uint32_t *)0x10000000;
    while ((*uart_status) & 1); // wait while tx_busy
    *uart_status = (uint32_t)c;
}
