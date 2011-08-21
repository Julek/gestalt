#include <stdio.h>
#include <gdt.h>
#include <idt.h>
#include <paging.h>
#include <isr.h>

void k_main(void* multi_data, unsigned int magic)
{
  if(magic != 0x2BADB002)
    return;
  multi_data++;
  clear_screen();
  print("Gestalt OS v 0.0.1 beta booting.\n\n");
  gdt_init();
 return;
}
