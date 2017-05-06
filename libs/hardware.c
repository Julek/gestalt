#include <stdio.h>
#include <multiboot.h>

unsigned int total_memory, total_available_memory;

void detect_hardware(multiboot_info_t* multi_data)
{

  unsigned int usable_pages = 0;

  unsigned int max_mem = 0;

  if(multi_data->flags & 0x01)
    {
      // print("mem_lower: %u\n", multi_data->mem_lower);
      // print("mem_upper: %u\n", multi_data->mem_upper);
      // print("Total contiguous memory: %ukB.\n", (multi_data->mem_upper - multi_data->mem_lower));
      if(multi_data->flags & 0x20)
	{
	  memory_map_t *mmap = (memory_map_t*)multi_data->mmap_addr;
	  for(int i = 1; (unsigned int)mmap < multi_data->mmap_addr + multi_data->mmap_length; i++)
	    {
	      if(mmap->type == 1)
		{
		  // print("Segment %u:\n", i);
		  // print("base address: %h.\n", mmap->base_addr_low);
		  // print("number of pages: %u.\n", mmap->length_low/4096);
		  usable_pages += (mmap->length_low/4096);
		  if((mmap->base_addr_low + mmap->length_low) > max_mem)
		    max_mem = mmap->base_addr_low + mmap->length_low;
		}
	      mmap = (memory_map_t*)((unsigned int)mmap +mmap->size + sizeof(unsigned int));
	    }
	}
    }

  print("Total usable pages: %u\n", usable_pages);

  print("Total usable memory: %uMB",  usable_pages / 256 );
}
