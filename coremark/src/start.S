    .section .text.init
    .global _start
_start:
    /* initialize stack pointer */
    la sp, _stack_top

    /* copy data section */
    la a0, _data_lma
    la a1, _data_start
    la a2, _data_end
    bgeu a1, a2, 0f
3:
    lw t0, 0(a0)
    sw t0, 0(a1)
    addi a0, a0, 4
    addi a1, a1, 4
    bltu a1, a2, 3b
0:

    /* clear BSS */
    la a0, _bss_start
    la a1, _bss_end
    bgeu a0, a1, 2f
1:
    sw zero, 0(a0)
    addi a0, a0, 4
    bltu a0, a1, 1b
2:

    /* jump to main */
    call main

    /* check return value (CoreMark main returns 0 on success if PORT_DIR is setup, wait, coremark returns something else? Usually returns 0 if validation passes.) 
       Actually, CoreMark main typically returns 0 for PASS. Let's write 1 to tohost for pass, else 2. */
    li t0, 0
    beq a0, t0, 3f
    /* fail */
    li t1, 2
    j 4f
3:
    /* pass */
    li t1, 1
4:
    /* write to tohost */
    li t0, 0x20000000
    sw t1, 0(t0)
5:
    j 5b
