#include <stdio.h>
#include <system.h>
#include <pic.h>

void pic_remap()
{
  unsigned char a = inb(0x21);
  unsigned char b = inb(0xA1);
  
  outb(0x20, 0x11);
  for(int i = 0; i < 100000; i++);
  outb(0xA0, 0x11);
  for(int i = 0; i < 100000; i++);
  outb(0x21, PIC_BASE);
  for(int i = 0; i < 100000; i++);
  outb(0xA1, PIC_BASE + 7);
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
  
  return;
}
