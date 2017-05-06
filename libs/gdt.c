#include <access.h>
#include <gdt.h>
#include <stdbool.h>
#include <stdio.h>
#include <system.h>

gdt_entry table[8192];
gdt_descriptor gdt_desc = {.size = 0, .offset = (unsigned int)&table};

const unsigned char access_bytes[] = {0x9A, 0x92, 0x90, 0xBA, 0xB2, 0xB0, 0xDA, 0xD2, 0xD0, 0xFA, 0xF2, 0xF0} ;

bool add_gdt_entry(unsigned int base, unsigned int limit, segment t)
{
  if(limit >= 1048576)
    return false;

  if(t > 11)
    return false;

  gdt_entry* curr = &table[(gdt_desc.size + 1)/8];
  curr->limit_b = (unsigned short)(limit & 0x0000FFFF);
  curr->base_b = (unsigned short)(base & 0x0000FFFF);
  curr->base_tb = (unsigned char)((base & 0x00FF0000) >> 16);
  curr->access = access_bytes[t];
  curr->flags_limt = 0xC0 | ((0xF0000 & limit) >> 16);
  curr->base_tt = (unsigned char)((base & 0xFF000000) >> 24);
  
  gdt_desc.size += 8;
  
  return true;
}

void lgdt()
{
  __asm__ __volatile__ ("lgdt (%0)"::"g"(gdt_desc));
  return;
}



bool set_segment_registers(segment code, segment data)
{
  if((data > 11) || (code > 11))
    {
      return false;
    }
  __asm__ __volatile__ ("sal %0, 0x03;\n mov %%ds, %0;\n mov %%ss, %0;\n mov %%es, %0;\n mov %%fs, %0;\n mov %%gs, %0;\n" :: "r" (data + 1));
  __asm__ __volatile__ ("sal %0, 0x03;\n  push %0;\n lea %%eax, jump;\n push %%eax;\n lret;\n jump:\n" :: "r" (code + 1) : "%eax");
  return true;
}

bool init_gdt()
{
  
  table[0].limit_b = 0;
  table[0].base_b = 0;
  table[0].base_tb = 0;
  table[0].access = 0;
  table[0].flags_limt = 0;
  table[0].base_tt = 0;

  gdt_desc.size = 7;
  
  if(!add_gdt_entry(0, 0xFFFFF, k_text))
    {
      print("\n\nError: Kernel code segment descriptor was not succesfully added to GDT.\n\n");
      return false;
    }
  if(!add_gdt_entry(0, 0xFFFFF, k_data))
    {
      print("\n\nError: Kernel data segment descriptor was not succesfully added to GDT.\n\n");
      return false;
    }
  if(!add_gdt_entry(0, 0xFFFFF, k_rodata))
    {
      print("\n\nError: Kernel static data segment descriptor was not succesfully added to GDT.\n\n");
      return false;
    }

  if(!add_gdt_entry(0, 0xFFFFF, d_text))
    {
      print("\n\nError: Driver code segment descriptor was not succesfully added to GDT.\n\n");
      return false;
    }
  if(!add_gdt_entry(0, 0xFFFFF, d_data))
    {
      print("\n\nError: Driver data segment descriptor was not succesfully added to GDT.\n\n");
      return false;
    }
  if(!add_gdt_entry(0, 0xFFFFF, d_rodata))
    {
      print("\n\nError: Driver static data segment descriptor was not succesfully added to GDT.\n\n");
      return false;
    }

 if(!add_gdt_entry(0, 0xFFFFF, s_text))
   {
     print("\n\nError: Sub-kernel code segment descriptor was not succesfully added to GDT.\n\n");
     return false;
   }
 if(!add_gdt_entry(0, 0xFFFFF, s_data))
   {
     print("\n\nError: Sub-kernel data segment descriptor was not succesfully added to GDT.\n\n");
     return false;
   }
 if(!add_gdt_entry(0, 0xFFFFF, s_rodata))
   {
     print("\n\nError: Sub-kernel static data segment descriptor was not succesfully added to GDT.\n\n");
     return false;
   }

 if(!add_gdt_entry(0, 0xFFFFF, a_text))
   {
     print("\n\nError: Application code segment descriptor was not succesfully added to GDT.\n\n");
     return false;
   }
 if(!add_gdt_entry(0, 0xFFFFF, a_data))
   {
     print("\n\nError: Application data segment descriptor was not succesfully added to GDT.\n\n");
     return false;
   }
 if(!add_gdt_entry(0, 0xFFFFF, a_rodata))
   {
     print("\n\nError: Application static data segment descriptor was not succesfully added to GDT.\n\n");
     return false;
   }

 return true;
}
