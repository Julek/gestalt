#ifndef STACK_PROTECTOR_H
#define STACK_PROTECTOR_H

extern void * __stack_chk_guard;

// extern void __stack_chk_guard_setup() __attribute__ ((constructor));
extern void __stack_chk_fail() __attribute__ ((noreturn));

#endif
