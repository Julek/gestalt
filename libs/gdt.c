#include <gdt.h>
#include <stdbool.h>
#include <stdio.h>

gdt_entry table[8192];
gdt_descriptor desc = {.size = 0, .offset = (unsigned int)&table};

const unsigned char access_bytes[] = {0x9A, 0x92, 0x90, 0x92, 0xBA, 0xB2, 0xB0, 0xB2, 0xDA, 0xD2, 0xD0, 0xD2, 0xFA, 0xF2, 0xF0, 0xF2} ;

bool gdt_started = False;

void start_gdt()
{
  table[0].limit_b = 0;
  table[0].base_b = 0;
  table[0].base_tb = 0;
  table[0].access = 0;
  table[0].flags_limt = 0;
  table[0].base_tt = 0;
  if(desc.size == 0)
    desc.size = 7;
  
  gdt_started = True;

  return;
}



bool add_gdt_entry(unsigned int base, unsigned int limit, entry_type t)
{
  if(limit >= 1048576)
    return False;

  if(t > 15)
    return False;

  if(!gdt_started)
    start_gdt();

  gdt_entry* curr = &table[(desc.size + 1)/8];
  curr->limit_b = (unsigned short)(limit & 0x0000FFFF);
  curr->base_b = (unsigned short)(base & 0x0000FFFF);
  curr->base_tb = (unsigned char)((base & 0x00FF0000) >> 16);
  curr->access = access_bytes[t];
  curr->flags_limt = 0xC0 | ((0xF0000 & limit) >> 16);
  curr->base_tt = (unsigned char)((base & 0xFF000000) >> 24);
  
  desc.size += 8;
  
  return True;
}

void lgdt()
{
  __asm__ __volatile__ ("lgdt (%0)"::"m"(desc));
  __asm__ __volatile__ ("movl $0x10, %%eax;\n movl %%eax, %%ds;\n movl %%eax, %%ss;\n movl %%eax, %%es;\n movl %%eax, %%fs;\n movl %%eax, %%gs;\n" ::: "%eax");
  __asm__ __volatile__ ("pushl $0x08;\n");
  __asm__ __volatile__ ("lea jump, %%eax;\n pushl %%eax;\n lret;\n" ::: "%eax");
  __asm__ __volatile__ ("jump:");
  print("GDT and segment registers succesfully updated.\n");
  return;
}
