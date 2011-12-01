#ifndef ISR_H
#define ISR_H

#include <regs.h>
#include <stdbool.h>

extern bool install_isr_handler(unsigned char int_no, void (*handler)(regs *r));
extern bool uninstall_isr_handler(unsigned char int_no );

#endif
