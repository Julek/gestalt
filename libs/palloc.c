#include <linker_symbols.h>
#include <multiboot.h>
#include <stdbool.h>
#include <string.h>
#include <palloc.h>

unsigned char* palloc_table = (unsigned char*)end;

void setup_palloc(multiboot_info_t* multi_data __attribute__ ((unused)))
{
  //  memset(palloc_table, 0, );
}
