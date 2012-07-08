#include <access.h>
#include <linker_symbols.h>
#include <stdbool.h>
#include <stdio.h>
#include <paging.h>

unsigned int __attribute__ ((aligned(4096))) page_tables [1024][1024] = {[0 ... 1023] = {[0 ... 1023] = 0}};

unsigned int __attribute__ ((aligned(4096))) page_directory[1024] = {[0 ... 1023] = 0};

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

  return ;
}

bool map_page(unsigned int virt_addr, unsigned int phys_addr, unsigned short config)
{
  int page_num = (virt_addr >> 12);
  page_tables[page_num/1024][page_num%1024] = phys_addr | config;

  return True;
}

void enable_paging()
{
    __asm__ __volatile__ ("mov %%eax, (%0);\n mov %%cr3, %%eax;\n mov %%eax, %%cr0;\n or %%eax, 0x80000000;\n mov %%cr0, %%eax" :: "g" (page_directory) : "%eax");
  return;
}
