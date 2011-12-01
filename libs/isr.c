#include <interrupt_handler.h>
#include <regs.h>
#include <stdbool.h>
#include <isr.h>

bool install_isr_handler(unsigned char int_no, void (*handler)(regs *r))
{

  if(int_no >= 32)
    return False;

  int_routines[int_no] = handler;
  
  return True;

}

bool uninstall_isr_handler(unsigned char int_no)
{

  if(int_no >= 32)
    return False;

  int_routines[int_no] = 0;

  return True;

}

