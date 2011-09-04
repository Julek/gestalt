#include <isr.h>
#include <idt.h>
#include <system.h>
#include <stdio.h>

extern void isr0();
extern void isr1();
extern void isr2();
extern void isr3();
extern void isr4();
extern void isr5();
extern void isr6();
extern void isr7();
extern void isr8();
extern void isr9();
extern void isr10();
extern void isr11();
extern void isr12();
extern void isr13();
extern void isr14();
extern void isr15();
extern void isr16();
extern void isr17();
extern void isr18();
extern void isr19();
extern void isr20();
extern void isr21();
extern void isr22();
extern void isr23();
extern void isr24();
extern void isr25();
extern void isr26();
extern void isr27();
extern void isr28();
extern void isr29();
extern void isr30();
extern void isr31();

char* exceptions[32] = {
  "Division By Zero Exception\n",
  "Debug Exception\n",
  "Non Maskable Interrupt Exception\n",
  "Breakpoint Exception\n",
  "Into Detected Overflow Exception\n",
  "Out of Bounds Exception\n",
  "Invalid Opcode Exception\n",
  "No Coprocessor Exception\n",
  "Double Fault Exception\n",
  "Coprocessor Segment Overrun Exception\n",
  "Bad TSS Exception\n",
  "Segment Not Present Exception\n",
  "Stack Fault Exception\n",
  "General Protection Fault Exception\n",
  "Page Fault Exception\n",
  "x87 FPU Floating-Point Error\n",
  "Coprocessor Fault Exception\n",
  "Alignment Check Exception\n",
  "Machine Check Exception\n",
  "SIMD floating point exception\n",
  "Reserved Exceptions\n",
  "Reserved Exceptions\n",
  "Reserved Exceptions\n",
  "Reserved Exceptions\n",
  "Reserved Exceptions\n",
  "Reserved Exceptions\n",
  "Reserved Exceptions\n",
  "Reserved Exceptions\n",
  "Reserved Exceptions\n",
  "Reserved Exceptions\n",
  "Reserved Exceptions\n",
  "Reserved Exceptions\n"};

void isrs_install()
{
  print("Setting up IDT.\n");
  setup_idt();
  print("Adding ISRs to IDT.\n");
  add_kint(0, (unsigned int)isr0, 0x08);
  add_kint(1, (unsigned int)isr1, 0x08);
  add_kint(2, (unsigned int)isr2, 0x08);
  add_kint(3, (unsigned int)isr3, 0x08);
  add_kint(4, (unsigned int)isr4, 0x08);
  add_kint(5, (unsigned int)isr5, 0x08);
  add_kint(6, (unsigned int)isr6, 0x08);
  add_kint(7, (unsigned int)isr7, 0x08);
  add_kint(8, (unsigned int)isr8, 0x08);
  add_kint(9, (unsigned int)isr9, 0x08);
  add_kint(10, (unsigned int)isr10, 0x08);
  add_kint(11, (unsigned int)isr11, 0x08);
  add_kint(12, (unsigned int)isr12, 0x08);
  add_kint(13, (unsigned int)isr13, 0x08);
  add_kint(14, (unsigned int)isr14, 0x08);
  add_kint(15, (unsigned int)isr15, 0x08);
  add_kint(16, (unsigned int)isr16, 0x08);
  add_kint(17, (unsigned int)isr17, 0x08);
  add_kint(18, (unsigned int)isr18, 0x08);
  add_kint(19, (unsigned int)isr19, 0x08);
  add_kint(20, (unsigned int)isr20, 0x08);
  add_kint(21, (unsigned int)isr21, 0x08);
  add_kint(22, (unsigned int)isr22, 0x08);
  add_kint(23, (unsigned int)isr23, 0x08);
  add_kint(24, (unsigned int)isr24, 0x08);
  add_kint(25, (unsigned int)isr25, 0x08);
  add_kint(26, (unsigned int)isr26, 0x08);
  add_kint(27, (unsigned int)isr27, 0x08);
  add_kint(28, (unsigned int)isr28, 0x08);
  add_kint(29, (unsigned int)isr29, 0x08);
  add_kint(30, (unsigned int)isr30, 0x08);
  add_kint(31, (unsigned int)isr31, 0x08);
  print("Switching to new IDT.\n");
  lidt();
  cli();
  sti();
  print("Switched to new IDT and interupts are on.\n");
  return;
}

typedef struct regs regs;

struct regs
{
    unsigned int gs, fs, es, ds;
    unsigned int edi, esi, ebp, esp, ebx, edx, ecx, eax;
    unsigned int int_no, err_code;
    unsigned int eip, cs, eflags, useresp, ss;
} __attribute__ ((packed));

void error_handler(regs* r)
{
  if(r->int_no < 32)
    {
      print("\n%s", exceptions[r->int_no]);
      print("eip: %h\nSystem Halting!!!\n", r->eip);
      kill();
    }
  return;
}
