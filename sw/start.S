// start.S — minimal bare-metal crt0 for the Gandiva RV32IM core.
// Sets the stack to the top of DRAM, calls main(), then writes main()'s
// return value to the tohost address (1 = PASS, 2 = FAIL) and spins.
    .section .text.init, "ax"
    .globl _start
_start:
    li   sp, 0x80008000        // top of 32 KB DRAM
    li   gp, 0
    call main
    li   t0, 0x20000000        // tohost
    sw   a0, 0(t0)
1:  j    1b
