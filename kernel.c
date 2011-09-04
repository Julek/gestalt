#include <stdio.h>
#include <gdt.h>
#include <idt.h>
#include <paging.h>
#include <isr.h>
#include <pic.h>
#include <stack_protector.h>

void k_main(void* multi_data, unsigned int magic)
{
  if(magic != 0x2BADB002)
    return;
  multi_data++;
  clear_screen();
  print("Gestalt OS v 0.0.1 beta booting.\n\n");
  gdt_init();
  PIC_remap();
  isrs_install();
  /*unsigned int before, after;
  __asm__ __volatile__ ("mov (%0), %%esp;\n push byte;\n mov (%1), %%esp;\n push byte;\n pop %%ax;\n" : "=g" (before), "=g" (after):: "%eax" );
  print("before: %u\nafter: %u\n", before, after);*/
 return;
}
