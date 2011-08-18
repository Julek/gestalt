#ifndef SYSTEM
#define SYSTEM

extern unsigned char inb(unsigned short port);
extern void outb(unsigned short port, unsigned char val);
extern void cli();
extern void sti();

#endif
