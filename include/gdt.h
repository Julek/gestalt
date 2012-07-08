#ifndef GDT_H
#define GDT_H

#include <access.h>
#include <stdbool.h>

#define enable_segmentation() lgdt()

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

extern bool init_gdt();
extern void lgdt();

extern bool set_segment_registers(segment code, segment data);

#endif
