#include <gdt.h>

gdt_entry entry;
gdt_descriptor table[65536];

const unsigned char access_bytes[] = {0x9A, 0x92, 0x90, 0x92,} ;

void set_gdt_entry(unsigned int limit, unsigned int base, enum entry_type)
{
  
  return;
}
