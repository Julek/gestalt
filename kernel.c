#include <gdt.h>
#include <interrupt_handler.h>
#include <linker_symbols.h>
#include <multiboot.h>
#include <paging.h>
#include <stack_protector.h>
#include <stdio.h>

void k_main(multiboot_info_t* multi_data, unsigned int magic)
{

  if(magic != MULTIBOOT_BOOTLOADER_MAGIC)
    {
      print("Non Multiboot-compliant boot loader.\nHalting.\n");
      return;
    }

  multi_data++;

  clear_screen();

  print("Gestalt OS v 0.0.1 beta booting.\n\n");

  if(init_segmentation())    
    print("Segmentation initialised.\n");
  else
    {
      print("Error, segmentation initialisation failed.\nHalting.\n");
      return;
    }

  install_ints();
  print("Interrupts system initialised.\n");

  init_paging();

 return;
}

/*  if(multi_data->flags & 0x01)
    {
      print("Total contiguous memory: %ukB.\n", (multi_data->mem_upper - multi_data->mem_lower));
      if(multi_data->flags & 0x20)
	{
	  memory_map_t *mmap = (memory_map_t*)multi_data->mmap_addr;
	  for(int i = 1; (unsigned int)mmap < multi_data->mmap_addr + multi_data->mmap_length; i++)
	    {
	      print("Segment %u:\n", i);
	      print("base address: %h.\n", mmap->base_addr_low);
	      print("length: %h.\n", mmap->length_low);
	      print("type: %u.\n", mmap->type);
	      mmap = (memory_map_t*)((unsigned int)mmap +mmap->size + sizeof(unsigned int));
	    }
	}
    }*/
