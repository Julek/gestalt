#include <system.h>
#include <stdio.h>

void PIC_remap()
{
  print("Remapping PICs...\n");
  unsigned char a = inb(0x21);
  unsigned char b = inb(0xA1);
  
  outb(0x20, 0x11);
  for(int i = 0; i < 100000; i++);
  outb(0xA0, 0x11);
  for(int i = 0; i < 100000; i++);
  outb(0x21, 32);
  for(int i = 0; i < 100000; i++);
  outb(0xA1, 39);
  for(int i = 0; i < 100000; i++);
  outb(0x21, 4);
  for(int i = 0; i < 100000; i++);
  outb(0xA1, 2);
  for(int i = 0; i < 100000; i++);
  
  outb(0x21, 0x01);
  for(int i = 0; i < 100000; i++);
  outb(0xA1, 0x01);
  for(int i = 0; i < 100000; i++);

  outb(0x21, a);
  outb(0xA1, b);

  print("PICs remapped.\n");

  return;
}
