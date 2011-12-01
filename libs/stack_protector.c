#include <stdio.h>
#include <stdsymbols.h>
#include <system.h>
#include <stack_protector.h>

void * __stack_chk_guard = NULL;

void __stack_chk_guard_setup()
{
  
  *((unsigned int*)(&__stack_chk_guard)) = 0x00000aff;
  
  return;
}

void __stack_chk_fail()
{

  print("Stack overflow detected by stack smashing protector...\n");

  __asm__ __volatile__ ("int 0x0C");

  kill();
}
