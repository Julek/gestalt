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
  if(add_gdt_entry(0, 0xFFFFF, d_text))
    print("Driver code segment descriptor added to GDT.\n");
  else
    {
      print("Error: Driver code segment descriptor was not succesfully added to GDT. Halting.\n");
      return;
    }
  if(add_gdt_entry(0, 0xFFFFF, d_data))
    print("Driver data segment descriptor added to GDT.\n");
  else
    {
      print("Error: Driver data segment descriptor was not succesfully added to GDT. Halting.\n");
      return;
    }
 if(add_gdt_entry(0, 0xFFFFF, s_text))
   print("Sub-kernel code segment descriptor added to GDT.\n");
 else
   {
     print("Error: Sub-kernel code segment descriptor was not succesfully added to GDT. Halting.\n");
     return;
   }
 if(add_gdt_entry(0, 0xFFFFF, s_data))
   print("Sub-kernel data segment descriptor added to GDT.\n");
 else
   {
     print("Error: Sub-kernel data segment descriptor was not succesfully added to GDT. Halting.\n");
     return;
   }
 if(add_gdt_entry(0, 0xFFFFF, a_text))
   print("Application code segment descriptor added to GDT.\n");
 else
   {
     print("Error: Application code segment descriptor was not succesfully added to GDT. Halting.\n");
     return;
   }
 if(add_gdt_entry(0, 0xFFFFF, a_data))
   print("Application data segment descriptor added to GDT.\n");
 else
   {
     print("Error: Application data segment descriptor was not succesfully added to GDT. Halting.\n");
     return;
   }
 lgdt();
 return;
}
