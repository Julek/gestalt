all:
	sudo make build &> /dev/null

build: gestalt.iso
	ndisasm -u kernel.bin > out.txt 
	rm -f *.o *.bin
	cloc kernel.c loader.asm makefile ./include/* ./libs/* --by-file-by-lang > report.txt

loader.o : loader.asm
	nasm -f elf -o loader.o loader.asm

kernel.o : kernel.c
	i586-elf-gcc -o kernel.o -c kernel.c -Wall -Wextra -Werror -nostdlib -nostartfiles -nodefaultlibs -std=c99 -fstack-protector-all -masm=intel -I ./include

stdio.o : ./libs/stdio.c
	i586-elf-gcc -o stdio.o -c ./libs/stdio.c -Wall -Wextra -Werror -nostdlib -nostartfiles -nodefaultlibs -std=c99 -fstack-protector-all -I ./include

system.o : ./libs/system.c
	i586-elf-gcc -o system.o -c ./libs/system.c -Wall -Wextra -Werror -nostdlib -nostartfiles -nodefaultlibs -std=c99 -masm=intel -fstack-protector-all -I ./include

gdt.o : ./libs/gdt.c
	i586-elf-gcc -o gdt.o -c ./libs/gdt.c -Wall -Wextra -nostdlib -nostartfiles -nodefaultlibs -std=c99 -masm=intel -fstack-protector-all -I ./include

paging.o : ./libs/paging.c
	i586-elf-gcc -o paging.o -c ./libs/paging.c -Wall -Wextra -Werror -nostdlib -nostartfiles -nodefaultlibs -std=c99 -fstack-protector-all -I ./include

idt.o : ./libs/idt.c
	i586-elf-gcc -o idt.o -c ./libs/idt.c -Wall -Wextra -Werror -nostdlib -nostartfiles -nodefaultlibs -std=c99 -fstack-protector-all -I ./include

isr.o : ./libs/isr.c
	i586-elf-gcc -o isr.o -c ./libs/isr.c -Wall -Wextra -Werror -nostdlib -nostartfiles -nodefaultlibs -std=c99 -fstack-protector-all -masm=intel -I ./include

isr_a.o : ./libs/isr.asm
	nasm -f elf -o isr_a.o ./libs/isr.asm

system_a.o : ./libs/system.asm
	nasm -f elf -o system_a.o ./libs/system.asm

stack_protector.o : ./libs/stack_protector.c
	i586-elf-gcc -o stack_protector.o -c ./libs/stack_protector.c -Wall -Wextra -Werror -nostdlib -nostartfiles -nodefaultlibs -std=c99 -masm=intel -fstack-protector-all -I ./include	

pic.o : ./libs/pic.c
	i586-elf-gcc -o pic.o -c ./libs/pic.c -Wall -Wextra -Werror -nostdlib -nostartfiles -nodefaultlibs -std=c99 -fstack-protector-all -I ./include

kernel.bin : loader.o kernel.o stdio.o system.o gdt.o paging.o idt.o isr.o isr_a.o system_a.o stack_protector.o pic.o
	i586-elf-ld -T linker.ld -o kernel.bin loader.o kernel.o stdio.o system.o gdt.o paging.o idt.o isr.o isr_a.o system_a.o stack_protector.o pic.o

gestalt.iso : kernel.bin ./isofiles/boot/grub/stage2_eltorito
	sudo cp ./kernel.bin ./isofiles/boot/
	sudo genisoimage -R -b boot/grub/stage2_eltorito -no-emul-boot -boot-load-size 4 -boot-info-table -input-charset utf-8 -o gestalt.iso isofiles

commit:
	git add ./libs/*.c ./libs/*.asm
	git add ./include/*.h
	git commit -a -m "auto-commit"
	git push
