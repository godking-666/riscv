OUTPUT_ARCH(riscv)
ENTRY(_start)
/* Program region lives in DDR3 (DDR_BASE = 0x4000_0000); source frame buffers
   start at 0x4100_0000.  SIZE IS CAPPED AT 60K: the ROM-resident UART loader
   advertises LOADER_RANDOM_MAX = 61440 bytes and refuses anything larger, so a
   bigger image would need the ROM loader rebuilt and a new bitstream.  The wide
   CNN model (23755 words) therefore stores its INT8 weights as bytes, not as
   one uint32 per byte -- see build.py. */
MEMORY { PROGRAM (rwx) : ORIGIN = 0x40000000, LENGTH = 60K }
SECTIONS {
    .text : { KEEP(*(.text.startup)) *(.text .text.*) } > PROGRAM
    .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > PROGRAM
    .data : ALIGN(4) {
        __data_start = .; *(.data .data.* .sdata .sdata.*)
        . = ALIGN(4); __data_end = .;
    } > PROGRAM
    __global_pointer$ = __data_start + 0x800;
    .bss (NOLOAD) : ALIGN(4) {
        __bss_start = .; *(.bss .bss.* .sbss .sbss.*) *(COMMON)
        . = ALIGN(4); __bss_end = .;
    } > PROGRAM
    __stack_bottom = 0x4000F000;
    __stack_top = 0x40010000;
    ASSERT(__bss_end <= __stack_bottom,"Preprocess application overlaps reserved 4KiB stack")
    /DISCARD/ : { *(.comment) *(.eh_frame .eh_frame.*) }
}

