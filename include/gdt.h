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

enum segment {k_text = 0, k_data = 1, k_rodata = 2, d_text = 3, d_data = 4, d_rodata = 5, s_text = 6, s_data = 7, s_rodata = 8, a_text = 9, a_data = 10, a_rodata = 11};
//k = kernel, d = driver, s = subkernel, a = application.

typedef enum segment segment;

extern void gdt_init();

extern bool set_segments(segment code, segment data);

#endif
