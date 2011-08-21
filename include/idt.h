#ifndef IDT_H
#define IDT_H

typedef struct idt_descriptor idt_descriptor;

struct idt_descriptor
{
  unsigned short limit;
  unsigned int address;
} __attribute__ ((packed));

typedef struct idt_entry idt_entry;

struct idt_entry
{
  unsigned short offset_b;
  unsigned short selector;
  char zero;
  unsigned char attr;
  unsigned short offset_t;
} __attribute__ ((packed));

extern void setup_idt();

extern void add_kint(unsigned char no, unsigned int offset, unsigned short selector);

extern void lidt();

#endif
