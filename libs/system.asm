[BITS 32]

global kill

section .text
	
kill:	
	cli
	
hang:
	hlt
	jmp hang
	
