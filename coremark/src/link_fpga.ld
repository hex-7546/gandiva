OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    ram (rwx) : ORIGIN = 0x00000000, LENGTH = 32K
}

SECTIONS {
    .text : {
        *(.text.init)
        *(.text .text.*)
        *(.rodata .rodata.*)
    } > ram

    .data : ALIGN(4) {
        _data_start = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        . = ALIGN(4);
        _data_end = .;
    } > ram
    _data_lma = LOADADDR(.data);

    .bss : ALIGN(4) {
        _bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        _bss_end = .;
    } > ram

    . = ALIGN(16);
    . += 0x2000; /* 8KB stack */
    _stack_top = .;
}
