#include <stack_protector.h>
#include <system.h>
#include <stdsymbols.h>

void * __stack_chk_guard = NULL;

void __stack_chk_guard_setup()
{
  *((unsigned int*)(&__stack_chk_guard)) = 0x00000aff;
  return;
}

void __stack_chk_fail()
{
  __asm__ __volatile__ ("int 0x0C");
  kill();
}
