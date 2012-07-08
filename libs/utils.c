#include <stdio.h>

void print_mem(unsigned int mem)
{
  if(mem > 1024 * 1024 * 1024)
    print("%uGB", mem / (1024 * 1024 * 1024));
  else if(mem > 1024 * 1024)
    print("%uMB", mem / (1024 * 1024));
  else if(mem > 1024)
    print("%uKB", mem / 1024);
  else
    print("%uB", mem);
  return;
}
