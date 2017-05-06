#include <access.h>
#include <linker_symbols.h>
#include <multiboot.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <paging.h>

void setup_page_dir();
void map_kernel();

void enable_paging();

bool map_page(unsigned int page_num, unsigned int phys_addr, unsigned short config);
bool unmap_page(unsigned int virt_addr);

volatile int page_allocation_lock = 0;

unsigned int __attribute__ ((aligned(4096))) page_tables [1024][1024] = {[0 ... 1023] = {[0 ... 1023] = 0}};

unsigned int __attribute__ ((aligned(4096))) page_directory[1024] = {[0 ... 1023] = 0};

enum page_state {HARDWARE = 0, NO_MEM = 1, ALLOCATED = 2, UNALLOCATED = 3};

unsigned int page_allocation_tables[1024*1024] = {[0 ... (1024*1024 - 1)] = (NO_MEM << 30)};

void setup_page_dir()
{
  
  for(unsigned int i  = 0; i < 1024; ++i)
      page_directory[i] = ((unsigned int)&page_tables[i]) | 3;
  
  return;
}

void map_kernel()
{

  for(unsigned int i = (stext >> 12); i < (srodata >> 12); ++i)
    page_tables[i/1024][i%1024] = (i << 12) | 1;

  for(unsigned int i = (srodata >> 12); i < (sdata >> 12); ++i)
    page_tables[i/1024][i%1024] = (i << 12) | 1;

  for(unsigned int i = (sdata >> 12); i < (sbss >> 12); ++i)
    page_tables[i/1024][i%1024] = (i << 12) | 3;

  for(unsigned int i = (sbss >> 12); i < (end >> 12); ++i)
    page_tables[i/1024][i%1024] = (i << 12) | 3;

  return;
}

void enable_paging()
{
    __asm__ __volatile__ ("mov %%eax, (%0);\n mov %%cr3, %%eax;\n mov %%eax, %%cr0;\n or %%eax, 0x80000000;\n mov %%cr0, %%eax" :: "g" (page_directory) : "%eax");
  return;
}

bool map_page(unsigned int virt_addr, unsigned int phys_addr, unsigned short config)
{

  if((virt_addr & 0xFFF) && (phys_addr & 0xFFF) && (config & 3)) {
    return false;
  }
  
  int page_num = (virt_addr >> 12);
  page_tables[page_num/1024][page_num%1024] = phys_addr | config;

  return true;
}


bool unmap_page(unsigned int virt_addr)
{

  if(virt_addr & 0xFFF) {
    return false;
  }
  
  int page_num = (virt_addr >> 12);
  page_tables[page_num/1024][page_num%1024] = 0;

  return true;
}

bool setup_paging(multiboot_info_t* multi_data)
{
  if (!(multi_data -> flags | 32)) {
    print("Error: Multiboot data does not contain memory map.");
    return false;
  }
  
  unsigned long mmap_length = multi_data->mmap_length;
  char* mmap_base_addr = (char*)multi_data->mmap_addr;
  memory_map_t* mmap_curr;

  
  for(char* mmap_curr_addr = mmap_base_addr;
      ((unsigned long)(mmap_curr_addr - mmap_base_addr)) < mmap_length;
      mmap_curr_addr += (mmap_curr->size + sizeof(unsigned long))) {

    mmap_curr = (memory_map_t*)mmap_curr_addr;

    /* print("mmap info:\n"); */
    /* print("- size: %ul\n- base_addr_low: %ul\n- base_addr_high: %ul\n- length_low: %ul\n- length_high: %ul\n- type: %ul\n", */
    /* 	  mmap_curr->size, */
    /* 	  mmap_curr->base_addr_low, */
    /* 	  mmap_curr->base_addr_high, */
    /* 	  mmap_curr->length_low, */
    /* 	  mmap_curr->length_high, */
    /* 	  mmap_curr->type); */
    
    if(mmap_curr->base_addr_high == 0) {
      
      unsigned long begin_addr = mmap_curr->base_addr_low;
      unsigned long end_addr;
      
      if(mmap_curr->length_high != 0
	 || __builtin_uaddl_overflow(
				      mmap_curr->base_addr_low,
				      mmap_curr->length_low,
				      &end_addr))
	{
	  end_addr = 0xFFFFFFFF;
	}

      unsigned long begin_page = (begin_addr >> 12) + ((begin_addr & 0xFFF)?1:0);
      unsigned long end_page = end_addr >> 12;

      for(unsigned long i = begin_page; i < end_page; ++i) {
	page_allocation_tables[i] = ((mmap_curr->type == 1)?UNALLOCATED:HARDWARE) << 30;
      }
      
      // print("- begin address: %ul, end_address: %ul, begin page: %ul, end page: %ul, type: %s.\n", begin_addr, end_addr, begin_page, end_page, (mmap_curr->type == 1)?"UNALLOCATED":"HARDWARE");
      
    }
      
  }
  
  for(unsigned long kernel_page = begin >> 12;
      kernel_page < (end >> 12) + ((end & 0xFFF)?1:0);
      ++kernel_page) {
    page_allocation_tables[kernel_page] = ALLOCATED << 30;
  }

  page_allocation_tables[0xb8] = ALLOCATED << 30;

  print("- Memory mapped and page allocation tables setup\n");
  
  setup_page_dir();
  print("- Page directory setup\n");

  map_kernel();
  print("- Kernel pages mapped (id).\n");

  map_page(0xb8000, 0xb8000, 3);
  print("- Video memory pages mapped (id).\n");
  
  enable_paging();
  print("- Paging enabled\n\n");
  
  return true;
}

unsigned long palloc(int num_pages) {

  unsigned long allocated_page = 1;
  
  for(; (allocated_page < 1024*1024); ++allocated_page)
    if((page_allocation_tables[allocated_page] >> 30) != UNALLOCATED) {
      int i = 1;
      for(; (i < num_pages) && (allocated_page + i < 1024*1024); ++i) {
	if((page_allocation_tables[allocated_page + i] >> 30) != UNALLOCATED) {
	  break;
	}
      }
      if(i == num_pages) {
	break;
      } else if (allocated_page + i == 1024 * 1024) {
	allocated_page = 1024 * 1024;
	break;
      } else {
	allocated_page += i;
      }
    }
  
  if(allocated_page == 1024*1024) {
    return 0;
  } else {
    for(int i = 0; i < num_pages; ++i) { 
      map_page((allocated_page + i) << 12, (allocated_page + i) << 12, 3);
      page_allocation_tables[allocated_page + i] = ALLOCATED << 30;
    }
    return allocated_page << 12;
  }
}

bool pfree(unsigned long page_address, int num_pages) {
  if(page_address & 0xFFF) {
    return false;
  }

  unsigned long page_index = page_address >> 12;

  for(int i = 0; i < num_pages; ++i) {
    if((page_allocation_tables[page_index + i] >> 30) != ALLOCATED) {
      return false;
    }
  }

  for(int i = 0; i < num_pages; ++i) {
    page_allocation_tables[page_index + i] = UNALLOCATED << 30;
  }
  
  return true;
}

void lock_allocation() {
  bool b = false;
  while(!b) {
    b = __sync_bool_compare_and_swap(&page_allocation_lock, 0, 1);
  }
  return;
}

void unlock_allocation() {
  page_allocation_lock = 0;
  return;
}
