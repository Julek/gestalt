#include <stdio.h>

void k_main(void* multi_data, unsigned int magic)
{
  if(magic != 0x2BADB002)
    return;
  multi_data++;
  clear_screen();
  print("Hello world!!!\n");
  print("Test.");
  gotoxy(0, 4);
  print("Re-test.");
  set_cursor(100);
  return;
}
