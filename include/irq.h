#ifndef IRQ_H
#define IRQ_H

#include <regs.h>
#include <stdbool.h>

extern bool install_irq_handler(unsigned char irq, void (*handler)(regs *r));
extern bool uninstall_irq_handler(unsigned char irq);

#endif
