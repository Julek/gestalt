#ifndef GDT_H
#define GDT_H

#include <stdbool.h>

typedef struct gdt_descriptor gdt_descriptor;

struct gdt_descriptor
{
  unsigned short size;
  unsigned int offset;
} __attribute__ ((packed));

typedef struct gdt_entry gdt_entry;

struct gdt_entry
{
  unsigned short limit_b;
  unsigned short base_b;
  unsigned char base_tb;
  unsigned char access;
  unsigned char flags_limt;
  unsigned char base_tt;
} __attribute__ ((packed));

enum entry_type {k_text = 0, k_data = 1, k_rodata = 2, k_bss = 3, d_text = 4, d_data = 5 , d_rodata = 6, d_bss = 7, s_text = 8, s_data = 9, s_rodata = 10, s_bss = 11, a_text = 12, a_data = 13, a_rodata = 14, a_bss = 15};
//k = kernel, d = driver, s = subkernel, a = application.

typedef enum entry_type entry_type;

void start_gdt();

bool add_gdt_entry(unsigned int base, unsigned int limit, entry_type t);

void lgdt();

#endif
