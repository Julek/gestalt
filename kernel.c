#include <stdio.h>
#include <gdt.h>
#include <paging.h>

void k_main(void* multi_data, unsigned int magic)
{
  if(magic != 0x2BADB002)
    return;
  multi_data++;
  clear_screen();
  print("Gestalt OS v 0.0.1 beta booting.\n");
  start_gdt();
  print("\nGDT structure set up!\n");
  if(add_gdt_entry(0, 0xFFFFF, k_text))
    print("Kernel code segment descriptor added to GDT.\n");
  else
    {
      print("Error: Kernel code segment descriptor was not succesfully added to GDT. Halting.\n");
      return;
    }
  if(add_gdt_entry(0, 0xFFFFF, k_data))
    print("Kernel data segment descriptor added to GDT.\n");
  else
    {
      print("Error: Kernel data segment descriptor was not succesfully added to GDT. Halting.\n");
      return;
    }
  lgdt();
  return;
}
