all:
	sudo make build &> /dev/null

build: virginix.iso
	ndisasm -u kernel.bin > out.txt 
	rm -f *.o *.bin

loader.o : loader.asm
	nasm -f elf -o loader.o loader.asm

kernel.o : kernel.c
	i586-elf-gcc -o kernel.o -c kernel.c -Wall -Wextra -Werror -nostdlib -nostartfiles -nodefaultlibs -std=c99 -I ./include

stdio.o : ./libs/stdio.c
	i586-elf-gcc -o stdio.o -c ./libs/stdio.c -Wall -Wextra -Werror -nostdlib -nostartfiles -nodefaultlibs -std=c99 -I ./include

system.o : ./libs/system.c
	i586-elf-gcc -o system.o -c ./libs/system.c -Wall -Wextra -Werror -nostdlib -nostartfiles -nodefaultlibs -std=c99 -masm=intel -I ./include

gdt.o : ./libs/gdt.c
	i586-elf-gcc -o gdt.o -c ./libs/gdt.c -Wall -Wextra -nostdlib -nostartfiles -nodefaultlibs -std=c99 -masm=intel -I ./include

paging.o : ./libs/paging.c
	i586-elf-gcc -o paging.o -c ./libs/paging.c -Wall -Wextra -Werror -nostdlib -nostartfiles -nodefaultlibs -std=c99 -I ./include

idt.o : ./libs/idt.c
	i586-elf-gcc -o idt.o -c ./libs/idt.c -Wall -Wextra -Werror -nostdlib -nostartfiles -nodefaultlibs -std=c99 -I ./include

isr.o : ./libs/isr.c
	i586-elf-gcc -o isr.o -c ./libs/isr.c -Wall -Wextra -Werror -nostdlib -nostartfiles -nodefaultlibs -std=c99 -I ./include

isr_a.o : ./libs/isr.asm
	nasm -f elf -o isr_a.o ./libs/isr.asm

system_a.o : ./libs/system.asm
	nasm -f elf -o system_a.o ./libs/system.asm

kernel.bin : loader.o kernel.o stdio.o system.o gdt.o paging.o idt.o isr.o isr_a.o system_a.o
	i586-elf-ld -T linker.ld -o kernel.bin loader.o kernel.o stdio.o system.o gdt.o paging.o idt.o isr.o isr_a.o system_a.o

virginix.iso : kernel.bin ./isofiles/boot/grub/stage2_eltorito
	sudo cp ./kernel.bin ./isofiles/boot/
	sudo genisoimage -R -b boot/grub/stage2_eltorito -no-emul-boot -boot-load-size 4 -boot-info-table -input-charset utf-8 -o virginix.iso isofiles

commit:
	git add ./libs/*.c ./libs/*.asm
	git add ./include/*.h
	git commit -a -m "auto-commit"
	git push
