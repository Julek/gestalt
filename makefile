CC=i586-elf-gcc
ASM=nasm
CFLAGS= -c -Wall -Wextra -nostdlib -nostartfiles -nodefaultlibs -std=c99 -fstack-protector-all -masm=intel -I ./include
AFLAGS= -f elf
CSOURCES=$(wildcard ./libs/*.c)
ASOURCES=$(wildcard ./libs/*.asm)
COBJECTS=$(CSOURCES:.c=_c.o)
AOBJECTS=$(ASOURCES:.asm=_a.o)

all:
	make build &> /dev/null

build: gestalt.iso
	ndisasm -u kernel.bin > out.txt 
	rm -f *.o *.bin ./libs/*.o
	cloc kernel.c loader.asm makefile ./include/* ./libs/* --by-file-by-lang > report.txt


gestalt.iso : kernel.bin ./isofiles/boot/grub/stage2_eltorito
	sudo cp ./kernel.bin ./isofiles/boot/
	sudo genisoimage -R -b boot/grub/stage2_eltorito -no-emul-boot -boot-load-size 4 -boot-info-table -input-charset utf-8 -o gestalt.iso isofiles

loader.o : loader.asm
	nasm loader.asm -o loader.o $(AFLAGS)

kernel.o : kernel.c
	$(CC) kernel.c -o kernel.o $(CFLAGS)

%_c.o: %.c
	$(CC) $< -o $@ $(CFLAGS)

%_a.o: %.asm
	$(ASM) $< -o $@ $(AFLAGS)

kernel.bin : loader.o kernel.o $(COBJECTS) $(AOBJECTS)
	i586-elf-ld loader.o kernel.o $(COBJECTS) $(AOBJECTS) -o kernel.bin -T linker.ld

commit:
	git add ./libs/*.c ./libs/*.asm
	git add ./include/*.h
	git commit -a -m "auto-commit"
	git push
