#include <gdt.h>
#include <interrupt_handler.h>
#include <liballoc.h>
#include <linker_symbols.h>
#include <multiboot.h>
#include <paging.h>
#include <stack_protector.h>
#include <stdio.h>

void k_main(multiboot_info_t* multi_data __attribute__ ((unused)), unsigned int magic)
{
  
  if(magic != MULTIBOOT_BOOTLOADER_MAGIC)
    {
      print("Non Multiboot-compliant boot loader.\nHalting.\n");
      return;
    }

  clear_screen();

  //print("Gestalt OS v 0.0.1 beta booting.\n\n");
  
  print("Gestalt OS initial build\n");


  print("\nSegmentation:\n");
  if(init_gdt())    
    print("- GDT initialised.\n");
  else
    {
      clear_screen();
      print("Error, segmentation initialisation failed.\nHalting.\n");
      return;
    }

  enable_segmentation();
  print("- GDT loaded.\n");

   if(set_segment_registers(k_text, k_data))
     print("- Segment registers updated\n");
   else
   {
     clear_screen();
     print("Error: Invalid segment descriptor offsets.\nHalting.\n");
     return;
   }

  print("\nPaging:\n");

  if(!setup_paging(multi_data)) {
    print("Error: Paging initialization failure.\nHalting.\n");
    return; 
  }
  
  print("Interrupts:\n");
  install_ints();
  print("- Interrupt system initialised.\n\n");

  print("Allocation test:\n");

  void* test = malloc(100);
  print("- Address returned: %h\n", (unsigned long)test);

  free(test);

  print("- Memory freed\n");
  
  return;
}
