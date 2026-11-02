ENTRY(roemu_entry)
PHDRS {
  code PT_LOAD FLAGS(5);
  data PT_LOAD FLAGS(6);
  tls PT_TLS FLAGS(4);
}
SECTIONS {
  . = 0x10000;
  .text : { *(.text .text.*) } :code
  .rodata : { *(.rodata .rodata.*) } :code
  . = 0x20000;
  .opd : { *(.opd) } :data
  .toc : { *(.toc .toc.*) *(.got) *(.branch_lt) } :data
  .data : { *(.data .data.*) } :data
  .tdata ALIGN(16) : { *(.tdata .tdata.*) } :data :tls
  .tbss ALIGN(8) : { *(.tbss .tbss.*) } :data :tls
  .bss ALIGN(16) : { *(.bss .bss.*) *(COMMON) } :data
  /DISCARD/ : { *(.eh_frame) *(.comment) *(.note.GNU-stack) }
}
