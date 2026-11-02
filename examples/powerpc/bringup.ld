ENTRY(roemu_entry)
SECTIONS {
  . = 0x10000;
  .text : { *(.text .text.*) }
  . = ALIGN(0x1000);
  .rodata : { *(.rodata .rodata.*) }
  .opd : { *(.opd) }
  .toc : { *(.toc .toc.*) }
  . = ALIGN(0x1000);
  .data : { *(.data .data.*) }
  .bss : { *(.bss .bss.*) *(COMMON) }
  /DISCARD/ : { *(.eh_frame) *(.comment) *(.note.GNU-stack) }
}
