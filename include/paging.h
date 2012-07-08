#ifndef PAGING_H
#define PAGING_H

#include <stdbool.h>

extern void setup_page_dir();
extern void map_kernel();
extern void enable_paging();

extern bool map_page(unsigned int page_num, unsigned int phys_addr, unsigned short config);

#endif
