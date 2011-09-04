#include <system.h>
#include <stdio.h>

unsigned char inb(unsigned short port)
{
  unsigned char ret;
  __asm__ __volatile__ ( "inb %0, %1" : "=a"(ret) : "Nd"(port)); 
 return ret;
}

void outb(unsigned short port, unsigned char val)
{
  __asm__ __volatile__ ("outb %1, %0" : : "a"(val), "Nd"(port));
  return;
}

void cli()
{
  __asm__ __volatile__ ("cli");
  return;
}

void sti()
{
  print("Test1\n");
  __asm__ __volatile__ ("sti");
  print("Test2");
  return;
}
