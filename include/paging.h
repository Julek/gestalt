#ifndef PAGING_H
#define PAGING_H

#include <stdbool.h>
#include <multiboot.h>

bool setup_paging(multiboot_info_t* multi_data);

unsigned long palloc(int num_pages);
bool pfree(unsigned long page_address, int num_pages);

void lock_allocation();
void unlock_allocation();

#endif
