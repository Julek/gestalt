#include <interrupt_handler.h>
#include <pic.h>
#include <regs.h>
#include <stdbool.h>
#include <irq.h>

bool install_irq_handler(unsigned char int_no, void (*handler)(regs *r))
{
  
  if((int_no <= PIC_BASE) && ((int_no - PIC_BASE) >= 16))
    return false;
  
  int_routines[int_no] = handler;

  return true;

}

bool uninstall_irq_handler(unsigned char int_no)
{

  if((int_no <= PIC_BASE) && ((int_no - PIC_BASE) >= 16))
    return false;

  int_routines[int_no] = 0;

  return true;
}

