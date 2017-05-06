[BITS 32]

global loader
	
extern kill
extern k_main

section .text
align 4

MultiBootHeader:
	dd 0x1BADB002
	dd 3
	dd -(0x1BADB005)

loader:
	mov esp, (stack + 0x8000)
	mov ebp, esp
	push eax
	push ebx

	call k_main
	call kill
	
section .bss
align 4
stack:	
	resb 0x8000

	

