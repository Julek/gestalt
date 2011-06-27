all:
	sudo make build > /dev/null

build: virginix.iso
	rm -f loader.o kernel.o stdio.o system.o kernel.bin

loader.o : loader.asm
	nasm -f elf -o loader.o loader.asm

kernel.o : kernel.c
	i586-elf-gcc -o kernel.o -c kernel.c -Wall -Wextra -Werror -nostdlib -nostartfiles -nodefaultlibs -std=c99 -I ./include

stdio.o : ./libs/stdio.c
	i586-elf-gcc -o stdio.o -c ./libs/stdio.c -Wall -Wextra -Werror -nostdlib -nostartfiles -nodefaultlibs -std=c99 -I ./include

system.o : ./libs/system.c
	i586-elf-gcc -o system.o -c ./libs/system.c -Wall -Wextra -Werror -nostdlib -nostartfiles -nodefaultlibs -std=c99 -I ./include

gdt.o : ./libs/gdt.c
	i586-elf-gcc -o gdt.o -c ./libs/gdt.c -Wall -Wextra -Werror -nostdlib -nostartfiles -nodefaultlibs -std=c99 -I ./include

kernel.bin : loader.o kernel.o stdio.o system.o gdt.o
	i586-elf-ld -T linker.ld -o kernel.bin loader.o kernel.o stdio.o system.o

virginix.iso : kernel.bin ./isofiles/boot/grub/stage2_eltorito
	sudo cp ./kernel.bin ./isofiles/boot/
	sudo genisoimage -R -b boot/grub/stage2_eltorito -no-emul-boot -boot-load-size 4 -boot-info-table -input-charset utf-8 -o virginix.iso isofiles

commit:
	git add ./libs/*.c
	git add ./include/*.h
	git commit -a -m "auto-commit"
	git push
