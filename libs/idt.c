#include <stdbool.h>
#include <idt.h>

idt_entry IDT[256];
idt_descriptor idt_desc = {.limit = (256*8), .address = (unsigned int)&IDT};

bool idt_started = false;

void setup_idt()
{
  if(idt_started)
    return;
  for(int i = 0; i < 256; i++)
    IDT[i].attr = (unsigned char)0;
  idt_started = true;
  return;
}

void install_kint(unsigned char no, unsigned int offset, unsigned short selector)
{
  idt_entry* curr = &IDT[no];
  curr->offset_b = (unsigned short)(offset & 0xFFFF);
  curr->selector = selector;
  curr->zero = 0;
  curr->attr = 0x8E;
  curr->offset_t = (unsigned short)((offset & 0xFFFF0000) >> 16);
  return;
}

void lidt()
{
  __asm__ __volatile__ ("lidt (%0)" :: "m" (idt_desc));
  return;
}
